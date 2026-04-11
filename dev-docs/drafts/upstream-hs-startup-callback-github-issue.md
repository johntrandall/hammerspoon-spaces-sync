# Feature request: `hs.startupCallback` symmetric to `hs.shutdownCallback`

## TL;DR

I'd like an `hs.startupCallback` variable, symmetric to the existing `hs.shutdownCallback`, that fires on the next main-queue tick after `MJLuaCreate()` returns from `applicationDidFinishLaunching:`. This would give `init.lua` and Spoon `:start()` methods a clean place to put UI that interacts with the window server (canvas, drawing, alerts shown during startup).

## Problem

I'm writing a [Hammerspoon Spoon](https://github.com/johntrandall/hammerspoon-spaces-sync) whose `:start()` method creates an `hs.canvas` HUD and calls `canvas:show()` on it. When `:start()` is invoked synchronously from `init.lua` — which is the normal case on `hs.reload()` for Spoons bound via `:bindHotkeys(...)` and immediately started — the canvas is created but `:show()` has no visible effect. The window never appears. No error, no log, nothing in the Console.

A minimal repro, pasted into a fresh `~/.hammerspoon/init.lua`:

```lua
local c = hs.canvas.new({x=100, y=100, w=300, h=120})
c:level(hs.canvas.windowLevels.overlay)
c:behavior({"canJoinAllSpaces", "stationary"})
c:appendElements({
  type = "rectangle", action = "fill",
  fillColor = {red = 30/255, green = 30/255, blue = 32/255, alpha = 0.92},
  roundedRectRadii = {xRadius = 14, yRadius = 14},
  frame = {x = 0, y = 0, w = 300, h = 120},
})
c:appendElements({
  type = "text",
  text = hs.styledtext.new("Hello from init.lua", {
    font = {name = "Helvetica-Bold", size = 24},
    color = {white = 1, alpha = 1},
    paragraphStyle = {alignment = "center"},
  }),
  frame = {x = 20, y = 40, w = 260, h = 40},
})
c:show()                                     -- invisible after hs.reload()
hs.timer.doAfter(5, function() c:delete() end)
```

Reload Hammerspoon with `hs.reload()`. The canvas is never visible. Wrapping the `c:show()` in `hs.timer.doAfter(0, function() c:show() end)` — a zero-delay timer — makes it appear reliably.

## What I think is happening

As far as I can tell from reading `MJAppDelegate.m` and `MJLua.m` on current `master`:

1. `applicationDidFinishLaunching:` calls `MJLuaCreate()` near the end of its own body.
2. `MJLuaCreate()` → `MJLuaInit()` runs `setup.lua` and loads `init.lua` **synchronously, still inside the delegate method**.
3. The AppKit main runloop does not get a chance to pump any pending events until `applicationDidFinishLaunching:` returns.
4. My `canvas:show()` reaches `[canvasWindow makeKeyAndOrderFront:nil]` during that in-delegate window, before the runloop has completed the window-server handshake with the new NSWindow. The call returns without error, but the window never becomes visible.
5. `hs.timer.doAfter(0, ...)` defers the show call to the next main-queue tick, which is after the delegate method has returned and the runloop has pumped a round of events. At that point the window server is ready and `:show()` works.

If I'm reading the source wrong, please tell me — I'd welcome a correction.

## What I tried first

Before writing this up I spent a while trying to find an existing solution and disprove my own premise. I wanted to rule out "I'm missing an obvious API":

- **Grepped current `master` for lifecycle hooks.** The only variables that call back from C-land into Lua are `accessibilityStateCallback`, `dockIconClickCallback`, `textDroppedToDockIconCallback`, `fileDroppedToDockIconCallback`, and `shutdownCallback`. No startup/ready/loaded/reload callback.
- **Introspected the `hs` table at runtime** with `hs -c 'for k,v in pairs(hs) do ... end'` — same answer. Nothing matching `callback`/`ready`/`startup`/`init`/`load` beyond the five C callbacks and the functions `loadSpoon`, `reload`, `uploadCrashData`.
- **Checked `hs.canvas` instance methods** via `hs -c` and the docs — no `waitForWindowServer`, no async-show, no `showWhenReady`, no readiness flag. `show()` is a direct synchronous `[canvasWindow makeKeyAndOrderFront:nil]` per `extensions/canvas/libcanvas.m`.
- **Read the Getting Started guide, FAQ, `SPOONS.md`, the hammerspoon.org Spoons page, and the wiki.** None document a lifecycle pattern for "UI at start time" or mention that canvases created in init.lua race the window server.
- **Searched open + closed issues, PRs, and GitHub Discussions** for `startupCallback`, `startup callback`, `reload callback`, `ready callback`, `canvas not visible`, `alert not showing init`, `applicationDidFinishLaunching`, `didFinishLaunching`, `config loaded`, `initCallback`, `loadedCallback`, and `lifecycle callback`. Zero hits for a prior feature request or discussion of the init-time race. I did find #2709, #3309, and #2809 (other canvas edge cases) but none match.
- **Surveyed the official Spoons repo** for Spoons that create a canvas in `:start()` and show it directly. Several `doAfter(0)` workarounds exist (`TurboBoost`, `MicMute`, `AClock`, `FadeLogo`, `InputMethodIndicator`) but I couldn't find a Spoon that calls `canvas:show()` synchronously from `:start()` on a fresh reload and works. The ones that do show UI at start time either bind a hotkey first (so `:show()` happens later on user action) or use `hs.alert` (which has its own path).

**If I missed an existing mechanism — runtime, API, or convention — please close this and point me at it. I would genuinely prefer to learn I was wrong than to add API surface.**

## Proposed API

Add `hs.startupCallback` next to `hs.shutdownCallback` in `extensions/_coresetup/_coresetup.lua`, and invoke it via a new `callStartupCallback()` helper in `MJLua.m` (mirroring the existing `callShutdownCallback()`).

In `MJAppDelegate.m`'s `applicationDidFinishLaunching:`, immediately after `MJLuaCreate()`, schedule the call on the main queue so it fires after the delegate method returns and the runloop has pumped a round of events:

```objc
MJLuaCreate();
dispatch_async(dispatch_get_main_queue(), ^{
    callStartupCallback();
});
```

Documentation: *"An optional function called on the next main-queue tick after `init.lua` has loaded and Hammerspoon has finished launching (or finished reloading), at which point the window server is ready to display canvases, drawings, alerts, and webviews created during init."* Should fire on both the initial launch and on `hs.reload()`.

This would eliminate the `doAfter(0)` workaround that several Spoons currently use for init-time UI, and it gives us a clean semantic primitive instead of an implementation-detail timer.

## Environment

- Hammerspoon 1.1.1
- macOS 15.5.0 (Sequoia)
- Happy to open a PR for this if the design is welcome.

## Related

- Workaround and research are documented in my Spoon's quirks notes: https://github.com/johntrandall/hammerspoon-spaces-sync/blob/main/dev-docs/hammerspoon-and-spaces-quirks.md#no-reload-complete-callback--use-doafter0-for-init-time-ui
- `hs.shutdownCallback` is the existing symmetric half: https://www.hammerspoon.org/docs/hs.html#shutdownCallback
