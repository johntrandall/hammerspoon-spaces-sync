#!/usr/bin/env bash
# tests/L0/run.sh
#
# L0 dispatcher: run every check-*.sh in tests/L0/, report results.
# Exits 0 only if every script returns PASS or SKIP. Any FAIL in any
# script is propagated.
#
# Per dev-docs/test-strategy.md § Active Levels L0:
#   "Headless. Runs on any host without Hammerspoon."

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
L0_DIR="$REPO_ROOT/tests/L0"

shopt -s nullglob
SCRIPTS=("$L0_DIR"/check-*.sh)
if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
  echo "L0 SKIP: no check-*.sh scripts in $L0_DIR"
  exit 0
fi

ANY_FAIL=0
for s in "${SCRIPTS[@]}"; do
  # Each script self-prints its PASS/FAIL/SKIP line; we just propagate.
  bash "$s"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    ANY_FAIL=1
  fi
done

if [[ $ANY_FAIL -ne 0 ]]; then
  echo "L0 FAIL: at least one check failed"
  exit 1
fi
echo "L0 OK"
exit 0
