#!/usr/bin/env bash
# tests/L0/check-docs-json.sh
#
# L0 guard: docs.json validity + v0.3 entry presence.
#
# Per dev-docs/test-strategy.md § Active Levels L0:
#   "docs.json shape"
#
# Catches:
#   * docs.json drift after init.lua edits (broken JSON, missing
#     required Variable / Method entries)
#   * Forgot-to-regenerate-docs after API changes
#
# Does NOT validate that every doc field matches the source — that's
# more invasive. Just checks structural integrity + the canonical
# v0.3 surface.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOCS_JSON="$REPO_ROOT/Source/SpacesSync.spoon/docs.json"

if [[ ! -f "$DOCS_JSON" ]]; then
  echo "L0 docs.json FAIL: $DOCS_JSON does not exist"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  # python3 ships with macOS by default. If somehow missing, SKIP
  # rather than fail — L0 must remain robust on a stripped host.
  echo "L0 docs.json SKIP: python3 not on PATH"
  exit 0
fi

# Required v0.3 surface, derived from dev-docs/test-strategy.md §
# L3 Contract Spec and the public method list. If init.lua adds new
# public surface, add it here (or, better, regenerate docs.json and
# update this script in the same commit).
python3 - "$DOCS_JSON" <<'PYEOF'
import json
import sys

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f"L0 docs.json FAIL: invalid JSON: {e}")
    sys.exit(1)

# Top-level shape: list of one module entry.
if not isinstance(data, list) or not data:
    print("L0 docs.json FAIL: top-level should be a non-empty list")
    sys.exit(1)

mod = data[0]
if not isinstance(mod, dict):
    print("L0 docs.json FAIL: first entry should be a module object")
    sys.exit(1)

# Required v0.3 variables.
required_variables = {
    "syncGroups",
    "pollTimeout",
    "pollInterval",
    "switchDelay",       # deprecated but present
    "debounceSeconds",   # deprecated but present
    "popupDuration",
    "spaceNames",
    "logger",
}
got_variables = {v["name"] for v in mod.get("Variable", []) if "name" in v}
missing_variables = required_variables - got_variables
if missing_variables:
    print(f"L0 docs.json FAIL: missing Variable entries: {sorted(missing_variables)}")
    sys.exit(1)

# Required v0.3 methods. Per L3 Contract Spec the public surface is
# fixed; if init.lua adds a method, regenerate docs.json AND update
# this list.
required_methods = {
    "init",
    "start",
    "stop",
    "toggle",
    "isEnabled",
    "status",
    "showNames",
    "renameCurrentSpace",
    "bindHotkeys",
}
got_methods = {m["name"] for m in mod.get("Method", []) if "name" in m}
missing_methods = required_methods - got_methods
if missing_methods:
    print(f"L0 docs.json FAIL: missing Method entries: {sorted(missing_methods)}")
    sys.exit(1)

# Each Variable / Method entry must have at least name + doc/desc fields.
for category in ("Variable", "Method"):
    for entry in mod.get(category, []):
        if "name" not in entry:
            print(f"L0 docs.json FAIL: {category} entry missing 'name'")
            sys.exit(1)
        if not entry.get("doc") and not entry.get("desc"):
            print(f"L0 docs.json FAIL: {category}[{entry['name']}] has no 'doc' or 'desc'")
            sys.exit(1)

print(f"L0 docs.json PASS: {len(got_variables)} variables, {len(got_methods)} methods, all required entries present")
PYEOF
