#!/usr/bin/env bash
# tests/L6h/run.sh
#
# L6h dispatcher — human-in-loop E2E tests. L6h is a sub-tier of L6
# (per dev-docs/test-strategy.md § L6 Sub-Tiers). The contract:
#
#   * L6  = fully automated via `hs -c` + `hs.spaces.gotoSpace`.
#   * L6h = scripted prompts + programmatic assertions, but the
#           TRIGGER comes from a real user action (trackpad swipe,
#           accessibility toggle, hotkey, etc.) that `gotoSpace`
#           cannot emulate from the AX path.
#
# WHY L6h EXISTS
#   Manual-checklist scenarios like Group B #5 ("user re-swipes
#   trigger mid-chain") cannot run as L6 because Mission Control
#   serializes/drops a second `gotoSpace` while SpacesSync's chain
#   is in flight (see dev-docs/hammerspoon-and-spaces-quirks.md
#   § "Rapid gotoSpace() calls get silently dropped", L6 testing
#   footnote). Real trackpad input goes through a different priority
#   queue. L6h captures that gap with scripted prompts + Lua-side
#   assertions on `:status().lastVerifierResult`, replacing the
#   prose-only "v3 actual" column for those scenarios.
#
# GATING
#   * SPACESSYNC_L6H=1 is enforced in the TOP-LEVEL tests/run.sh
#     (not here). Direct invocation of tests/L6h/run.sh bypasses the
#     gate intentionally (debugging tool).
#   * Hammerspoon must be running and the Spoon must be `:start`-ed.
#
# Each test module exposes:
#   M.probe()           — preflight + plan; returns "L6H PROBE READY: ..."
#                          or "L6H SKIP: <reason>".
#   M.instructions()    — returns a multi-line human-readable string
#                          describing what the user must do.
#   M.arm()             — the AUTOMATED dispatch (often a single
#                          `gotoSpace`); may be a no-op for scenarios
#                          where the user does everything.
#   M.assert_()         — read state, validate, cleanup. Returns
#                          "L6H PASS: ..." or "L6H FAIL: ...".
#
# Each phase is a separate `hs -c` call (runloop-blocking constraint,
# same as L6).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
L6H_DIR="$REPO_ROOT/tests/L6h"

# --- Terminal styling (no-op if not a TTY) -----------------------------------

if [[ -t 1 ]]; then
  BOLD=$(printf '\033[1m')
  DIM=$(printf '\033[2m')
  YELLOW=$(printf '\033[33m')
  GREEN=$(printf '\033[32m')
  CYAN=$(printf '\033[36m')
  RESET=$(printf '\033[0m')
else
  BOLD=""; DIM=""; YELLOW=""; GREEN=""; CYAN=""; RESET=""
fi

# --- Preflight ---------------------------------------------------------------

if ! command -v hs >/dev/null 2>&1; then
  echo "L6h SKIP: hs CLI not on PATH"
  exit 0
fi

if ! hs -c 'return "alive"' 2>/dev/null | grep -q alive; then
  echo "L6h SKIP: Hammerspoon not responding to hs -c"
  exit 0
fi

# Settle time AFTER the user signals "done my action". Lets the chain
# complete its remaining polls + verifier before we read state. Sized
# like L6's SLEEP_BETWEEN — same chain, same worst-case.
POLL_TIMEOUT=$(hs -q -c 'if spoon and spoon.SpacesSync and spoon.SpacesSync.pollTimeout then return spoon.SpacesSync.pollTimeout else return 2.0 end' 2>/dev/null | tail -1)
if [[ -z "$POLL_TIMEOUT" || ! "$POLL_TIMEOUT" =~ ^[0-9.]+$ ]]; then
  POLL_TIMEOUT=2.0
fi
SETTLE_AFTER_USER=$(awk -v pt="$POLL_TIMEOUT" 'BEGIN { v = 3 * pt + 2; if (v < 8) v = 8; printf "%g\n", v }')

