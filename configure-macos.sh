#!/usr/bin/env bash
# Configure macOS settings for optimal SpacesSync behavior.
# See dev-docs/macos-spaces-settings.md for details on each setting.
set -euo pipefail

DOCK_RESTART=0

echo "Configuring macOS for SpacesSync..."
echo ""

# Critical: Displays have separate Spaces (requires logout)
current=$(defaults read com.apple.spaces spans-displays 2>/dev/null || echo "missing")
if [ "$current" != "0" ]; then
  echo "  [CRITICAL] Setting 'Displays have separate Spaces' to ON..."
  defaults write com.apple.spaces spans-displays -bool false
  echo "  ⚠️  LOGOUT REQUIRED for this to take effect."
else
  echo "  ✓ 'Displays have separate Spaces' already ON"
fi

# Critical: Disable auto-rearrange Spaces
current=$(defaults read com.apple.dock mru-spaces 2>/dev/null || echo "missing")
if [ "$current" != "0" ]; then
  echo "  [CRITICAL] Disabling 'Automatically rearrange Spaces'..."
  defaults write com.apple.dock mru-spaces -bool false
  DOCK_RESTART=1
else
  echo "  ✓ 'Automatically rearrange Spaces' already OFF"
fi

# Recommended: Disable auto-switch to app's Space
current=$(defaults read com.apple.dock workspaces-auto-swoosh 2>/dev/null || echo "missing")
if [ "$current" != "0" ]; then
  echo "  [RECOMMENDED] Disabling 'Switch to Space with open windows'..."
  defaults write com.apple.dock workspaces-auto-swoosh -bool false
  DOCK_RESTART=1
else
  echo "  ✓ 'Switch to Space with open windows' already OFF"
fi

# Recommended: Disable Stage Manager
current=$(defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null || echo "missing")
if [ "$current" != "0" ]; then
  echo "  [RECOMMENDED] Disabling Stage Manager..."
  defaults write com.apple.WindowManager GloballyEnabled -bool false
else
  echo "  ✓ Stage Manager already OFF"
fi

# Restart Dock if needed
if [ "$DOCK_RESTART" = "1" ]; then
  echo ""
  echo "  Restarting Dock to apply changes..."
  killall Dock
fi

echo ""
echo "Done."
echo ""
if [ "$current" != "0" ] && [ "$(defaults read com.apple.spaces spans-displays 2>/dev/null)" = "1" ]; then
  echo "⚠️  'Displays have separate Spaces' was changed — log out and back in for it to take effect."
fi
echo "Run SpacesSync with debug=true to verify settings are detected correctly."
