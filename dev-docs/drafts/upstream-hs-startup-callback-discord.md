# Discord draft — #hammerspoon channel

Hi everyone 👋 Quick question before I file a GitHub issue, in case I'm missing something obvious.

I'm writing a Spoon whose `:start()` method creates an `hs.canvas` HUD and calls `canvas:show()` on it. When `:start()` is invoked synchronously from `init.lua` (the normal case on `hs.reload()` when the Spoon is started immediately after loading), the canvas is created but `:show()` has no visible effect — no error, no log, just invisible.

Wrapping the call in `hs.timer.doAfter(0, function() canvas:show() end)` fixes it reliably. Reading `MJAppDelegate.m` + `MJLua.m` on master, I *think* the reason is that `MJLuaCreate()` is called near the end of `applicationDidFinishLaunching:`, so `init.lua` runs synchronously inside that delegate method, and the AppKit runloop hasn't had a chance to pump the window-server handshake for the new `NSWindow`. The `doAfter(0)` defers to the next main-queue tick, which is after the delegate returns.

**My question:** Is there a documented way to hook "runtime is ready / window server handshake complete" that I've overlooked? I checked:

- the `hs` table at runtime via `hs -c` — only found the five C callbacks (`shutdownCallback` + 4 dock/accessibility ones)
- `hs.canvas` for a `waitForWindowServer` / `showWhenReady` / async variant — nope
- issues + PRs + Discussions for `startupCallback`, `reload callback`, `canvas not visible`, etc. — nothing relevant
- SPOONS.md, Getting Started, FAQ, the wiki — nothing about init-time UI timing

If the answer is "no, use `doAfter(0)`, that's the way", I'll file a feature request for a proper `hs.startupCallback` symmetric to `hs.shutdownCallback`. If the answer is "yes, use X", please point me at X and I'll drop the issue.

Minimal repro (paste in a fresh init.lua, reload — canvas never appears, remove the `c:show()` line and replace it with `hs.timer.doAfter(0, function() c:show() end)` and it does):

```lua
local c = hs.canvas.new({x=100, y=100, w=300, h=120})
c:level(hs.canvas.windowLevels.overlay)
c:behavior({"canJoinAllSpaces", "stationary"})
c:appendElements({type="rectangle", action="fill",
  fillColor={red=30/255, green=30/255, blue=32/255, alpha=0.92},
  roundedRectRadii={xRadius=14, yRadius=14},
  frame={x=0, y=0, w=300, h=120}})
c:appendElements({type="text",
  text=hs.styledtext.new("Hello from init.lua",
    {font={name="Helvetica-Bold", size=24}, color={white=1, alpha=1},
     paragraphStyle={alignment="center"}}),
  frame={x=20, y=40, w=260, h=40}})
c:show()
hs.timer.doAfter(5, function() c:delete() end)
```

Hammerspoon 1.1.1 on macOS 15.5. Thanks!
