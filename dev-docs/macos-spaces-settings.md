# macOS Settings That Affect SpacesSync

Every setting below can interfere with multi-monitor Space synchronization. Each is marked with a confidence level per the project's claim confidence convention.

## Confidence Key

| Marker | Meaning |
|---|---|
| **Verified** | Tested in isolation — changed one variable, observed the effect |
| **Observed** | Worked in our setup, but not tested by toggling this specific setting |
| **Inferred** | Logical conclusion from documentation or behavior, never directly tested |

---

## Critical Settings (will break sync if wrong)

### 1. Displays have separate Spaces

| | |
|---|---|
| **Location** | System Settings > Desktop & Dock > Mission Control |
| **Required** | ON |
| **Key** | `defaults read com.apple.spaces spans-displays` |
| **Required value** | `0` (counterintuitively, `0` = separate spaces ON) |
| **Effect if wrong** | All monitors share one Space. `hs.spaces.spacesForScreen()` returns the same spaces for every screen. Nothing to sync. |
| **Change requires** | Logout and login |
| **Confidence** | **Verified** — module checks this on init and blocks activation if wrong |

### 2. Automatically rearrange Spaces based on most recent use

| | |
|---|---|
| **Location** | System Settings > Desktop & Dock > Mission Control |
| **Required** | OFF |
| **Key** | `defaults read com.apple.dock mru-spaces` |
| **Required value** | `0` |
| **Effect if wrong** | macOS silently reorders Space indices. Space "3" on one monitor might become Space "1" after a few minutes of use. Index-based sync becomes meaningless — you switch to Space 3 on one monitor and the partner switches to what used to be Space 3 but is now a different desktop. |
| **Change requires** | `killall Dock` (or takes effect on next Dock restart) |
| **Confidence** | **Verified** — module checks this on init and warns |

---

## High-Risk Settings (likely to cause problems)

### 3. When switching to an application, switch to a Space with open windows for the application

| | |
|---|---|
| **Location** | System Settings > Desktop & Dock > Mission Control |
| **Required** | OFF (recommended) |
| **Key** | `defaults read com.apple.dock workspaces-auto-swoosh` |
| **Required value** | `0` (default is `1` / enabled when key is absent) |
| **Effect if wrong** | Clicking an app in the Dock or Cmd-Tabbing to it causes macOS to switch Spaces automatically. This fires the `hs.spaces.watcher` and SpacesSync interprets it as a user-initiated space switch, syncing all targets to that index. Could cause unexpected cascading switches when you just wanted to focus an app. |
| **Change requires** | `killall Dock` |
| **Confidence** | **Inferred** — not tested in isolation. The watcher would see the auto-switch the same as a manual switch. |

### 4. Stage Manager

| | |
|---|---|
| **Location** | System Settings > Desktop & Dock > Stage Manager |
| **Required** | OFF |
| **Key** | `defaults read com.apple.WindowManager GloballyEnabled` |
| **Required value** | `0` |
| **Effect if wrong** | Stage Manager changes how windows are organized within Spaces. It may alter which Space is "active" and how `hs.spaces.activeSpaceOnScreen()` reports state. Interaction with multi-monitor sync is unknown. |
| **Change requires** | Immediate |
| **Confidence** | **Inferred** — not tested. Stage Manager is a fundamentally different window management paradigm. |

### 5. Fullscreen apps creating separate Spaces

| | |
|---|---|
| **Location** | Per-window green button behavior (no global toggle) |
| **Required** | Awareness |
| **Key** | N/A (controlled per-window, stored in `com.apple.spaces.plist`) |
| **Required value** | N/A |
| **Effect if wrong** | When an app goes fullscreen, macOS creates a new Space for it. This changes the Space count and indices on that monitor. If monitor A has [Desktop 1, Desktop 2, Fullscreen Safari, Desktop 3] and monitor B has [Desktop 1, Desktop 2, Desktop 3], index 3 on A is "Fullscreen Safari" but index 3 on B is "Desktop 3". Sync would try to switch B to its index 3, which is the correct desktop — but the fullscreen Space on A has type `4` (fullscreen) vs type `0` (normal). `hs.spaces.spacesForScreen()` may or may not include fullscreen Spaces in the index. |
| **Change requires** | N/A |
| **Confidence** | **Inferred** — we haven't tested how fullscreen Spaces affect the index returned by `hs.spaces.spacesForScreen()`. This could be a significant edge case. |

### 6. Apps assigned to "All Desktops"

| | |
|---|---|
| **Location** | Right-click app in Dock > Options > All Desktops |
| **Required** | Awareness |
| **Key** | `defaults read com.apple.spaces app-bindings` |
| **Required value** | N/A |
| **Effect if wrong** | Apps assigned to "All Desktops" appear on every Space. This shouldn't affect sync directly (Space indices don't change), but it means these apps' windows may appear to "follow" you across synced switches, which could be confusing or desirable depending on intent. |
| **Change requires** | Immediate |
| **Confidence** | **Inferred** — All Desktops shouldn't change Space indices, but not tested. |

---

## Medium-Risk Settings (may cause subtle issues)

### 7. Group windows by application (Mission Control)

| | |
|---|---|
| **Location** | System Settings > Desktop & Dock > Mission Control |
| **Required** | No preference |
| **Key** | `defaults read com.apple.dock expose-group-apps` |
| **Required value** | Any (`0` or `1`) |
| **Effect if wrong** | Only affects how Mission Control visually groups windows. Should not affect Space indices or `hs.spaces` API behavior. |
| **Confidence** | **Inferred** — visual-only setting, unlikely to affect programmatic space switching. |

