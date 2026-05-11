#!/usr/bin/env bash
# tests/L6/run.sh
#
# L6 dispatcher: runs each *.lua test in three phases (probe / arm /
# assert) with a shell-orchestrated sleep between arm and assert per
# dev-docs/test-strategy.md § Operational Notes.
#
# Per the strategy doc:
#   * `tests/L6/run.sh` owns probe/arm/sleep/assert orchestration
#     for L6 tests. Top-level tests/run.sh dispatcher does NOT
#     manage L6 timing or phases.
#   * SLEEP_BETWEEN >= max(8, 3 * pollTimeout + 2). At default
#     pollTimeout=2.0, that's 8 seconds.
#   * SPACESSYNC_L6=1 gating lives in the TOP-LEVEL tests/run.sh
#     dispatcher — this script does NOT re-check the env var.
#     Direct invocation of tests/L6/run.sh bypasses that gate
#     intentionally (debugging tool).
#
# Each test module exposes:
#   M.probe()              — read state, find trigger/target pair, stash plan
#   M.arm()                — dispatch the trigger swipe
#   M.disrupt()            — OPTIONAL; called between two sleeps to disturb
#                            the in-flight chain (e.g., scenario-08 calls
#                            :stop() mid-chain). Detected by grepping
#                            `function M.disrupt` in the test file.
#   M.assert_()            — read result, restore Spaces (and restart
#                            Spoon if the scenario stopped it)
#   M.required_*           — OPTIONAL declarative config. Any field
#                            named `M.required_FIELD` (where FIELD is a
#                            mutable obj.* attribute like `syncGroups`,
#                            `pollInterval`, `pollTimeout`) is snapshot'd
#                            BEFORE probe (dispatcher saves current
#                            obj.FIELD, sets to M.required_FIELD, then
#                            calls :stop():start() to re-arm) and
#                            RESTORED after the test (saved value
#                            re-applied + :stop():start()). The test's
#                            own phases see the bumped config; subsequent
#                            tests + the live user session see the
#                            original. Tables (e.g. syncGroups) are
#                            deep-copied on save and restore.
#
# Phase shape per test:
#   * Without M.disrupt: probe / arm / sleep(SLEEP_BETWEEN) / assert_
#   * With M.disrupt:    probe / arm / sleep(MID_SLEEP) / disrupt /
#                        sleep(SLEEP_BETWEEN) / assert_
#
# Each phase is a separate `hs -c` call (runloop-blocking constraint).
#
# Around each test (config-aware):
#   1. apply_test_config (snapshot obj.* + apply M.required_*)
#   2. (phase loop above)
#   3. restore_test_config (re-apply snapshot)
#
# Between scenarios the runner sleeps SETTLE_BETWEEN_TESTS seconds so
# the prior scenario's restore chain (or :start() warm-up) can settle
# before the next probe runs.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
L6_DIR="$REPO_ROOT/tests/L6"

if ! command -v hs >/dev/null 2>&1; then
  echo "L6 SKIP: hs CLI not on PATH"
  exit 0
fi

if ! hs -c 'return "alive"' 2>/dev/null | grep -q alive; then
  echo "L6 SKIP: Hammerspoon not responding to hs -c"
  exit 0
fi

# Read pollTimeout from the live Spoon to size SLEEP_BETWEEN per the
# formula. If the Spoon isn't loaded, individual tests SKIP via probe.
POLL_TIMEOUT=$(hs -q -c 'if spoon and spoon.SpacesSync and spoon.SpacesSync.pollTimeout then return spoon.SpacesSync.pollTimeout else return 2.0 end' 2>/dev/null | tail -1)
if [[ -z "$POLL_TIMEOUT" || ! "$POLL_TIMEOUT" =~ ^[0-9.]+$ ]]; then
  POLL_TIMEOUT=2.0
fi

# SLEEP_BETWEEN = max(8, 3 * pollTimeout + 2). Use awk for floating math.
SLEEP_BETWEEN=$(awk -v pt="$POLL_TIMEOUT" 'BEGIN { v = 3 * pt + 2; if (v < 8) v = 8; printf "%g\n", v }')

# MID_SLEEP: only used by tests that define M.disrupt. Long enough for
# the watcher to fire and the chain to enter its first poll cycle at
# default pollTimeout=2.0 (poll interval ~0.25s); short enough to land
# the disrupt while syncInProgress is still true.
MID_SLEEP=1.0

# SETTLE_BETWEEN_TESTS: pause between scenarios so a prior restore /
# :start() warm-up can settle before the next probe checks
# syncInProgress.
SETTLE_BETWEEN_TESTS=3

