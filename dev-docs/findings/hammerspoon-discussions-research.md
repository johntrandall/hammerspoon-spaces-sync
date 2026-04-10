# Hammerspoon Discussions Research

Findings from surveying github.com/Hammerspoon/hammerspoon discussions and issues.
Research conducted 2026-04-09 by multiple parallel agents.

## hs.spaces API Risk Assessment

### What works on Sequoia (macOS 15)

| API | Status | Mechanism | Risk |
|---|---|---|---|
| `gotoSpace()` | Working | AX automation of Mission Control (clicks space buttons) | Low-Medium |
| `hs.spaces.watcher` | Working | Built-in event watcher, predates hs.spaces rewrite | Low |
| `allSpaces()` | Working | CGS private functions (`CGSCopyManagedDisplaySpaces`) | Low-Medium |
| `activeSpaceOnScreen()` | Working | CGS private functions | Low-Medium |
| `focusedSpace()` | Working | CGS private functions | Low-Medium |
| `spacesForScreen()` | Working | CGS private functions | Low-Medium |

### What broke on Sequoia

| API | Status | What happened |
|---|---|---|
| `moveWindowToSpace()` | Broken | Apple NOP'd three WindowServer functions the Sonoma 14.5 fix relied on. All remaining functions require Dock.app-level rights. Returns `true` but does nothing. |
| `windowSpaces()` | Broken | Multiple reports of inaccurate data on Sequoia |

### Why gotoSpace() is different

`gotoSpace()` does NOT use private WindowServer APIs. It uses `hs.axuielement` to:
1. Open Mission Control programmatically
2. Find the target space button in the AX element tree
3. Click it
4. Close Mission Control

This is the same mechanism a screen reader uses. Apple protects accessibility API stability more than private framework functions. The tradeoff is speed — it's slow because it physically opens/closes Mission Control.

Source: Issue #2776 (maintainer @asmagill explaining the architecture).

### macOS 16 (Tahoe) compatibility

