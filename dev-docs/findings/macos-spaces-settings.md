# macOS Settings That Affect SpacesSync

Every setting below can interfere with multi-monitor Space synchronization. Each is marked with a confidence level per the project's claim confidence convention.

## Confidence Key

| Marker | Meaning |
|---|---|
| **Verified** | Tested in isolation — changed one variable, observed the effect |
| **Logically inferred** | Follows from API documentation or observed system behavior, but not tested by toggling this specific setting |
| **Suspected** | Plausible concern based on how macOS works, but no documentation or testing supports it |

---

## Required Settings (sync will not work without these)

### 1. Displays have separate Spaces

| | |
|---|---|
| **Location** | System Settings > Desktop & Dock > Mission Control |
| **Required** | ON |
| **Key** | `defaults read com.apple.spaces spans-displays` |
| **Required value** | `0` (counterintuitively, `0` = separate spaces ON) |
| **Effect if wrong** | All monitors share one Space. `hs.spaces.spacesForScreen()` returns the same spaces for every screen. Nothing to sync. |
| **Change requires** | Logout and login |
| **Confidence** | **Verified** — sync does not work without this setting enabled |

---

## Recommended Settings (sync works but behavior may be surprising)

### 2. Automatically rearrange Spaces based on most recent use

| | |
|---|---|
| **Location** | System Settings > Desktop & Dock > Mission Control |
| **Recommended** | OFF |
| **Key** | `defaults read com.apple.dock mru-spaces` |
| **Recommended value** | `0` |
| **Effect if wrong** | macOS silently reorders Space indices. Space "3" on one monitor might become Space "1" after a few minutes of use. Index-based sync becomes meaningless — you switch to Space 3 on one monitor and the target switches to what used to be Space 3 but is now a different desktop. |
| **Change requires** | `killall Dock` (or takes effect on next Dock restart) |
| **Confidence** | **Logically inferred** — module checks the defaults key on init, but we have not toggled this ON and observed index reordering |

### 3. When switching to an application, switch to a Space with open windows for the application

| | |
|---|---|
| **Location** | System Settings > Desktop & Dock > Mission Control |
| **Recommended** | OFF |
| **Key** | `defaults read com.apple.dock workspaces-auto-swoosh` |
| **Required value** | `0` (default is `1` / enabled when key is absent) |
| **Effect if wrong** | Clicking an app in the Dock or Cmd-Tabbing to it causes macOS to switch Spaces automatically. This fires the `hs.spaces.watcher` and SpacesSync interprets it as a user-initiated space switch, syncing all targets to that index. Could cause unexpected cascading switches when you just wanted to focus an app. |
| **Change requires** | `killall Dock` |
| **Confidence** | **Logically inferred** — the watcher would see the auto-switch the same as a manual switch, but not tested in isolation |

### 4. Stage Manager

| | |
|---|---|
| **Location** | System Settings > Desktop & Dock > Stage Manager |
| **Recommended** | OFF |
| **Key** | `defaults read com.apple.WindowManager GloballyEnabled` |
| **Required value** | `0` |
| **Effect if wrong** | Stage Manager changes how windows are organized within Spaces. It may alter which Space is "active" and how `hs.spaces.activeSpaceOnScreen()` reports state. Interaction with multi-monitor sync is unknown. |
| **Change requires** | Immediate |
| **Confidence** | **Suspected** — Stage Manager is a fundamentally different window management paradigm; no documentation or testing on interaction with hs.spaces |

---

## Informational Settings (no effect or needs investigation)

### 5. Fullscreen apps creating separate Spaces

| | |
|---|---|
| **Location** | Per-window green button behavior (no global toggle) |
| **Required** | Awareness |
| **Key** | N/A (controlled per-window, stored in `com.apple.spaces.plist`) |
| **Required value** | N/A |
| **Effect if wrong** | When an app goes fullscreen, macOS creates a new Space for it. This changes the Space count and indices on that monitor. If monitor A has [Desktop 1, Desktop 2, Fullscreen Safari, Desktop 3] and monitor B has [Desktop 1, Desktop 2, Desktop 3], index 3 on A is "Fullscreen Safari" but index 3 on B is "Desktop 3". Sync would try to switch B to its index 3, which is the correct desktop — but the fullscreen Space on A has type `4` (fullscreen) vs type `0` (normal). `hs.spaces.spacesForScreen()` may or may not include fullscreen Spaces in the index. |
| **Change requires** | N/A |
| **Confidence** | **Suspected** — we haven't tested how fullscreen Spaces affect the index returned by `hs.spaces.spacesForScreen()`. Could be a significant edge case or a non-issue. |