echo "L6 setup: pollTimeout=$POLL_TIMEOUT, SLEEP_BETWEEN=${SLEEP_BETWEEN}s (max(8, 3*pollTimeout+2)), MID_SLEEP=${MID_SLEEP}s, SETTLE_BETWEEN_TESTS=${SETTLE_BETWEEN_TESTS}s"

# -----------------------------------------------------------------------------
# Run-scoped state snapshot + EXIT-trap restore
# -----------------------------------------------------------------------------
#
# Each test's `apply_test_config` / `restore_test_config` is a per-test
# guarantee. But if a test crashes BEFORE its restore runs (e.g. the
# user Ctrl-Cs L6, or hs.ipc hangs mid-test), the user's live
# obj.syncGroups / pollTimeout / pollInterval can be left at the
# test's bumped values. The next L6 run then snapshots the polluted
# values as "saved" and never recovers.
#
# This wrapper snapshots the user's live config at L6 startup, stashes
# it in _G for safekeeping, and registers a bash EXIT trap that
# restores it. The trap runs on:
#   * Normal completion (after the test loop)
#   * Test FAIL (non-zero exit)
#   * Ctrl-C / SIGINT
#   * Any other shell exit
#
# The snapshot key is unique per L6 run to avoid colliding with a
# prior interrupted run's snapshot (which might itself be polluted).

