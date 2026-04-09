#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPOON_SRC="$SCRIPT_DIR/Source/SpacesSync.spoon"
SPOON_DIR="$HOME/.hammerspoon/Spoons"
TARGET="$SPOON_DIR/SpacesSync.spoon"

# Ensure Spoons directory exists
mkdir -p "$SPOON_DIR"

if [ -L "$TARGET" ]; then
  echo "Symlink already exists: $TARGET -> $(readlink "$TARGET")"
elif [ -e "$TARGET" ]; then
  echo "ERROR: $TARGET exists and is not a symlink. Back it up first."
  exit 1
else
  ln -s "$SPOON_SRC" "$TARGET"
  echo "Installed: $TARGET -> $SPOON_SRC"
fi

# Clean up legacy flat-module symlink if present
LEGACY="$HOME/.hammerspoon/spaces-sync.lua"
if [ -L "$LEGACY" ]; then
  echo ""
  echo "Found legacy symlink: $LEGACY"
  echo "Remove it after updating your init.lua to use the Spoon."
fi

echo ""
echo "Add to ~/.hammerspoon/init.lua:"
echo ""
echo '  hs.loadSpoon("SpacesSync")'
echo '  spoon.SpacesSync.syncGroups = { {1, 2} }'
echo '  spoon.SpacesSync:bindHotkeys({ toggle = {{"ctrl", "alt", "cmd"}, "Y"} })'
echo '  spoon.SpacesSync:start()'