### 6. Apps assigned to "All Desktops"

| | |
|---|---|
| **Location** | Right-click app in Dock > Options > All Desktops |
| **Required** | Awareness |
| **Key** | `defaults read com.apple.spaces app-bindings` |
| **Required value** | N/A |
| **Effect if wrong** | Apps assigned to "All Desktops" appear on every Space. This shouldn't affect sync directly (Space indices don't change), but it means these apps' windows may appear to "follow" you across synced switches, which could be confusing or desirable depending on intent. |
| **Change requires** | Immediate |
| **Confidence** | **Verified** — apps assigned to All Desktops do not affect Space indices; sync works normally with them present |

### 7. Group windows by application (Mission Control)

| | |
|---|---|
| **Location** | System Settings > Desktop & Dock > Mission Control |
| **Required** | No preference |
| **Key** | `defaults read com.apple.dock expose-group-apps` |
| **Required value** | Any (`0` or `1`) |
| **Effect if wrong** | Only affects how Mission Control visually groups windows. Should not affect Space indices or `hs.spaces` API behavior. |
| **Confidence** | **Logically inferred** — visual-only setting, unlikely to affect programmatic space switching |

### 8. Reduce Motion (Accessibility)

| | |
|---|---|
| **Location** | System Settings > Accessibility > Display > Reduce motion |
| **Required** | No preference (but may help) |
| **Key** | `defaults read com.apple.universalaccess reduceMotion` |
| **Required value** | Any (`0` or `1`) |
| **Effect if wrong** | Reduces or eliminates Space-switching animations. With Reduce Motion ON, `gotoSpace()` may complete faster, potentially allowing a shorter `switchDelay`. With it OFF, the animation takes ~300ms which is why we need the delay between chained calls. |
| **Confidence** | **Suspected** — plausible that reducing animation would affect timing, but not tested |

### 9. Mission Control disabled entirely

| | |
|---|---|
| **Location** | N/A (hidden setting) |
| **Required** | Must NOT be set |
| **Key** | `defaults read com.apple.dock mcx-expose-disabled` |
| **Required value** | Key should not exist (or be `0`) |
| **Effect if wrong** | Disables Mission Control entirely. Spaces stop working. `hs.spaces` APIs would likely fail or return empty results. |
| **Confidence** | **Logically inferred** — documented behavior, not tested |

### 10. Expose animation duration

| | |
|---|---|
| **Key** | `defaults read com.apple.dock expose-animation-duration` |
| **Effect** | Custom Mission Control animation speed. Visual only — shouldn't affect `gotoSpace()` timing. |
| **Confidence** | **Suspected** — plausible but no evidence this key affects gotoSpace timing |

### 11. Swipe between Spaces gestures

| | |
|---|---|
| **Location** | System Settings > Trackpad > More Gestures |
| **Effect** | Trackpad swipes between Spaces fire the same watcher. SpacesSync handles them the same as keyboard switches. |
| **Confidence** | **Verified** — trackpad swipe gestures trigger sync correctly, confirmed by user testing |

---

## Testing Plan

Settings that need isolated testing before marking as Verified:

| # | Setting | Test procedure | Priority |
|---|---|---|---|
| 1 | spans-displays | Set to 1 (shared Spaces), logout/login, check what `hs.spaces.spacesForScreen()` returns for each screen | High |
| 2 | mru-spaces | Set to 1, create 3+ Spaces, use them in different order, check if indices shift | High |
| 3 | workspaces-auto-swoosh | Enable, Cmd-Tab to an app on a different Space, observe if sync cascades | High |
| 5 | Fullscreen Spaces | Make an app fullscreen on one synced monitor, switch spaces on another, check if index mapping breaks | High |
| 8 | Reduce Motion | Enable, test if `switchDelay` can be reduced below 0.3s | Medium |
| 4 | Stage Manager | Enable, test basic sync behavior | Medium |
| 6 | All Desktops apps | Assign an app to All Desktops, verify sync still works | Low |
| 9 | mcx-expose-disabled | Set to true, verify module blocks gracefully | Low |

---

## Setup Script

See `configure-macos.sh` in the repo root. It sets the required and recommended settings.

