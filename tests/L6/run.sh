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
#   M.probe()    — read state, find trigger/target pair, stash plan
#   M.arm()      — dispatch the trigger swipe
#   M.assert_()  — read result, restore Spaces
#
# Each phase is a separate `hs -c` call (runloop-blocking constraint).

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
echo "L6 setup: pollTimeout=$POLL_TIMEOUT, SLEEP_BETWEEN=${SLEEP_BETWEEN}s (max(8, 3*pollTimeout+2))"

# Helper: invoke one phase via `hs -c -q`, return its tail-line result.
run_phase() {
  local test_file="$1"
  local phase="$2"
  # `tail -1` strips any preceding info-level log lines.
  hs -q -c "local M = dofile('$test_file'); return M.${phase}()" 2>&1 | tail -1
}

shopt -s nullglob
TESTS=("$L6_DIR"/scenario-*.lua)
if [[ ${#TESTS[@]} -eq 0 ]]; then
  echo "L6 SKIP: no scenario-*.lua tests in $L6_DIR"
  exit 0
fi

ANY_FAIL=0
for tf in "${TESTS[@]}"; do
  name="$(basename "$tf" .lua)"
  echo "── $name"

  # PHASE 1: probe
  probe_out=$(run_phase "$tf" "probe")
  case "$probe_out" in
    "L6 PROBE READY"*)
      echo "  probe: $probe_out"
      ;;
    "L6 SKIP"*)
      echo "  $probe_out"
      continue
      ;;
    *)
      echo "  probe FAIL: $probe_out"
      ANY_FAIL=1
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
      continue
      ;;
  esac

  # PHASE 3: shell-sleep so the runloop pumps the watcher / chain /
  # verifier. Must precede assert.
  echo "  sleep: ${SLEEP_BETWEEN}s (waiting for chain to settle)"
  sleep "$SLEEP_BETWEEN"

  # PHASE 4: assert — read result, restore Spaces. CRITICAL: the
  # assert phase reads lastVerifierResult BEFORE dispatching restore.
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
done

if [[ $ANY_FAIL -ne 0 ]]; then
  echo "L6 FAIL"
  exit 1
fi
echo "L6 OK"
exit 0
