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

## Features

- [ ] Publish to GitHub
- [ ] Submit to Hammerspoon Spoons repository (http://www.hammerspoon.org/Spoons/)