L6_SNAPSHOT_KEY="_SpacesSyncL6_RunSnapshot_$$"  # $$ = pid, unique per run
echo "  L6 run-scope: snapshotting live config to $L6_SNAPSHOT_KEY"
snapshot_out=$(hs -q -c "
  local s = spoon.SpacesSync
  if not s then return 'L6 SNAPSHOT FAIL: spoon.SpacesSync not loaded' end
  local function deep_copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, vv in pairs(v) do out[k] = deep_copy(vv) end
    return out
  end
  _G['$L6_SNAPSHOT_KEY'] = {
    syncGroups   = deep_copy(s.syncGroups),
    pollTimeout  = s.pollTimeout,
    pollInterval = s.pollInterval,
  }
  return 'L6 SNAPSHOT OK: syncGroups=' .. tostring(hs.inspect and hs.inspect(s.syncGroups) or 'table') ..
         ', pollTimeout=' .. tostring(s.pollTimeout) ..
         ', pollInterval=' .. tostring(s.pollInterval)
" 2>&1 | tail -1)
echo "  $snapshot_out"

# Restore function — called by EXIT trap, also runs after normal
# completion. Resets to the snapshotted values and re-arms via
# :stop():start(). Idempotent (clears _G key after running).
l6_restore_snapshot() {
  local restore_out=$(hs -q -c "
    local snap = _G['$L6_SNAPSHOT_KEY']
    if not snap then return 'L6 SNAPSHOT-RESTORE SKIP: no snapshot' end
    local s = spoon.SpacesSync
    if not s then return 'L6 SNAPSHOT-RESTORE FAIL: spoon.SpacesSync vanished' end
    local function deep_copy(v)
      if type(v) ~= 'table' then return v end
      local out = {}
      for k, vv in pairs(v) do out[k] = deep_copy(vv) end
      return out
    end
    s.syncGroups   = deep_copy(snap.syncGroups)
    s.pollTimeout  = snap.pollTimeout
    s.pollInterval = snap.pollInterval
    _G['$L6_SNAPSHOT_KEY'] = nil
    s:stop()
    s:start()
    return 'L6 SNAPSHOT-RESTORE OK: syncGroups=' .. tostring(hs.inspect and hs.inspect(s.syncGroups) or 'table') ..
           ', pollTimeout=' .. tostring(s.pollTimeout) ..
           ', pollInterval=' .. tostring(s.pollInterval)
  " 2>&1 | tail -1)
  echo "  $restore_out"
}

# Register the EXIT trap. This fires on:
#   * Script's natural end (exit 0 / exit 1 below)
#   * Ctrl-C / SIGINT propagating up
#   * Any explicit `exit` call
trap 'l6_restore_snapshot' EXIT

# Helper: invoke one phase via `hs -c -q`, return its tail-line result.
run_phase() {
  local test_file="$1"
  local phase="$2"
  # `tail -1` strips any preceding info-level log lines.
  hs -q -c "local M = dofile('$test_file'); return M.${phase}()" 2>&1 | tail -1
}

# Pre-probe: snapshot any obj.* fields the test declares as
# M.required_FIELD, apply the required values, re-arm via stop/start.
# Snapshot is stashed in _G keyed by the scenario basename so
# restore_test_config can find it. Tables are deep-copied so the
# saved reference survives any in-place mutations.
#
# Returns:
#   "L6 CONFIG OK: applied {summary}" — config was applied
#   "L6 CONFIG OK: no required_* fields" — test has no config needs
#   "L6 CONFIG FAIL: {reason}" — apply failed (raises ANY_FAIL)
apply_test_config() {
  local test_file="$1"
  local scenario_key="$2"
  hs -q -c "
    local M = dofile('$test_file')
    if not spoon or not spoon.SpacesSync then
      return 'L6 CONFIG FAIL: spoon.SpacesSync not loaded'
    end
    local s = spoon.SpacesSync

    local function deep_copy(v)
      if type(v) ~= 'table' then return v end
      local out = {}
      for k, vv in pairs(v) do out[k] = deep_copy(vv) end
      return out
    end

    local saved = {}
    local applied = {}
    for k, v in pairs(M) do
      local field = type(k) == 'string' and k:match('^required_(.+)$') or nil
      if field and type(v) ~= 'function' then
        saved[field] = deep_copy(s[field])
        s[field] = deep_copy(v)
        applied[field] = v
      end
    end

    if not next(saved) then
      return 'L6 CONFIG OK: no required_* fields'
    end

    _G['_SpacesSyncL6_SavedConfig_${scenario_key}'] = saved
    s:stop()
    s:start()

    local parts = {}
    for f, v in pairs(applied) do
      if type(v) == 'table' then
        table.insert(parts, f .. '=<table>')
      else
        table.insert(parts, f .. '=' .. tostring(v))
      end
    end
    return 'L6 CONFIG OK: applied ' .. table.concat(parts, ', ')
  " 2>&1 | tail -1
}

# Post-test: re-apply the snapshot from apply_test_config and clear
# the _G stash. Always run if apply_test_config returned OK, regardless
# of test outcome — keeps the live user session clean.
#
# Returns:
#   \"L6 CONFIG RESTORED: {summary}\"
#   \"L6 CONFIG SKIP: no saved config\" — apply_test_config didn't run / no fields
#   \"L6 CONFIG FAIL: {reason}\" — restore failed
restore_test_config() {
  local scenario_key="$1"
  hs -q -c "
    local key = '_SpacesSyncL6_SavedConfig_${scenario_key}'
    local saved = _G[key]
    if not saved or not next(saved) then
      return 'L6 CONFIG SKIP: no saved config'
    end
    if not spoon or not spoon.SpacesSync then
      return 'L6 CONFIG FAIL: spoon.SpacesSync vanished'
    end
    local s = spoon.SpacesSync

    local function deep_copy(v)
      if type(v) ~= 'table' then return v end
      local out = {}
      for k, vv in pairs(v) do out[k] = deep_copy(vv) end
      return out
    end

    local parts = {}
    for f, v in pairs(saved) do
      s[f] = deep_copy(v)
      if type(v) == 'table' then
        table.insert(parts, f .. '=<table>')
      else
        table.insert(parts, f .. '=' .. tostring(v))
      end
    end
    _G[key] = nil
    s:stop()
    s:start()
    return 'L6 CONFIG RESTORED: ' .. table.concat(parts, ', ')
  " 2>&1 | tail -1
}

shopt -s nullglob
TESTS=("$L6_DIR"/scenario-*.lua)
if [[ ${#TESTS[@]} -eq 0 ]]; then
  echo "L6 SKIP: no scenario-*.lua tests in $L6_DIR"
  exit 0
fi

ANY_FAIL=0
FIRST_TEST=1
for tf in "${TESTS[@]}"; do
  name="$(basename "$tf" .lua)"
  # Scenario key for _G stash — basename suffices since scenario files
  # are unique per directory, and the key only needs to round-trip
  # apply -> restore within one test.
  scenario_key=$(basename "$tf" .lua | tr -c 'A-Za-z0-9' '_')

  # Inter-test settle: let a prior scenario's restore / restart finish
  # before this scenario's probe reads :status().
  if [[ $FIRST_TEST -eq 0 ]]; then
    sleep "$SETTLE_BETWEEN_TESTS"
  fi
  FIRST_TEST=0

  echo "── $name"

  # Detect optional disrupt phase by inspecting the test file. Cheap
  # and avoids an extra `hs -c` round-trip.
  HAS_DISRUPT=0
  if grep -q '^function M.disrupt' "$tf"; then
    HAS_DISRUPT=1
  fi

  # PHASE 0: apply test-declared config (M.required_*). Snapshot stashed
  # in _G; restore_test_config (called at end of scenario) reverses.
  config_out=$(apply_test_config "$tf" "$scenario_key")
  case "$config_out" in
    "L6 CONFIG OK"*)
      # Only print if it actually applied something — "no required_*"
      # is the silent default for tests without config needs.
      case "$config_out" in
        *"no required_* fields"*) : ;;
        *) echo "  config: $config_out" ;;
      esac
      ;;
    *)
      echo "  config FAIL: $config_out"
      ANY_FAIL=1
      continue
      ;;
  esac

  # Recompute SLEEP_BETWEEN per-scenario — apply_test_config may have
  # bumped pollTimeout (e.g. scenario-05 sets pollTimeout=8.0 to
  # accommodate a bumped pollInterval). The global SLEEP_BETWEEN at
  # startup was sized from the unbumped pollTimeout; using it here
  # would cause assert to run while the chain is still in flight.
  scenario_pt=$(hs -q -c 'return tostring(spoon.SpacesSync.pollTimeout or 2.0)' 2>/dev/null | tail -1)
  if [[ ! "$scenario_pt" =~ ^[0-9.]+$ ]]; then scenario_pt=2.0; fi
  scenario_sleep=$(awk -v pt="$scenario_pt" 'BEGIN { v = 3 * pt + 2; if (v < 8) v = 8; printf "%g\n", v }')
  if [[ "$scenario_sleep" != "$SLEEP_BETWEEN" ]]; then
    echo "  (scenario sleep ${scenario_sleep}s, was ${SLEEP_BETWEEN}s — pollTimeout was bumped)"
  fi

  # PHASE 1: probe
  probe_out=$(run_phase "$tf" "probe")
  case "$probe_out" in
    "L6 PROBE READY"*)
      echo "  probe: $probe_out"
      ;;
    "L6 SKIP"*)
      echo "  $probe_out"
      restore_out=$(restore_test_config "$scenario_key")
      case "$restore_out" in
        "L6 CONFIG SKIP"*) : ;;
        *) echo "  config: $restore_out" ;;
      esac
      continue
      ;;
    *)
      echo "  probe FAIL: $probe_out"
      ANY_FAIL=1
      restore_out=$(restore_test_config "$scenario_key")
      case "$restore_out" in
        "L6 CONFIG SKIP"*) : ;;
        *) echo "  config: $restore_out" ;;
      esac
      continue
      ;;
  esac

  # PHASE 2: arm — dispatch the trigger.
  arm_out=$(run_phase "$tf" "arm")
  case "$arm_out" in
    "L6 ARM OK"*)
      echo "  arm: $arm_out"
      ;;
    *)
      echo "  arm FAIL: $arm_out"
      ANY_FAIL=1
      restore_out=$(restore_test_config "$scenario_key")
      case "$restore_out" in
        "L6 CONFIG SKIP"*) : ;;
        *) echo "  config: $restore_out" ;;
      esac
      continue
      ;;
  esac

  if [[ $HAS_DISRUPT -eq 1 ]]; then
    # PHASE 2.5a: short sleep to land mid-chain.
    echo "  mid-sleep: ${MID_SLEEP}s (letting chain enter flight)"
    sleep "$MID_SLEEP"

    # PHASE 2.5b: disrupt — synchronous state perturbation
    # (e.g. :stop() the Spoon).
    disrupt_out=$(run_phase "$tf" "disrupt")
    case "$disrupt_out" in
      "L6 DISRUPT OK"*)
        echo "  disrupt: $disrupt_out"
        ;;
      *)
        echo "  disrupt FAIL: $disrupt_out"
        ANY_FAIL=1
        restore_out=$(restore_test_config "$scenario_key")
        case "$restore_out" in
          "L6 CONFIG SKIP"*) : ;;
          *) echo "  config: $restore_out" ;;
        esac
        continue
        ;;
    esac
  fi

  # PHASE 3: shell-sleep so the runloop pumps the watcher / chain /
  # verifier. Must precede assert. For disrupt-style tests this is the
  # window in which stale callbacks must fire AND bail. Uses the
  # scenario-specific sleep (recomputed after apply_test_config above).
  echo "  sleep: ${scenario_sleep}s (waiting for chain to settle)"
  sleep "$scenario_sleep"

  # PHASE 4: assert — read result, restore Spaces (and restart Spoon
  # if the scenario stopped it). CRITICAL: the assert phase reads
  # lastVerifierResult BEFORE dispatching restore.
  assert_out=$(run_phase "$tf" "assert_")
  case "$assert_out" in
    "L6 PASS"*)
      echo "  assert: $assert_out"
      ;;
    *)
      echo "  assert: $assert_out"
      ANY_FAIL=1
      ;;
  esac

  # PHASE 5: restore test-declared config (always runs after probe
  # READY, regardless of subsequent outcomes via early-exit continues
  # above).
  restore_out=$(restore_test_config "$scenario_key")
  case "$restore_out" in
    "L6 CONFIG SKIP"*) : ;;
    *) echo "  config: $restore_out" ;;
  esac
done

if [[ $ANY_FAIL -ne 0 ]]; then
  echo "L6 FAIL"
  exit 1
fi
echo "L6 OK"
exit 0
