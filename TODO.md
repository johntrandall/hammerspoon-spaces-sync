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

## Test automation gaps (post-session 2026-05-10/05-11)

Discovered during the test-suite-extension session. See
`dev-docs/field-reports/2026-05-10-test-suite-extension.md` for
context.

### High-priority L6 automation (patterns proven, ~1-2 hours)

- [x] **Scenario 06** — User swipes a TARGET display mid-chain. Landed
  in commit 7ad93f8. AppleScript ⌃-rightArrow at TARGET cursor.
  Verifier flags target drift (expectedIdx=2, actualIdx=3).
- [x] **Scenario 07** — User swipes an INDEPENDENT display mid-chain.
  Landed in commit 7ad93f8. Proves verifier coverage extends to
  non-sync-group displays via `captureExpectedEndState()`'s
  connected-displays snapshot.
- [x] **Scenario 09** — Mid-chain toggle hotkey. Landed in commit
  7b3e8b3. Uses disrupt-phase to call `:toggle()` mid-chain; verifies
  chain halts cleanly + re-toggle restores sync.
- [x] **Scenario 10** — Rapid double-toggle. Landed in commit 7b3e8b3.
  Verifies BOTH halves of the chainGeneration contract — `:stop()`
  bumps gen by +1 (init.lua:1747), `:start()` resets gen to 0
  (init.lua:1709). Mid-arm gen capture required because final state
  alone is indistinguishable from "never advanced".
- [x] **Scenario 24** — Misconfigured `syncGroups` (out-of-range
  position). Landed in commit bdb1c4f. Uses `M.required_syncGroups
  = {{1, 5}}`. Console-tail check runs in `assert_()` rather than
  `probe()` because `hs.logger` writes through `hs.console`
  asynchronously — by `assert_()` the >=8s SLEEP_BETWEEN has given
  the logger plenty of time to flush.

### Hard-but-feasible L6 automation (revisit when needed, ~1 hour each)

- [x] **Scenario 16** — Forced timeout (done 2026-05-11, commit
  `772b6b4`). Implemented the `:stop()`-race-prevention approach from
  the field report. `M.required_pollTimeout=0.01` +
  `M.required_pollInterval=0.005` via the dispatcher; arm fires
  gotoSpace, chain times out per-target, MID_SLEEP=1s, disrupt calls
  `:stop()` to suppress the late-watcher second chain, assert verifies
  target wrong-space mismatch.
- [ ] **Scenario 20** — Display sleep + wake. `pmset displaysleepnow`,
  shell sleep 30s, observe activeSpaces still tracks correctly.
- [ ] **Scenario 21** — `hs.reload()` mid-chain. Complex because the
  test process loses its Lua state on reload; needs out-of-band
  verification via a marker file.
- [ ] **Scenario 18** — Add a Space via Mission Control mid-chain.
  Needs AX scripting on the Mission Control "+" button. Fragile;
  defer.

### Irreducibly manual (will never be automated)

These require human action or visual judgment. Run as part of
pre-release manual checklist sample:

- [ ] **C #11-15** — Physical display reconfig (plug/unplug, lid
  close, rearrange in System Settings).
- [ ] **E #22, #23** — Accessibility revoke via System Settings →
  Privacy & Security → Accessibility. macOS deliberately doesn't
  expose this toggle to APIs.
- [ ] **F #27** — Rename hotkey dialog appearance.
- [ ] **F #28** — Status HUD on toggle (ON/OFF text legibility).
- [ ] **F #29** — Popup after sync (positioning, name rendering).
- [ ] **F #30** — Status HUD on display reconfig.

### Known flakiness to address

- [x] **Scenario 02 intermittent failure** — target on pos 2 ends
  at idx 2 instead of following to idx 1. Observed once in the
  L6_inclusive subagent run on 2026-05-11; not reproducible after
  a clean state reset. Hypothesis: a stale chain from a prior
  partial run was interleaving. The L6 dispatcher's EXIT-trap
  snapshot/restore mitigates this. **Confirmed 2026-05-11:** 5
  consecutive L6 runs (with the EXIT-trap reset in place) all
  passed scenario-02 cleanly. Closed.

## Release v0.3 — pre-publish checklist

Per `dev-docs/publication-checklist.md`. Test infrastructure
landed on main since v0.3 tag; Spoon code is unchanged from tag.

- [x] `TESTED_OS` bumped to 15.7.5 (commit d935d49)
- [x] Distribution artifacts rebuilt (`Spoons/SpacesSync.spoon.zip`,
  `docs/docs.json`) — commit d935d49
- [x] All four test levels green on the bumped version
- [ ] **Push 48-commit backlog to origin**: `git push origin main`
  + `git push umbridge main`
- [ ] **Decide tagging strategy**: re-tag v0.3 at HEAD (preferred —
  never publicly released) OR cut a new tag (v0.3.1 / v0.4)
- [ ] `gh release create v0.3 Spoons/SpacesSync.spoon.zip` (with
  release notes covering v0.2 → v0.3 changes: verify-based timing
  per F-010, etc.)
- [ ] Sync `~/dev/Spoons` fork (`add-spaces-sync-spoon` branch):
  copy `init.lua` + `docs.json` from this repo, commit, push.
  Updates Hammerspoon/Spoons PR #361 automatically.
- [ ] Manual checklist pass (the irreducible-manual items above)
  before announcing the release.
