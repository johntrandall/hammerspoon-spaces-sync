# TODO: Approaches to Evaluate

Generated from Hammerspoon discussions research (2026-04-09).
See `dev-docs/findings/hammerspoon-discussions-research.md` for source citations.

## High priority

### 1. Evaluate window:focus() fast-switching (from #3823)

**Hypothesis:** Using `window:focus()` on a known window in the target space avoids the Mission Control animation and dramatically reduces `switchDelay` requirements — possibly eliminating the rapid-fire drop problem entirely.

**Evaluation steps:**
- [ ] Prototype a window-per-space cache maintained by the watcher
- [ ] Test if `window:focus()` on a non-focused monitor's window triggers a space switch on THAT monitor (key question for our use case)
- [ ] Measure timing vs. `gotoSpace()` — how much faster?
- [ ] Fall back to `gotoSpace()` for empty spaces
- [ ] Determine if the window cache needs rebuilding on `hs.screen.watcher` events

**If it works:** Could replace `gotoSpace()` entirely or become the primary path with `gotoSpace()` as fallback.

### 2. Evaluate InstantSpaceSwitcher integration (from #3850)

**Hypothesis:** Private `CGSManagedDisplaySetCurrentSpace` API switches spaces instantly without Mission Control animation. If we can call it (directly or via shelling out), we'd eliminate the need for `switchDelay` and `debounceSeconds` tuning.

**Evaluation steps:**
- [ ] Review jurplel/InstantSpaceSwitcher source — does it take a monitor target, or just current monitor?
- [ ] Does it work on Sequoia 15.5? On Tahoe?
- [ ] Does it require SIP disabled?
- [ ] Could we bundle a pre-built helper binary in the Spoon and shell out via `hs.task`?
- [ ] Would Hammerspoon/Spoons accept a Spoon that bundles a binary?
- [ ] Alternative: port the CGS calls to Lua via `hs.axuielement` or direct ObjC bridging?

**If it works:** Sub-100ms sync across any number of monitors, no animation flicker.

### 3. Write a Tahoe compatibility test

**Hypothesis:** We claim "assumed broken on Tahoe" in the README but have no data. One user reports general Hammerspoon works on Tahoe but no `hs.spaces` specifics.

**Evaluation steps:**
- [ ] Find someone with a Tahoe machine willing to test
- [ ] Or spin up a Tart VM with Tahoe and test
- [ ] Document exactly which `hs.spaces` functions work/fail
- [ ] Update README with findings
- [ ] If it works, update `TESTED_OS` and remove the "not working" warning

## Medium priority

### 4. Document reload-during-sync edge case

**Observation:** If `hs.reload()` happens mid-sync-chain, the already-dispatched `gotoSpace()` completes on the macOS side. The new Lua state has no debounce running, so the watcher might see it as a user-initiated change. Harmless (would be a no-op since already at target) but worth documenting.

**Action:**
- [ ] Add a note to `dev-docs/hammerspoon-and-spaces-quirks.md`
- [ ] No code changes needed

### 5. Consider falling back to yabai for moveWindowToSpace (if we ever add that feature)

**Context:** Multiple maintainer comments suggest hs.spaces should "become a yabai wrapper" for window-moving operations. We don't currently move windows (just switch spaces), but if we ever do, yabai is the path.

**Action:**
- [ ] If/when adding window-move features, gate them behind `hs.task` shelling to yabai
- [ ] Document yabai as an optional dependency for that feature
- [ ] Not urgent — keep in mind for future features

### 6. Add hs.screen.watcher for hotplug (L3 from earlier adversarial review)

**Context:** Our `rebuildPositionMap()` runs once in `start()`. If a monitor is disconnected/reconnected, positions go stale. Deferred earlier as "feature, not bug" — still true, but worth a tracking item.

**Action:**
- [ ] Add `hs.screen.watcher.new(rebuildPositionMap)` in `start()`
- [ ] Stop it in `stop()`
- [ ] Add to the `state` table for GC safety
- [ ] Test with an unplug/replug cycle

## Low priority / monitor only

### 7. Monitor the Swift rewrite

**Context:** cmsj is working on a Swift + JavaScript "Hammerspoon v2" rewrite. No public repo, no timeline. When it exists, it will break all Spoons.

**Action:**
- [ ] Check Hammerspoon Discord/discussions quarterly for rewrite progress
- [ ] When v2 repo appears, evaluate migration path
- [ ] Not urgent — likely 1-2+ years away

### 8. List on macoswm.com

**Context:** New directory site for macOS window managers: https://macoswm.com/

**Action:**
- [ ] Once the Hammerspoon/Spoons PR merges (or sooner), submit our Spoon for listing
- [ ] Boost discoverability

## Won't fix / deliberate non-action

### 9. Automated tests

Already decided — `hs.spaces` requires real displays, no mocking possible, no other Spoons ship tests. Not worth the ceremony.

### 10. __gc destructor

Not needed per our research. `hs.reload()` destroys the Lua state entirely; all watchers and timers are cleaned up automatically. Only Spoons with OS-level side effects (like Caffeine's caffeinate assertion) need `__gc`.

### 11. Shared watcher architecture (hs.watchable)

cmsj noted the lack of shared event bus as "one of the most significant architectural shortcomings in Hammerspoon," but we only use a single `hs.spaces.watcher`. Irrelevant for our scope.
