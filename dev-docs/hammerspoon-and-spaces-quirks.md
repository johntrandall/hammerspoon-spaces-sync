# Hammerspoon and macOS Spaces Quirks

Lessons learned building spaces-sync on macOS 15.5 (Sequoia) with Hammerspoon 1.1.1. Useful for anyone working with `hs.spaces` or multi-monitor Space automation.

## hs.spaces uses private APIs

`hs.spaces` is built on top of undocumented macOS APIs. Apple can and does change these between point releases. What works on 15.5 may break on 15.6 or 16.0. There is no public API for programmatic Space switching.

## hs.spaces.gotoSpace() is asynchronous

`gotoSpace(spaceID)` returns immediately, but the actual Space switch happens later (during the next run loop cycle or after an animation). This means you **cannot** verify a switch by calling `activeSpaceOnScreen()` right after — it will still return the old space.

```lua
hs.spaces.gotoSpace(targetSpaceID)
-- This check is UNRELIABLE:
local current = hs.spaces.activeSpaceOnScreen(screen)
-- 'current' may still be the OLD space
```

If you need to verify, either:
- Wait (e.g., `hs.timer.doAfter(0.5, ...)`) and then check
- Accept that the post-sync snapshot taken a bit later is the real source of truth

## Rapid gotoSpace() calls get silently dropped

If you call `gotoSpace()` for multiple monitors in a tight loop, macOS will silently drop some of the calls. The first switch works, subsequent ones don't — no error, no callback, just nothing happens.

**Fix:** Chain calls with a delay between each one. 300ms works reliably in testing.

```lua
-- BAD: second call gets dropped
hs.spaces.gotoSpace(spaceOnMonitor2)
hs.spaces.gotoSpace(spaceOnMonitor3)  -- silently ignored

-- GOOD: chain with delay
hs.spaces.gotoSpace(spaceOnMonitor2)
hs.timer.doAfter(0.3, function()
  hs.spaces.gotoSpace(spaceOnMonitor3)
end)
```

## hs.spaces.watcher fires for programmatic changes too

The space watcher doesn't distinguish between user-initiated space switches and ones triggered by `gotoSpace()`. If your watcher calls `gotoSpace()`, that triggers the watcher again — infinite loop.

**Fix:** Use a flag (`syncInProgress`) to ignore watcher events during programmatic switches, and a debounce timer to re-enable the watcher after things settle.

## Stale state after programmatic switches

`hs.spaces.activeSpaces()` returns a snapshot. If you capture it before calling `gotoSpace()` and then compare it to the next watcher event, you'll see the programmatic switches as "changes" — and try to sync based on them, causing a cascade.

**Fix:** Re-snapshot `activeSpaces()` after completing all programmatic switches, so the watcher's baseline reflects what you just did.

## Lazy extension loading adds latency

Hammerspoon lazy-loads extensions on first use. If the first call to `hs.screen` or `hs.application` happens inside a time-sensitive watcher callback, the load adds hundreds of milliseconds of latency — which can push your switch timing past the window where macOS accepts it.

**Fix:** `require()` all needed extensions at module load time:

```lua
require("hs.screen")
require("hs.spaces")
require("hs.application")
require("hs.timer")
```

## hs.spaces.moveWindowToSpace() is broken on Sequoia

As of macOS 15.5, `hs.spaces.moveWindowToSpace()` does not work. This is a known issue. Workarounds involve click-hold simulation with `hs.eventtap`, which is fragile. Not used in this module but relevant for related window-management work.

## Monitor position numbers are unstable

macOS assigns display numbers (the parenthetical in names like "LG SDQHD (2)") arbitrarily and can reassign them when cables are reconnected or the machine reboots. Don't rely on these for identification.

**Fix:** Identify monitors by screen frame position (x, y coordinates from `screen:frame()`), which reflects the physical arrangement set in System Settings > Displays. This module sorts by x then y to assign stable position numbers.

## Hammerspoon API conventions

- All APIs use **camelCase** naming
- Pure Lua extensions return a table of functions
- Third-party modules install to `~/.hammerspoon/` and load via `require()`
- Docstrings use `---` prefix (Lua) or `///` (Objective-C)
