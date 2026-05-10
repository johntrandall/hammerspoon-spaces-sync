#!/usr/bin/env bash
# tests/L1/run.sh
#
# L1 unit-test runner. Exec'd from the repo root by tests/run.sh.
#
# Usage: tests/L1/run.sh
#
# Loads the minimal harness (helpers.lua), seeds it with every
# *_spec.lua file in this directory, runs them, and exits 0 on
# clean / 1 on any failure.
#
# Requires `lua` on PATH. Tested on Lua 5.5.
#
# Per dev-docs/test-strategy.md § Active Levels L1: stateless
# helpers (compareVersions, isLegacyFlatSchema) and module-state
# helpers (getGroupKey, getTargetsFor, getDisplayLabel) are
# exercised against the SHIPPED init.lua via a controlled load
# that stubs `hs` and reaches the local helpers via
# debug.getupvalue introspection (no init.lua modification).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

if ! command -v lua >/dev/null 2>&1; then
  echo "L1 SKIP: lua not on PATH (install via 'brew install lua')"
  exit 0
fi

LUA_PATH_PREFIX="$REPO_ROOT/tests/L1/?.lua;;"
export LUA_PATH="$LUA_PATH_PREFIX${LUA_PATH:-}"

# Generate a tiny driver that loads every *_spec.lua file then runs.
# Putting this inline avoids an extra file and keeps the spec list
# discovered fresh on each run.
SPEC_FILES=$(ls "$REPO_ROOT/tests/L1"/*_spec.lua 2>/dev/null | sort)
if [[ -z "$SPEC_FILES" ]]; then
  echo "L1 SKIP: no *_spec.lua files in tests/L1/"
  exit 0
fi

DRIVER=$(mktemp -t spacessync_l1_driver.XXXXXX.lua)
trap 'rm -f "$DRIVER"' EXIT
{
  echo 'local h = require("helpers")'
  while IFS= read -r f; do
    fname="$(basename "$f" .lua)"
    echo "require(\"$fname\")"
  done <<< "$SPEC_FILES"
  echo 'if h.run_tests() then os.exit(0) else os.exit(1) end'
} > "$DRIVER"

lua "$DRIVER"