# Inter-test settle, same purpose as L6.
SETTLE_BETWEEN_TESTS=3

echo "L6h setup: pollTimeout=$POLL_TIMEOUT, SETTLE_AFTER_USER=${SETTLE_AFTER_USER}s, SETTLE_BETWEEN_TESTS=${SETTLE_BETWEEN_TESTS}s"

# Durable result log — survives pane close. Cleared at start of each
# run; written to alongside stdout so the calling agent (or future-
# you) can read the result without racing the pane lifecycle.
RESULT_LOG="$REPO_ROOT/tests/L6h/last-run.log"
{
  echo "L6h run starting: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "pollTimeout=$POLL_TIMEOUT SETTLE_AFTER_USER=${SETTLE_AFTER_USER}s"
  echo "---"
} > "$RESULT_LOG"
echo "  log: $RESULT_LOG"

log_result() {
  echo "$@" >> "$RESULT_LOG"
}

# -----------------------------------------------------------------------------
# Window placement — auto-move iTerm window to an independent display.
# -----------------------------------------------------------------------------
#
# Why: L6h scenarios swipe Spaces on sync-group displays. A terminal
# hosted on one of those displays will vanish along with the prior
# Space when the swipe lands, hiding subsequent prompts. We move
# iTerm's focused window to a display outside the sync group before
# any prompts are shown, so the rest of the flow stays visible.
#
# How: hs.application.find('iTerm2'):focusedWindow() returns the
# frontmost iTerm window — the one the user just typed `tests/run.sh
# L6h` in. We resolve which position it's currently on, check it
# against the live syncGroups via spoon.SpacesSync:status(), and
# move it to the first independent position if needed.
move_result=$(hs -q -c '
local app = hs.application.find("iTerm2")
if not app then return "L6H WINDOW SKIP: iTerm2 not running" end
local win = app:focusedWindow() or app:mainWindow()
if not win then return "L6H WINDOW SKIP: no iTerm window" end

local cur_screen = win:screen()
if not cur_screen then return "L6H WINDOW SKIP: window has no screen" end

if not spoon or not spoon.SpacesSync then return "L6H WINDOW SKIP: spoon.SpacesSync not loaded" end
local status = spoon.SpacesSync:status()
local syncGroups = status.syncGroups or {}

local screens = hs.screen.allScreens()
table.sort(screens, function(a,b)
  local fa, fb = a:frame(), b:frame()
  if fa.x ~= fb.x then return fa.x < fb.x end
  return fa.y < fb.y
end)

local cur_pos
for i, scr in ipairs(screens) do
  if scr == cur_screen then cur_pos = i; break end
end
if not cur_pos then return "L6H WINDOW SKIP: cannot resolve iTerm window position" end

local function in_any_group(pos)
  for _, g in ipairs(syncGroups) do
    if type(g) == "table" then
      for _, p in ipairs(g) do
        if p == pos then return true end
      end
    end
  end
  return false
end

if not in_any_group(cur_pos) then
  return "L6H WINDOW OK: iTerm already on independent pos " .. cur_pos
end

local target_pos
for i = 1, #screens do
  if not in_any_group(i) then target_pos = i; break end
end
if not target_pos then return "L6H WINDOW FAIL: no independent display available" end

win:moveToScreen(screens[target_pos], false, true)
return "L6H WINDOW MOVED: from pos " .. cur_pos .. " to pos " .. target_pos
' 2>&1 | tail -1)

case "$move_result" in
  "L6H WINDOW OK"*|"L6H WINDOW MOVED"*)
    printf "  %s%s%s\n" "$DIM" "$move_result" "$RESET"
    ;;
  "L6H WINDOW SKIP"*|"L6H WINDOW FAIL"*)
    printf "  %s%s — you'll need to move your terminal manually.%s\n" "$YELLOW" "$move_result" "$RESET"
    ;;
  *)
    printf "  %sWindow-move probe produced unexpected output: %s%s\n" "$YELLOW" "$move_result" "$RESET"
    ;;
