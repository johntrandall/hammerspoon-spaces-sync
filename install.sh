#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/.hammerspoon/spaces-sync.lua"

if [ -L "$TARGET" ]; then
  echo "Symlink already exists: $TARGET -> $(readlink "$TARGET")"
elif [ -e "$TARGET" ]; then
  echo "ERROR: $TARGET exists and is not a symlink. Back it up first."
  exit 1
else
  ln -s "$SCRIPT_DIR/spaces-sync.lua" "$TARGET"
  echo "Installed: $TARGET -> $SCRIPT_DIR/spaces-sync.lua"
fi

echo ""
echo "Usage: Toggle with Ctrl+Alt+Cmd+Y in Hammerspoon"
echo "Also available in the ⚡ automations menu → 'Sync LG Monitors Toggle'"
