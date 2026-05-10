#!/usr/bin/env bash
# tests/run.sh — top-level test dispatcher
#
# Per dev-docs/test-strategy.md § Cumulative `_inclusive` Runners +
# Deviations §5 (SPACESSYNC_L6 gate is a single point in this file).
#
# Usage:
#   tests/run.sh                    # default: L0 + L3 (safe, requires HS but no Spaces switch)
#   tests/run.sh L0                 # L0 only
#   tests/run.sh L1                 # L1 only
#   tests/run.sh L3                 # L3 only
#   tests/run.sh L6                 # L6 only (requires SPACESSYNC_L6=1)
#   tests/run.sh L1_inclusive       # L0 + L1
#   tests/run.sh L3_inclusive       # L0 + L1 + L3
#   tests/run.sh L6_inclusive       # L0 + L1 + L3 + L6 (requires SPACESSYNC_L6=1)
#
# `_inclusive` semantics: include every active level at or below the
# named one. Inactive levels (L2, L4, L5, L7, L8) are silently skipped
# in the chain.
#
# SPACESSYNC_L6 gate: any invocation that would run L6 requires
# SPACESSYNC_L6=1. The gate lives here, NOT in tests/L6/run.sh. Direct
# invocation of tests/L6/run.sh bypasses the gate intentionally
# (debugging tool).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"

usage() {
  cat <<EOF
Usage: tests/run.sh [LEVEL]

LEVEL is one of:
  L0                 repo guards (headless)
  L1                 unit tests for pure-Lua helpers
  L3                 public API contract (requires Hammerspoon running)
  L6                 live sync chain (requires SPACESSYNC_L6=1; switches Spaces)
  L1_inclusive       L0 + L1
  L3_inclusive       L0 + L1 + L3
  L6_inclusive       L0 + L1 + L3 + L6 (requires SPACESSYNC_L6=1)

  (no argument)      L0 + L3      [default — "safe", no Spaces disruption]

Inactive levels (L2, L4, L5, L7, L8) are silently skipped.

See dev-docs/test-strategy.md for the full policy.
EOF
}

# Map a requested level to the ordered list of levels to run.
# "Active" levels in this project: L0, L1, L3, L6. Others are no-ops.
plan_for() {
  case "$1" in
    "")              echo "L0 L3" ;;       # default — safe
    L0)              echo "L0" ;;
    L1)              echo "L1" ;;
    L3)              echo "L3" ;;
    L6)              echo "L6" ;;
    L1_inclusive)    echo "L0 L1" ;;
    L2_inclusive)    echo "L0 L1" ;;       # L2 inactive — skipped
    L3_inclusive)    echo "L0 L1 L3" ;;
    L4_inclusive)    echo "L0 L1 L3" ;;    # L4 inactive
    L5_inclusive)    echo "L0 L1 L3" ;;    # L5 inactive
    L6_inclusive)    echo "L0 L1 L3 L6" ;;
    L7_inclusive)    echo "L0 L1 L3 L6" ;; # L7 inactive
    L8_inclusive)    echo "L0 L1 L3 L6" ;; # L8 inactive
    -h|--help|help)  usage; exit 0 ;;
    *)               echo "ERROR: unknown level: $1"; usage; exit 2 ;;
  esac
}

ARG="${1:-}"
PLAN="$(plan_for "$ARG")"
if [[ "$PLAN" == ERROR:* ]]; then
  echo "$PLAN" >&2
  usage >&2
  exit 2
fi

# SPACESSYNC_L6 gate: SINGLE point of enforcement (Deviations §5).
# Reject the run upfront before any side effects, even L0.
if [[ "$PLAN" == *L6* && "${SPACESSYNC_L6:-}" != "1" ]]; then
  cat >&2 <<EOF
tests/run.sh: refusing to run L6 without SPACESSYNC_L6=1.

L6 tests dispatch real hs.spaces.gotoSpace() calls and switch Spaces
on the test host's displays for ~SLEEP_BETWEEN seconds (default 8s).
Restore is best-effort.

Set SPACESSYNC_L6=1 explicitly to opt in:

  SPACESSYNC_L6=1 tests/run.sh $ARG

See dev-docs/test-strategy.md § Deviations §5 for context.
EOF
  exit 2
fi

echo "tests/run.sh: plan = $PLAN"

ANY_FAIL=0
for level in $PLAN; do
  echo
  echo "════ $level ════"
  case "$level" in
    L0)  bash "$TESTS_DIR/L0/run.sh"  || ANY_FAIL=1 ;;
    L1)  bash "$TESTS_DIR/L1/run.sh"  || ANY_FAIL=1 ;;
    L3)  bash "$TESTS_DIR/L3/run.sh"  || ANY_FAIL=1 ;;
    L6)  bash "$TESTS_DIR/L6/run.sh"  || ANY_FAIL=1 ;;
    *)   echo "internal error: unknown level in plan: $level"; ANY_FAIL=1 ;;
  esac
done

echo
if [[ $ANY_FAIL -ne 0 ]]; then
  echo "════ tests/run.sh FAIL: at least one level failed ════"
  exit 1
fi
echo "════ tests/run.sh OK: $PLAN ════"
exit 0