esac

# --- Helpers -----------------------------------------------------------------

run_phase() {
  local test_file="$1"
  local phase="$2"
  hs -q -c "local M = dofile('$test_file'); return M.${phase}()" 2>&1 | tail -1
}

# Get the multi-line instructions string. Unlike phase results, this
# may legitimately span multiple lines, so don't tail -1.
get_instructions() {
  local test_file="$1"
  hs -q -c "local M = dofile('$test_file'); return M.instructions()" 2>&1
}

# Wait for the user to press Enter, with a fallback timeout. Returns
# 0 if Enter pressed, 1 if timed out. Reads from /dev/tty so it works
# under any stdin redirection.
prompt_enter() {
  local prompt="$1"
  local timeout="${2:-120}"
  printf "%s%s%s " "$CYAN" "$prompt" "$RESET"
  if read -r -t "$timeout" _ </dev/tty 2>/dev/null; then
    return 0
  else
    printf "\n%s(timed out after %ss)%s\n" "$YELLOW" "$timeout" "$RESET"
    return 1
  fi
}

# Run M.cleanup() for a test file. Used both inline at end-of-scenario
# (success path) and from the early-exit short-circuits below. Safe
# to call more than once per scenario — cleanup is idempotent (it
# clears its own _G cache after first run).
run_cleanup_for_test() {
  local tf="$1"
  local cleanup_out=$(hs -q -c "local M = dofile('$tf'); if M.cleanup then return M.cleanup() else return 'L6H CLEANUP SKIP: no cleanup defined' end" 2>&1 | tail -1)
  log_result "  cleanup: $cleanup_out"
  case "$cleanup_out" in
    "L6H CLEANUP OK"*|"L6H CLEANUP SKIP"*)
      printf "  %scleanup: %s%s\n" "$DIM" "$cleanup_out" "$RESET"
      ;;
    *)
      printf "  %scleanup: %s%s\n" "$YELLOW" "$cleanup_out" "$RESET"
      ;;
  esac
}

# --- Test loop ---------------------------------------------------------------

