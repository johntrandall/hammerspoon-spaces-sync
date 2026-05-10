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

  # PHASE 1: probe
  probe_out=$(run_phase "$tf" "probe")
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

  # PHASE 2: print instructions, wait for "ready"
  printf "\n%s  INSTRUCTIONS%s\n" "$BOLD" "$RESET"
  get_instructions "$tf" | sed 's/^/    /'
  printf "\n"
  if ! prompt_enter "  Press Enter when you're at your trackpad/keyboard and ready to begin (or wait 120s) > " 120; then
    printf "  %sL6H FAIL: user did not respond%s\n" "$YELLOW" "$RESET"
    ANY_FAIL=1
    continue
  fi

  # PHASE 3: arm — automated dispatch (may be no-op)
  arm_out=$(run_phase "$tf" "arm")
  case "$arm_out" in
    "L6H ARM OK"*)
      echo "  arm: $arm_out"
      ;;
    *)
      printf "  %sarm FAIL:%s %s\n" "$YELLOW" "$RESET" "$arm_out"
      ANY_FAIL=1
      continue
      ;;
  esac

  # PHASE 4: prompt user to perform their action
  printf "\n  %s>>> NOW PERFORM THE MANUAL ACTION <<<%s\n" "$GREEN" "$RESET"
  if ! prompt_enter "  Press Enter once you've completed it (or wait 60s) > " 60; then
    printf "  %sL6H FAIL: user did not signal completion%s\n" "$YELLOW" "$RESET"
    ANY_FAIL=1
    continue
  fi

  # PHASE 5: settle so the chain finishes any pending polls + verifier
  printf "  %ssettle: %ss (waiting for chain to settle)%s\n" "$DIM" "$SETTLE_AFTER_USER" "$RESET"
  sleep "$SETTLE_AFTER_USER"

  # PHASE 6: assert
  assert_out=$(run_phase "$tf" "assert_")
  case "$assert_out" in
    "L6H PASS"*)
      printf "  %sassert: %s%s\n" "$GREEN" "$assert_out" "$RESET"
      ;;
    *)
      printf "  %sassert: %s%s\n" "$YELLOW" "$assert_out" "$RESET"
      ANY_FAIL=1
      ;;
  esac
done

echo
if [[ $ANY_FAIL -ne 0 ]]; then
  echo "L6h FAIL"
  exit 1
fi
echo "L6h OK"
exit 0
