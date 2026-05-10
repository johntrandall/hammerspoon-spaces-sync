#!/usr/bin/env bash
# tests/L3/run.sh
#
# L3 dispatcher: load each *.lua test module via `hs -c` and report.
#
# Per dev-docs/test-strategy.md § Active Levels L3 + § Operational
# Notes:
#   * `hs -c` blocks the runloop until the chunk returns, so each
#     L3 test must be one synchronous read of state — no waits, no
#     watchers, no timers.
#   * The Spoon must be :start()-ed; tests SKIP if not.
#   * Output may include info-level log lines BEFORE the actual
#     PASS/FAIL/SKIP line (e.g. :status() logs a one-line summary).
#     We match the LAST line for the result classification.
#
# Usage: tests/L3/run.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
L3_DIR="$REPO_ROOT/tests/L3"

if ! command -v hs >/dev/null 2>&1; then
  echo "L3 SKIP: hs CLI not on PATH (install Hammerspoon and enable the IPC CLI)"
  exit 0
fi

# Hammerspoon must be reachable.
if ! hs -c 'return "alive"' 2>/dev/null | grep -q alive; then
  echo "L3 SKIP: Hammerspoon not responding to hs -c (is it running?)"
  exit 0
fi

shopt -s nullglob
TESTS=("$L3_DIR"/*.lua)
if [[ ${#TESTS[@]} -eq 0 ]]; then
  echo "L3 SKIP: no *.lua tests in $L3_DIR"
  exit 0
fi

ANY_FAIL=0
for tf in "${TESTS[@]}"; do
  name="$(basename "$tf" .lua)"

  # `-q`: quiet mode (only errors + final result on the wire).
  # The `dofile` returns the test module table; we call M.run() and
  # return its string. `tail -1` extracts the result line, ignoring
  # any preceding info-level logs.
  raw=$(hs -q -c "local M = dofile('$tf'); return M.run()" 2>&1)
  result="$(printf '%s\n' "$raw" | tail -1)"

  case "$result" in
    "L3 PASS"*)
      echo "[$name] $result"
      ;;
    "L3 SKIP"*)
      echo "[$name] $result"
      ;;
    *)
      echo "[$name] $result"
      # On FAIL, surface the full output for debugging (log lines often
      # carry useful context before the result line).
      if [[ "$raw" != "$result" ]]; then
        echo "    full hs -c output:"
        printf '%s\n' "$raw" | sed 's/^/      /'
      fi
      ANY_FAIL=1
      ;;
  esac
done

if [[ $ANY_FAIL -ne 0 ]]; then
  echo "L3 FAIL"
  exit 1
fi
echo "L3 OK"
exit 0