shopt -s nullglob
TESTS=("$L6H_DIR"/scenario-*.lua)
if [[ ${#TESTS[@]} -eq 0 ]]; then
  echo "L6h SKIP: no scenario-*.lua tests in $L6H_DIR"
  exit 0
fi

ANY_FAIL=0
FIRST_TEST=1
for tf in "${TESTS[@]}"; do
  name="$(basename "$tf" .lua)"

  if [[ $FIRST_TEST -eq 0 ]]; then
    sleep "$SETTLE_BETWEEN_TESTS"
  fi
  FIRST_TEST=0

  printf "\n%s── %s%s\n" "$BOLD" "$name" "$RESET"
  log_result ""
  log_result "── $name"

  # PHASE 1: probe
  probe_out=$(run_phase "$tf" "probe")
  log_result "  probe: $probe_out"
  case "$probe_out" in
    "L6H PROBE READY"*)
      echo "  probe: $probe_out"
      ;;
    "L6H SKIP"*)
      echo "  $probe_out"
      continue
      ;;
    *)
      printf "  %sprobe FAIL:%s %s\n" "$YELLOW" "$RESET" "$probe_out"
      ANY_FAIL=1
      continue
      ;;
  esac

  # Re-read pollTimeout AFTER probe — probe may have bumped it (e.g.
  # scenario-05 sets pollTimeout=8.0 to give the user a comfortable
  # swipe window). Recompute SETTLE_AFTER_USER per-scenario so the
  # chain actually has time to complete before assert runs.
  scenario_poll=$(hs -q -c 'return tostring(spoon.SpacesSync.pollTimeout or 2.0)' 2>/dev/null | tail -1)
  if [[ ! "$scenario_poll" =~ ^[0-9.]+$ ]]; then scenario_poll=2.0; fi
  scenario_settle=$(awk -v pt="$scenario_poll" 'BEGIN { v = 3 * pt + 2; if (v < 8) v = 8; printf "%g\n", v }')
  printf "  %s(scenario pollTimeout=%s, settle=%ss)%s\n" "$DIM" "$scenario_poll" "$scenario_settle" "$RESET"
  log_result "  scenario_poll=$scenario_poll scenario_settle=${scenario_settle}s"

  # PHASE 2a: print full instructions. (Window placement was already
  # handled by the move_result step at the top of this run.)
  printf "\n%s  INSTRUCTIONS (read fully — these are the rules)%s\n" "$BOLD" "$RESET"
  get_instructions "$tf" | sed 's/^/    /'
  printf "\n"

  # PHASE 2c: action summary — what the user will need to do, displayed
  # IMMEDIATELY BEFORE arm fires. Read from M.user_action_summary() if
  # the test exposes it; otherwise a generic message.
  action_summary=$(hs -q -c "local M = dofile('$tf'); if M.user_action_summary then return M.user_action_summary() else return '' end" 2>&1 | tail -1)
  action_window=$(hs -q -c "local M = dofile('$tf'); return tonumber(M.action_window_seconds) or 0" 2>/dev/null | tail -1)
  if [[ ! "$action_window" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then action_window=0; fi

  printf "\n%s  ──── YOUR ACTION ────%s\n" "$BOLD" "$RESET"
  if [[ -n "$action_summary" ]]; then
    printf "%s    %s%s\n" "$CYAN" "$action_summary" "$RESET"
  else
    printf "%s    (see instructions above)%s\n" "$DIM" "$RESET"
  fi
  if (( $(awk -v v="$action_window" 'BEGIN { print (v > 0) }') )); then
    printf "%s    Window: %ss after the auto-trigger fires. NO Enter after your action.%s\n" "$CYAN" "$action_window" "$RESET"
  else
    printf "%s    After your action, press Enter to continue.%s\n" "$CYAN" "$RESET"
  fi
  printf "\n"

  # PHASE 2d: final "fire when ready" gate
  if ! prompt_enter "  Press Enter to fire the auto-trigger (or wait 600s) > " 600; then
    printf "  %sL6H FAIL: user did not fire%s\n" "$YELLOW" "$RESET"
    ANY_FAIL=1
    run_cleanup_for_test "$tf"
    continue
  fi

  # PHASE 3: arm — automated dispatch (may be no-op)
  arm_out=$(run_phase "$tf" "arm")
  log_result "  arm: $arm_out"
  case "$arm_out" in
    "L6H ARM OK"*)
      echo "  arm: $arm_out"
      ;;
    *)
      printf "  %sarm FAIL:%s %s\n" "$YELLOW" "$RESET" "$arm_out"
      ANY_FAIL=1
      run_cleanup_for_test "$tf"
      continue
      ;;
  esac

  # PHASE 3.5: wait for the chain to ACTUALLY enter flight before
  # opening the user's action window. Without this, GO! prints
  # immediately after arm, but the auto-swipe gesture is still mid-
  # animation and the watcher hasn't fired yet. A user who reacts to
  # GO! quickly may swipe BEFORE the chain starts, in which case the
  # watcher's first fire sees the user's swipe (not the auto one),
  # expectedEndState[trigger] points to the user's destination, and
  # the verifier finds 0 mismatches.
  #
  # We poll status.syncInProgress every 100 ms (via the lightweight
  # `hs -c` round-trip) for up to 2 s. If we never see
  # syncInProgress=true, the auto-swipe may have been dropped — log
  # and continue anyway (assert_ will catch it).
  inflight=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    sp=$(hs -q -c 'return tostring(spoon and spoon.SpacesSync and spoon.SpacesSync:status().syncInProgress)' 2>/dev/null | tail -1)
    if [[ "$sp" == "true" ]]; then
      inflight=1
      break
    fi
    sleep 0.1
  done
  if [[ $inflight -eq 1 ]]; then
    printf "  %s(chain in flight; opening action window)%s\n" "$DIM" "$RESET"
    log_result "  chain_in_flight: yes"
  else
    printf "  %s(WARNING: chain did NOT enter flight within 2 s — auto-swipe may have been dropped)%s\n" "$YELLOW" "$RESET"
    log_result "  chain_in_flight: no (warning)"
  fi

  # PHASE 4: prompt user OR sleep a fixed action window.
  #
  # Two completion-signal modes per scenario:
  #
  #   * action_window_seconds (read once per test) — if a positive
  #     number, runner prints "GO! N seconds" and shell-sleeps N
  #     seconds. NO second Enter prompt. Right for scenarios where the
  #     user's action briefly hides the terminal (e.g. swipe-the-
  #     trigger-display moves Spaces on that display).
  #   * Otherwise — runner waits for Enter (default). Right for
  #     scenarios where the user toggles a system pref / clicks a
  #     dialog and the terminal stays visible throughout.
  #
  # The mode is read once via `hs -c` after arm.
  action_window=$(hs -q -c "local M = dofile('$tf'); return tonumber(M.action_window_seconds) or 0" 2>/dev/null | tail -1)
  if [[ "$action_window" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(awk -v v="$action_window" 'BEGIN { print (v > 0) }') )); then
    # Terminal bell + bold green banner. The bell helps when the
    # user is staring at the trigger monitor (not the terminal) —
    # they hear the GO cue.
    printf '\a'
    printf "\n"
    printf "  %s╔═══════════════════════════════════════════════╗%s\n" "$GREEN" "$RESET"
    printf "  %s║  >>> GO! SWIPE NOW — %ss window OPEN <<<       ║%s\n" "$GREEN" "$action_window" "$RESET"
    printf "  %s╚═══════════════════════════════════════════════╝%s\n" "$GREEN" "$RESET"
    sleep "$action_window"
    printf "  %s(action window closed)%s\n" "$DIM" "$RESET"
  else
    printf "\n  %s>>> NOW PERFORM THE MANUAL ACTION <<<%s\n" "$GREEN" "$RESET"
    if ! prompt_enter "  Press Enter once you've completed it (or wait 60s) > " 60; then
      printf "  %sL6H FAIL: user did not signal completion%s\n" "$YELLOW" "$RESET"
      ANY_FAIL=1
      run_cleanup_for_test "$tf"
      continue
    fi
  fi

  # PHASE 5: settle so the chain finishes any pending polls + verifier.
  # Uses the scenario-specific settle (sized from THIS scenario's
  # pollTimeout, which may have been bumped by probe).
  printf "  %ssettle: %ss (waiting for chain to settle)%s\n" "$DIM" "$scenario_settle" "$RESET"
  sleep "$scenario_settle"

  # PHASE 6: assert
  assert_out=$(run_phase "$tf" "assert_")
  log_result "  assert: $assert_out"
  case "$assert_out" in
    "L6H PASS"*)
      printf "  %sassert: %s%s\n" "$GREEN" "$assert_out" "$RESET"
      ;;
    *)
      printf "  %sassert: %s%s\n" "$YELLOW" "$assert_out" "$RESET"
      ANY_FAIL=1
      ;;
  esac

  # PHASE 7: cleanup — ALWAYS run if probe was READY. Restores
  # test-owned config (e.g. obj.syncGroups). Skipped silently if the
  # test doesn't define M.cleanup. A cleanup failure is logged but
  # does not flip ANY_FAIL — the test result already captured the
  # behavior under test; cleanup failure is housekeeping only.
  run_cleanup_for_test "$tf"
done

echo
log_result ""
if [[ $ANY_FAIL -ne 0 ]]; then
  echo "L6h FAIL"
  log_result "L6h FAIL"
  log_result "EXIT=1 at $(date '+%Y-%m-%d %H:%M:%S')"
  exit 1
fi
echo "L6h OK"
log_result "L6h OK"
log_result "EXIT=0 at $(date '+%Y-%m-%d %H:%M:%S')"
exit 0
