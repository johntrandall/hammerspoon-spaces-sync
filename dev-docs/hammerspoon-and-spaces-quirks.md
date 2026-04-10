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

## hs.spaces.watcher callback argument is always -1

The `hs.spaces.watcher.new(callback)` passes an integer to the callback that is documented as the new space ID — but in practice it's always `-1` on macOS 15.x. This is a known issue (see Hammerspoon issues #3250 and #3489, both open as of 2026).

**Fix:** Ignore the callback argument entirely. Inside the callback, call `hs.spaces.activeSpaces()` to get a `{screenUUID: spaceID}` map, then diff against a saved snapshot to find which screen changed.

```lua
local lastActiveSpaces = hs.spaces.activeSpaces()
hs.spaces.watcher.new(function()  -- ignore the argument
  local current = hs.spaces.activeSpaces()
  for uuid, spaceID in pairs(current) do
    if lastActiveSpaces[uuid] ~= spaceID then
      -- this screen changed spaces
    end
  end
  lastActiveSpaces = current
end):start()
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

As of macOS 15.5, `hs.spaces.moveWindowToSpace()` does not work. Apple NOP'd three WindowServer functions that the Sonoma 14.5 workaround relied on (confirmed in issue #3698 by the yabai contributor who originally provided the fix). The remaining functions require Dock.app-level rights.

Returns `true` but does nothing. This is different from `gotoSpace()`, which uses accessibility automation of Mission Control rather than private WindowServer APIs — and still works on Sequoia.

Workarounds for window-moving involve click-hold simulation with `hs.eventtap` (fragile), the Drag.spoon approach (AX manipulation of Mission Control, flickery), or shelling out to yabai. Not used in this module but relevant for related window-management work.

## gotoSpace() vs moveWindowToSpace() — different mechanisms

`gotoSpace()` and `moveWindowToSpace()` look similar but work completely differently:

- **`gotoSpace()`:** Uses `hs.axuielement` to programmatically open Mission Control, find the target space button via accessibility APIs, click it, and close Mission Control. This is why it's slow (visible animation). But it also means it's NOT affected by the private WindowServer API breakage — accessibility APIs are more stable.

- **`moveWindowToSpace()`:** Uses private WindowServer functions directly. These got NOP'd in Sequoia.

This is why our module (which uses `gotoSpace()`) still works on Sequoia even though `moveWindowToSpace()` is broken.

## hs.reload() during a sync chain

If `hs.reload()` is triggered mid-sync, the already-dispatched `gotoSpace()` call still completes on the macOS side (macOS doesn't know Hammerspoon reloaded). The new Lua state starts fresh with no `debounceTimer` and `syncInProgress = false`, so the new watcher might see the completed programmatic switch as a user-initiated change.

In practice this is harmless — the resulting sync would be a no-op because all target monitors are already at the correct index. But if you see an unexpected sync right after a reload, this is likely the cause.

## Monitor position numbers are unstable

macOS assigns display numbers (the parenthetical in names like "LG SDQHD (2)") arbitrarily and can reassign them when cables are reconnected or the machine reboots. Don't rely on these for identification.

**Fix:** Identify monitors by screen frame position (x, y coordinates from `screen:frame()`), which reflects the physical arrangement set in System Settings > Displays. This module sorts by x then y to assign stable position numbers.

## No "reload complete" callback — use doAfter(0) for init-time UI

Hammerspoon has no `startupCallback` / `readyCallback` / "config loaded" event. The only lifecycle hook is `hs.shutdownCallback` (fires when the Lua environment is being destroyed, either on exit or reload).

**Verified** at runtime (`hs -c` introspection of the `hs` table) and at source level (current `master` of `Hammerspoon/hammerspoon`) by reading `MJLua.m`, `MJAppDelegate.m`, `extensions/_coresetup/_coresetup.lua`, and `extensions/canvas/libcanvas.m`. The only C→Lua lifecycle callbacks are `accessibilityStateCallback`, `dockIconClickCallback`, `fileDroppedToDockIconCallback`, `textDroppedToDockIconCallback`, and `shutdownCallback`. `hs.canvas` has no `waitForWindowServer` / `showWhenReady` / async-show variant.

### Why `:show()` silently fails during init.lua

`applicationDidFinishLaunching:` in `MJAppDelegate.m` calls `MJLuaCreate()` near the end of its own body. `MJLuaCreate()` runs `setup.lua` which loads and executes `init.lua` **synchronously, still inside the delegate method**. Because Lua runs inside an AppKit delegate callback, the main runloop does not get a chance to pump any pending events until `applicationDidFinishLaunching:` returns. A `canvas:show()` in `init.lua` therefore reaches `[canvasWindow makeKeyAndOrderFront:nil]` before the window server has completed its handshake with the new NSWindow — the call returns without error, but the window never becomes visible.

### Fix: defer to the next runloop tick with `doAfter(0)`

```lua
-- BAD: canvas created in init.lua is silently dropped after hs.reload()
function obj:start()
  ...
  hs.canvas.new({...}):show()  -- vanishes
end

-- GOOD: defer to next runloop tick
function obj:start()
  ...
  hs.timer.doAfter(0, function() hs.canvas.new({...}):show() end)
end
```

A zero-delay `hs.timer` is the canonical Hammerspoon idiom for "yield once and resume on the next main-queue tick." By that tick, `applicationDidFinishLaunching:` has returned, AppKit has pumped a round of events, and the window server is ready to display newly-created windows. Used throughout the official Spoons repo (`TurboBoost`, `MicMute`, `AClock`, `FadeLogo`, `InputMethodIndicator`) for the same class of problem.

**Not** `hs.timer.doAfter(0.1, ...)` — that's magic-number padding. The `0` version is semantically correct: it means "yield to the runloop once."

`hs.alert.show()` from init.lua usually works because it goes through a separate path that handles deferral internally — but it can still be unreliable immediately after `hs.reload()`. When in doubt, defer with `doAfter(0)`.

### Upstream feature request

If Hammerspoon adds an `hs.startupCallback` symmetric to `hs.shutdownCallback`, this entire section can be deleted. The fix is straightforward — after `MJLuaCreate()` in `applicationDidFinishLaunching:`, schedule a `callStartupCallback()` helper via `dispatch_async(dispatch_get_main_queue(), ...)` so it fires on the next main-queue tick (i.e., after the delegate method has returned and the runloop has pumped). Three to five lines of code. No upstream issue existed as of 2026-04-10 — filing one would be a clean contribution.

## Hammerspoon API conventions

- All APIs use **camelCase** naming
- Pure Lua extensions return a table of functions
- Third-party modules install to `~/.hammerspoon/` and load via `require()`
- Docstrings use `---` prefix (Lua) or `///` (Objective-C)