### 8. Reduce Motion (Accessibility)

| | |
|---|---|
| **Location** | System Settings > Accessibility > Display > Reduce motion |
| **Required** | No preference (but may help) |
| **Key** | `defaults read com.apple.universalaccess reduceMotion` |
| **Required value** | Any (`0` or `1`) |
| **Effect if wrong** | Reduces or eliminates Space-switching animations. With Reduce Motion ON, `gotoSpace()` may complete faster, potentially allowing a shorter `switchDelay`. With it OFF, the animation takes ~300ms which is why we need the delay between chained calls. |
| **Confidence** | **Inferred** — not tested whether Reduce Motion changes the timing requirements for chained `gotoSpace()` calls. |

### 9. Mission Control disabled entirely

| | |
|---|---|
| **Location** | N/A (hidden setting) |
| **Required** | Must NOT be set |
| **Key** | `defaults read com.apple.dock mcx-expose-disabled` |
| **Required value** | Key should not exist (or be `0`) |
| **Effect if wrong** | Disables Mission Control entirely. Spaces stop working. `hs.spaces` APIs would likely fail or return empty results. |
| **Confidence** | **Inferred** — documented behavior, not tested. |

---

## Low-Risk Settings (unlikely to affect sync)

### 10. Expose animation duration

| | |
|---|---|
| **Key** | `defaults read com.apple.dock expose-animation-duration` |
| **Effect** | Custom Mission Control animation speed. Visual only — shouldn't affect `gotoSpace()` timing. |
| **Confidence** | **Inferred** |

### 11. Swipe between Spaces gestures

| | |
|---|---|
| **Location** | System Settings > Trackpad > More Gestures |
| **Effect** | Trackpad swipes between Spaces fire the same watcher. SpacesSync handles them the same as keyboard switches. |
| **Confidence** | **Observed** — not specifically tested but the watcher is gesture-agnostic. |

---

## Testing Plan

Settings that need isolated testing before marking as Verified:

| # | Setting | Test procedure | Priority |
|---|---|---|---|
| 3 | workspaces-auto-swoosh | Enable, Cmd-Tab to an app on a different Space, observe if sync cascades | High |
| 5 | Fullscreen Spaces | Make an app fullscreen on one synced monitor, switch spaces on another, check if index mapping breaks | High |
| 8 | Reduce Motion | Enable, test if `switchDelay` can be reduced below 0.3s | Medium |
| 4 | Stage Manager | Enable, test basic sync behavior | Medium |
| 6 | All Desktops apps | Assign an app to All Desktops, verify sync still works | Low |
| 9 | mcx-expose-disabled | Set to true, verify module blocks gracefully | Low |

---

## Recommended Settings Script

The following script configures macOS for optimal SpacesSync behavior. It sets the two critical settings and the one high-risk recommended setting. All others are left at their defaults.

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "Configuring macOS for SpacesSync..."

# Critical: Displays have separate Spaces (requires logout)
current=$(defaults read com.apple.spaces spans-displays 2>/dev/null || echo "missing")
if [ "$current" != "0" ]; then
  echo "  Setting 'Displays have separate Spaces' to ON..."
  defaults write com.apple.spaces spans-displays -bool false
  echo "  ⚠️  LOGOUT REQUIRED for this to take effect."
else
  echo "  ✓ 'Displays have separate Spaces' already ON"
fi

# Critical: Disable auto-rearrange Spaces
current=$(defaults read com.apple.dock mru-spaces 2>/dev/null || echo "missing")
if [ "$current" != "0" ]; then
  echo "  Disabling 'Automatically rearrange Spaces'..."
  defaults write com.apple.dock mru-spaces -bool false
  DOCK_RESTART=1
else
  echo "  ✓ 'Automatically rearrange Spaces' already OFF"
fi

# Recommended: Disable auto-switch to app's Space
current=$(defaults read com.apple.dock workspaces-auto-swoosh 2>/dev/null || echo "missing")
if [ "$current" != "0" ]; then
  echo "  Disabling 'Switch to Space with open windows'..."
  defaults write com.apple.dock workspaces-auto-swoosh -bool false
  DOCK_RESTART=1
else
  echo "  ✓ 'Switch to Space with open windows' already OFF"
fi

# Recommended: Disable Stage Manager
current=$(defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null || echo "missing")
if [ "$current" != "0" ]; then
  echo "  Disabling Stage Manager..."
  defaults write com.apple.WindowManager GloballyEnabled -bool false
else
  echo "  ✓ Stage Manager already OFF"
fi

# Restart Dock if needed
if [ "${DOCK_RESTART:-0}" = "1" ]; then
  echo "  Restarting Dock..."
  killall Dock
fi

echo ""
echo "Done. If 'Displays have separate Spaces' was changed, log out and back in."
```

---

## Your Current Settings (ChoChang, 2026-04-09)

| Setting | Current value | Status |
|---|---|---|
| Displays have separate Spaces | ON (`spans-displays=0`) | ✅ Correct |
| Auto-rearrange Spaces | OFF (`mru-spaces=0`) | ✅ Correct |
| Switch to app's Space | ON (key absent = default ON) | ⚠️ Recommended: OFF |
| Stage Manager | OFF (`GloballyEnabled=0`) | ✅ Correct |
| Group windows by app | OFF (`expose-group-apps=0`) | ✅ No effect |
| Reduce Motion | OFF (`reduceMotion=0`) | ℹ️ Could test with ON |
| Mission Control disabled | No (key absent) | ✅ Correct |
| All Desktops apps | 11 apps bound | ℹ️ Monitor for issues |
