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

## Picker polish

- [x] **Evaluate picker canvas flicker** — **Verified (2026-04-10):** fluid, no flicker observed during interactive navigation. Full-canvas rebuild in `buildPopupCanvas()` is fast enough in practice; the in-place-mutation refactor is not warranted.

## Upstream requests

- [ ] **Upstream request: `hs.startupCallback`** (drafted, not sent) — Hammerspoon has `hs.shutdownCallback` but no symmetric startup hook. Adding one would eliminate the `doAfter(0)` workaround documented in `dev-docs/hammerspoon-and-spaces-quirks.md`. Clean one-function ask against `MJLua.m`.

  **Research (Verified 2026-04-10, source-level + runtime introspection):** No such callback exists in current `master`. Confirmed by reading `MJLua.m`, `MJAppDelegate.m`, `_coresetup.lua`, `libcanvas.m` and by `hs -c` introspection of the `hs` table. The only C→Lua lifecycle callbacks are the five documented ones (`accessibilityStateCallback`, `dockIconClickCallback`, `textDroppedToDockIconCallback`, `fileDroppedToDockIconCallback`, `shutdownCallback`). `hs.canvas` has no `waitForWindowServer` / `showWhenReady` / async-show variant. No existing issue, PR, or Discussion mentions this.

  **Drafted but NOT sent — review and send when ready:**
  * GitHub issue body: [`dev-docs/drafts/upstream-hs-startup-callback-github-issue.md`](dev-docs/drafts/upstream-hs-startup-callback-github-issue.md) — title `Feature request: hs.startupCallback symmetric to hs.shutdownCallback`. File via `gh issue create --repo Hammerspoon/hammerspoon --title "..." --body-file dev-docs/drafts/upstream-hs-startup-callback-github-issue.md`.
  * Discord draft: [`dev-docs/drafts/upstream-hs-startup-callback-discord.md`](dev-docs/drafts/upstream-hs-startup-callback-discord.md) — shorter, chat-appropriate, asks "am I missing something?" before filing. Post in `#hammerspoon` on https://discord.gg/vxchqkRbkR (the official server — confirmed active, maintainers present).

  **Recommended send sequence:** Post the Discord message first for a fast informed opinion. Wait 24-48 hours. File the GitHub issue regardless — chat answers aren't durable and future users searching for this problem need the permanent record. Google Group (`groups.google.com/g/hammerspoon`) is the secondary fallback; maintainer posted there as recently as Dec 2025. GitHub Discussions is technically enabled but nearly dormant.

## Design decisions to revisit

- [ ] **Space-name group keys: position-based vs UUID-based** — Names are keyed by the sorted comma-joined position numbers of the name group (e.g. `"2,3,4"` for a sync group, `"1"` for an independent monitor). This matches the positional identity the user writes in `syncGroups`, but has stability weaknesses.

  **Pros of positions (current choice):**
  * Consistent with how `syncGroups` is configured — the key is literally the `syncGroups` entry joined.
  * Human-readable in `hs.settings` dumps.
  * Stable across reboots as long as monitor physical arrangement is unchanged.
  * No extra indirection via UUIDs.

  **Cons of positions:**
  * Rearranging monitors in System Settings > Displays changes position numbers (reading order) and orphans stored names.
  * Adding or removing a monitor shifts positions for every monitor to its right, orphaning all names.
  * Changing `syncGroups` to add/remove a position from a group changes the key entirely; names stay persisted but are no longer reached.

  **Alternative: sorted-set-of-UUIDs hash as the key.**
  * Pros: survives position reshuffles. Rearranging displays in System Settings doesn't change UUIDs; neither does re-plugging. More stable in practice.
  * Cons: opaque in settings dumps. Doesn't survive monitor replacement (new UUID). Breaks if the user intentionally changes sync group membership (same problem as positions).

  **Neither is perfect** — the core question is whether physical rearrangement (position churn) or config churn (`syncGroups` edits) is the more common invalidation event. For John's setup (4 stable monitors, rarely reconfigured), positions are fine. Revisit if anyone hits orphaned-names pain.

## Features

- [ ] Publish to GitHub
- [ ] Submit to Hammerspoon Spoons repository (http://www.hammerspoon.org/Spoons/)
