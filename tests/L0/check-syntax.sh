#!/usr/bin/env bash
# tests/L0/check-syntax.sh
#
# L0 guard: Lua syntax check on the Spoon source.
#
# Per dev-docs/test-strategy.md § Active Levels L0:
#   "lua syntax (via luacheck or `luac -p`; SKIP if neither on PATH)"
#
# Catches typos / unbalanced blocks / illegal-escape regressions that
# would prevent Hammerspoon from loading the Spoon at all. Doesn't
# catch runtime API misuse — that's L1+.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INIT_LUA="$REPO_ROOT/Source/SpacesSync.spoon/init.lua"

if [[ ! -f "$INIT_LUA" ]]; then
  echo "L0 syntax FAIL: $INIT_LUA does not exist"
  exit 1
fi

# Prefer luacheck (richer diagnostics: undeclared globals, unused vars,
# shadowing, etc.). Fall back to `luac -p` (parse-only). If neither is
# on PATH, SKIP per the strategy doc — L0 must remain runnable on any
# host without forcing Lua dev deps.
if command -v luacheck >/dev/null 2>&1; then
  TOOL="luacheck"
  # --no-color: deterministic output for grep/CI
  # --no-global: ignore undeclared globals (init.lua references `hs`,
  #              `spoon`, etc., which are injected by Hammerspoon).
  # --no-self: ignore "implicit self argument" warnings (Lua method idiom).
  if luacheck --no-color --no-global --no-self "$INIT_LUA" >/dev/null 2>&1; then
    echo "L0 syntax PASS: luacheck clean on $(basename "$INIT_LUA")"
    exit 0
  else
    echo "L0 syntax FAIL: luacheck reported issues:"
    luacheck --no-color --no-global --no-self "$INIT_LUA"
    exit 1
  fi
elif command -v luac >/dev/null 2>&1; then
  TOOL="luac"
  if luac -p "$INIT_LUA" 2>/dev/null; then
    echo "L0 syntax PASS: luac -p clean on $(basename "$INIT_LUA")"
    exit 0
  else
    echo "L0 syntax FAIL: luac -p reported syntax errors:"
    luac -p "$INIT_LUA"
    exit 1
  fi
else
  echo "L0 syntax SKIP: neither luacheck nor luac on PATH"
  echo "  install via 'brew install luacheck' (preferred) or 'brew install lua'"
  exit 0
fi
