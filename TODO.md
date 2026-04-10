# TODO

## Verify macOS Settings (from dev-docs/findings/macos-spaces-settings.md)

Settings marked as logically inferred or suspected need isolated testing — toggle the one setting, observe the effect, update confidence to Verified.

### High Priority

- [x] **#1 Displays have separate Spaces** — ~~logically inferred~~ **Verified**: sync does not work without this.
- [ ] **#2 Auto-rearrange Spaces** (logically inferred) — Set `mru-spaces` to `1`, create 3+ Spaces, use them in varying order, check if `hs.spaces.spacesForScreen()` indices shift over time.
- [ ] **#3 Switch to app's Space (auto-swoosh)** (logically inferred) — Enable `workspaces-auto-swoosh`, Cmd-Tab to an app on a different Space, observe if SpacesSync fires a cascade sync.
- [ ] **#5 Fullscreen Spaces** (suspected) — Make an app fullscreen on one synced monitor, switch Spaces on another. Does `spacesForScreen()` include fullscreen Spaces in its index? Does the index mapping between monitors break?

### Medium Priority

- [ ] **#4 Stage Manager** (suspected) — Enable Stage Manager, test basic sync behavior. Does `activeSpaceOnScreen()` still report correctly?
- [ ] **#8 Reduce Motion** (suspected) — Enable Reduce Motion, test if `switchDelay` can be reduced below 0.3s without dropped switches.

### Low Priority

- [x] **#6 All Desktops apps** — ~~logically inferred~~ **Verified**: apps on All Desktops do not affect sync.
- [ ] **#9 Mission Control disabled** (logically inferred) — Set `mcx-expose-disabled` to true, verify the Spoon blocks gracefully on start.
- [ ] **#10 Expose animation duration** (suspected) — Set a custom animation duration, verify `gotoSpace()` timing is unaffected.

## Compatibility Testing

- [ ] **macOS 26 Tahoe** — test basic sync behavior once Tahoe ships. hs.spaces uses private APIs that are likely to change. Assume broken until tested.

## Known Issues

- [ ] **"SpacesSync: ON" status display invisible after `hs.reload()`** — The existing `hs.alert.show("SpacesSync: ON")` in `:start()` fires during init.lua but is either invisible, too brief, or gets dropped because Hammerspoon runs init.lua synchronously *before* NSApplication finishes its first `applicationDidFinishLaunching` cycle. UI created at that moment races the window server handshake.

  **Root cause (Verified via source-level research):** Hammerspoon has no `startupCallback` / `readyCallback` / "config loaded" event. Only `hs.shutdownCallback` exists. Confirmed by reading `MJLua.m` and `extensions/_coresetup/_coresetup.lua` in `Hammerspoon/hammerspoon`.

  **Proposed fix (Observed idiom in official Spoons, not yet tested in this repo):**
  1. Replace `hs.alert.show("SpacesSync: ON")` with a canvas-based status HUD matching the popup's visual style (dark rounded panel, HUD level, 3s duration).
  2. Defer the call via `hs.timer.doAfter(0, function() showStatusHUD("SpacesSync: ON") end)`. A zero-delay timer yields to the next runloop tick, which is the canonical Hammerspoon idiom for "let the window server settle" (see TurboBoost, MicMute, AClock, FadeLogo Spoons). **Not** `doAfter(0.1)` — that's magic-number padding.
  3. Update `dev-docs/hammerspoon-and-spaces-quirks.md` with a new section documenting the init-time canvas visibility race and the `doAfter(0)` workaround.
  4. (Optional) File an upstream feature request for `hs.startupCallback` as a symmetric counterpart to `hs.shutdownCallback`. No existing issue today.

## Features

- [ ] Publish to GitHub
- [ ] Submit to Hammerspoon Spoons repository (http://www.hammerspoon.org/Spoons/)