One user reports Hammerspoon "works fine on Tahoe" (discussion #3805, general statement). No specific testing of `gotoSpace()` or `hs.spaces.watcher` on Tahoe has been reported. No maintainer comments on Tahoe.

### Maintainer statements

- **@asmagill** (hs.spaces author, Sep 2024): "it might be time to admit defeat and move spaces to more of a yabai wrapper"
- **@cmsj** (co-founder, Jun 2024): "We could also just get out of the business of pretending that Apple wants us interacting with Spaces"
- Neither maintainer has flagged `gotoSpace()` specifically as at risk

## Hammerspoon Project Health

### Current state (as of Apr 2026)
- Last release: August 2024
- 600+ open issues
- PRs still merged sporadically
- Two core maintainers, both acknowledge reduced motivation

### Swift rewrite ("Hammerspoon v2")
- @cmsj outlined vision in Jun 2023: Swift + new scripting language, "HammerKit" framework
- @latenitefilms confirmed "in progress" Nov 2025
- **No public repo, no timeline, no ETA**
- Would break all existing Spoons and configs
- Not imminent — project is in slow-maintenance holding pattern

### Alternatives people are migrating to
- **yabai** — most commonly mentioned, requires SIP disabled for space operations on Sequoia
- **AeroSpace** — growing tiling WM alternative
- **Amethyst** — also affected by Sequoia changes
- **BetterTouchTool** — mentioned as possible replacement for some workflows

## Performance: Instant Space Switching — NOT VIABLE for our use case

### Summary

**Neither fast-switch technique targets a specific non-focused monitor**, which is exactly what our sync engine needs. `hs.spaces.gotoSpace(spaceID)` remains the only viable mechanism for us because the space ID implicitly targets the correct display.

### Discussion #3823: window:focus() trick

Cache a window reference per space. Instead of `gotoSpace(spaceID)`, call `window:focus()` on a window known to be in the target space. The focus call triggers an instant space switch without the Mission Control animation.

**Author:** itsfarseen (Sep 2025). Open, no replies.

**Why it doesn't work for us:**
- `window:focus()` steals keyboard focus to that window's monitor. Our use case is silently syncing *other* monitors in the background — we don't want to move focus.
- Empty spaces still need `gotoSpace()` fallback with the animation
- The cache can go stale if windows are closed/moved without revisiting the space
- Good for "switch my own monitor fast", bad for "sync other monitors silently"

### Issue #3850 / jurplel/InstantSpaceSwitcher

InstantSpaceSwitcher posts synthetic trackpad swipe gestures (`kCGSEventGesture` + `kCGSEventDockControl`) via `CGEventTap` to trick macOS into switching spaces without animation.

**Why it doesn't work for us:**
- Posts events to `kCGSessionEventTap` — macOS routes them to whichever display is "active" (cursor position or menu bar display)
- No way to target a specific non-focused display
- Would require moving the cursor to each target monitor, posting gestures, moving cursor back — fragile and disruptive
- `iss_get_space_info()` reads per-display but `iss_post_switch_gesture()` doesn't accept a display parameter
- The author themselves noted: "it cannot replace hs.spaces.gotoSpace"

**Other caveats:**
- Doesn't work during Mission Control or App Exposé
- Multi-step switches require N sequential gestures (unclear if rapid ones are reliable)
- Requires Accessibility permissions (creates event tap)
- Uses private CGS APIs and undocumented `CGEventField` constants

### PR #3859 (mogenson, Mar 2026)

Open PR to Hammerspoon adding the undocumented `CGEventField` constants and fixing `setProperty()` to allow the gesture technique from pure Lua. Would enable experimentation but doesn't solve the per-display targeting problem.

### Comparison table

| Aspect | `gotoSpace(spaceID)` | window:focus() #3823 | ISS gesture #3850 |
|---|---|---|---|
| Targets specific non-focused display | Yes (via space ID) | No (focuses that window) | No (active display only) |
| No animation | No (slide animation) | Yes (instant) | Yes (instant) |
| Works on empty spaces | Yes | No (falls back) | Yes |
| Doesn't steal focus | Yes | No | Unknown |
| SIP required | No | No | No |
| Private APIs | Yes (via hs.spaces) | No (standard HS) | Yes (CGS + undoc CGEvent fields) |
| Suitable for our multi-monitor sync | Yes (only option) | No | No |

### Bottom line

`hs.spaces.gotoSpace()` is the only mechanism that accepts a space ID that implicitly targets the correct display. The 0.3s delay and Mission Control animation are currently unavoidable for our use case. The only thing that would change this is an undocumented private API that takes both a display ID and a space index — no such API is known to exist.

## GC, Timers, and Watchers

### Our patterns are correct

The `state` table pattern (module-level table holding references to watchers and timers) is exactly the recommended approach per discussions #3434 and #3437.

| Pattern | Our Status |
|---|---|
| Timers stored in persistent references | Safe — `state.pendingSyncTimer`, `state.debounceTimer` |
| Watcher stored in persistent reference | Safe — `state.spaceWatcher` |
| Old timer stopped before replacement | Safe — debounceTimer stopped at line 381; pendingSyncTimer already fired |
| Old watcher stopped before new one | Safe — `setupWatcher()` stops existing first |
| pcall around private APIs | Safe — `gotoSpace()` wrapped in pcall |

### Reload behavior (Discussion #3680)

On `hs.reload()`, Hammerspoon destroys the entire Lua state. All watchers, timers, and eventtaps are cleaned up automatically. No manual cleanup needed.

### Edge case: reload during sync chain

If `hs.reload()` happens mid-sync, the already-dispatched `gotoSpace()` completes on the macOS side, but the new Lua state has no debounce running. The watcher might see the programmatic switch as a user-initiated change. Harmless in practice — the sync would be a no-op since monitors are already at the right index.

## Monitor Identification

### Discussion #3809: HDMI matrix

`hs.screen:name()` returns nil after HDMI matrix switch, but `hs.screen:getUUID()` remains stable. We identify monitors by UUID (via `rebuildPositionMap()`), so we're fine.

## Sources

| # | Type | Title | Relevance |
|---|---|---|---|
| #3823 | Discussion | Speed up gotoSpace with window:focus() | Performance optimization |
| #3850 | Issue | Instant space switching (InstantSpaceSwitcher) | Alternative switching mechanism |
| #2776 | Issue | Thoughts on a new approach to spaces | Architecture of hs.spaces |
| #3698 | Issue | moveWindowToSpace broken on Sequoia | API fragility signal |
| #3506 | Discussion | Future of the project | Maintenance status |
| #3805 | Discussion | Is this project dead? | Project health |
| #3434 | Discussion | Avoiding GC of timers | Timer safety patterns |
| #3437 | Discussion | Watchers and resource efficiency | Watcher architecture |
| #3680 | Discussion | Watchers auto-stop on reload? | Reload safety |
| #3673 | Discussion | Resilient auto config loading | Error handling patterns |
| #3809 | Discussion | HDMI matrix and screen names | Monitor identification |
