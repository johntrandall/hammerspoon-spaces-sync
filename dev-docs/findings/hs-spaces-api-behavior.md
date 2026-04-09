# Research Findings

Documented behaviors discovered during SpacesSync development. Each finding records what was observed, the confidence level, and how the code handles it.

For the public-facing version of these findings, see `hammerspoon-and-spaces-quirks.md`. For macOS settings analysis, see `macos-spaces-settings.md` (sibling file in this folder).

## Test Environment

| Component | Version |
|---|---|
| macOS | 15.5 Sequoia |
| Hammerspoon | 1.1.1 |
| Monitors | 4x LG SDQHD (2560x2880) |
| Arrangement | Horizontal row, left-to-right |

---

## F-001: gotoSpace() is asynchronous

**Confidence:** Verified

**Observed behavior:** `hs.spaces.gotoSpace(spaceID)` returns immediately. The Space switch happens asynchronously — during the next run loop cycle or after the animation. Calling `hs.spaces.activeSpaceOnScreen()` immediately after `gotoSpace()` returns the *old* space, not the target.

**How discovered:** Attempted to verify switches by reading active space right after `gotoSpace()`. Verification always showed the switch "failed" even though the Space visually changed.

**Impact:** Cannot reliably verify a switch completed. Any post-switch logic that reads `activeSpaceOnScreen()` must wait.

**Mitigation in code:** Don't verify individual switches. Re-snapshot `activeSpaces()` after the debounce period when all switches have settled. (`init.lua:379-394`)

---

## F-002: Rapid gotoSpace() calls are silently dropped

**Confidence:** Verified

**Observed behavior:** Calling `gotoSpace()` for multiple monitors in a tight loop results in only the first call taking effect. Subsequent calls are silently ignored — no error, no exception, no callback. The Space simply doesn't switch.

**How discovered:** Initial implementation switched all targets in a `for` loop. Only the first monitor switched; others stayed put. No errors in console.

**Minimum reliable delay:** 300ms between calls. Not tested below this threshold to find the actual minimum — 300ms works consistently and is fast enough to feel instantaneous.

**Impact:** Multi-monitor sync requires sequential, delayed switching.

**Mitigation in code:** `syncNext()` recursive function chains `gotoSpace()` calls with `hs.timer.doAfter(self.switchDelay, ...)`. Default `switchDelay` is 0.3s. (`init.lua:377-405`)

**Open question:** Does Reduce Motion (Accessibility setting) lower the minimum delay? The animation is ~300ms; if removed, the floor might be lower. See `macos-spaces-settings.md` #8 — not yet tested.

---

## F-003: Space watcher fires on programmatic switches

**Confidence:** Verified

**Observed behavior:** `hs.spaces.watcher` does not distinguish between user-initiated Space switches (keyboard, trackpad, Mission Control) and programmatic switches via `gotoSpace()`. All fire the same callback.

**How discovered:** First working sync immediately entered an infinite loop. Watcher detected a change → called `gotoSpace()` on targets → each target switch fired the watcher → watcher called `gotoSpace()` again → infinite loop. Console filled with sync logs until Hammerspoon froze.

**Impact:** Without guard logic, any sync implementation creates a feedback loop.

**Mitigation in code:** Two-layer protection:
1. `syncInProgress` flag — set `true` before switching, watcher ignores all events while set. (`init.lua:319-323, 375`)
2. Debounce timer — after all switches complete, wait `debounceSeconds` (default 0.8s) before clearing `syncInProgress`. This covers the gap between the last `gotoSpace()` call and macOS finishing the animation. (`init.lua:390-395`)

---

## F-004: activeSpaces() returns point-in-time snapshots

**Confidence:** Verified

**Observed behavior:** `hs.spaces.activeSpaces()` returns a table of `{screenUUID: spaceID}` reflecting the state at the moment of the call. It is not a live reference — it does not update as spaces change.

**How discovered:** Captured `activeSpaces()` before sync, compared to next watcher event. The watcher saw the programmatic switches as "new changes" because the baseline was stale, triggering a cascading sync attempt.

**Impact:** If the watcher's baseline (`lastActiveSpaces`) isn't updated after programmatic switches, every programmatic switch looks like a user-initiated change on the next watcher fire.

**Mitigation in code:** Re-snapshot `activeSpaces()` at two points:
1. After all sync switches complete (before debounce). (`init.lua:379`)
2. After debounce timer fires (when watcher re-enables). (`init.lua:393`)

---

## F-005: Lazy extension loading adds latency in callbacks

**Confidence:** Verified

**Observed behavior:** Hammerspoon lazy-loads Objective-C bridge extensions. `require("hs.screen")` returns a Lua proxy table; the actual ObjC bridge loads on first function call. If that first call happens inside a time-critical watcher callback, it adds hundreds of milliseconds of latency.

**How discovered:** Early versions occasionally dropped switches that should have worked within the 300ms window. Latency appeared non-deterministic. Adding `require()` calls at module load time eliminated the issue.

**Impact:** Extensions used in the watcher callback (`hs.screen`, `hs.spaces`, `hs.application`, `hs.timer`) must be pre-loaded at module initialization.

**Mitigation in code:** Pre-load with a dummy function call to force the ObjC bridge to initialize:
```lua
require("hs.screen");      local _ = hs.screen.allScreens
require("hs.spaces");      _ = hs.spaces.activeSpaces
require("hs.application"); _ = hs.application.frontmostApplication
require("hs.timer");       _ = hs.timer.secondsSinceEpoch
```
(`init.lua:34-37`)

**Note:** `require()` alone is insufficient — it returns the proxy. Touching a function forces the actual load.

---

## F-006: macOS display numbers are unstable

**Confidence:** Verified

**Observed behavior:** The parenthetical number in display names (e.g., "LG SDQHD (2)") is assigned arbitrarily by macOS. It can change when:
- Cables are reconnected
- Machine reboots
- Displays wake from sleep (occasionally)

The number does NOT reflect physical position or any deterministic ordering.

**How discovered:** Display numbers changed after a reboot. Sync groups referenced by display number broke silently — the wrong monitors synced.

**Impact:** Display numbers cannot be used for persistent monitor identification.

**Mitigation in code:** Identify monitors by `screen:frame()` coordinates (x, y), which reflect the physical arrangement in System Settings > Displays. Sort by x then y to assign stable position numbers. (`init.lua:164-183`)

---

## F-007: moveWindowToSpace() broken on Sequoia

**Confidence:** Verified (by community reports, not our testing)

**Observed behavior:** `hs.spaces.moveWindowToSpace(windowID, spaceID)` does not work on macOS 15.x. Known issue in the Hammerspoon community. Workarounds involve `hs.eventtap` click-hold simulation, which is fragile.

**Source:** Hammerspoon GitHub issues. Not used in SpacesSync but relevant context for anyone extending this module with window-management features.

---

## F-008: Multiple monitors changing simultaneously

**Confidence:** Observed

**Observed behavior:** When the watcher fires, sometimes multiple monitors show changed spaces in the `activeSpaces()` snapshot compared to `lastActiveSpaces`. This happens when:
- macOS batches watcher notifications
- A previous sync's debounce overlaps with a new user switch

**Current handling:** Only the first changed monitor is synced; others are logged as "(multiple changed; syncing first only)". (`init.lua:351-353`)

**Risk:** If the user switches spaces on monitor A and macOS also reports a stale change on monitor B (from a prior sync that wasn't fully captured in `lastActiveSpaces`), we might sync from the wrong trigger.

**Status:** Not observed to cause problems in practice, but the logic isn't proven correct for all edge cases.

---

## F-009: Watcher callback timing

**Confidence:** Observed

**Observed behavior:** The watcher callback fires at a variable delay after the Space switch. Not immediately, not after a fixed interval. Appears to correlate with animation completion but not strictly so.

**Impact:** The debounce timer (`debounceSeconds = 0.8`) must be long enough to cover:
- The watcher callback delay for our own programmatic switches
- The animation duration
- Any additional macOS internal processing

0.8s was chosen empirically — shorter values occasionally result in the watcher re-enabling too early and seeing a stale intermediate state.

**Status:** 0.8s works reliably on macOS 15.5. May need tuning on other versions or with Reduce Motion enabled.

---

## F-010: spans-displays defaults key semantics

**Confidence:** Verified

**Observed behavior:** `defaults read com.apple.spaces spans-displays` returns:
- `0` = "Displays have separate Spaces" is **ON** (each display has its own Spaces)
- `1` = "Displays have separate Spaces" is **OFF** (all displays share one Space)

The key name and values are counterintuitive. `spans-displays = 1` means all displays share a single Space (the display "spans" all monitors). `spans-displays = 0` means displays do NOT span — each gets its own Spaces.

**Impact:** The check in `init.lua:447` tests `separateSpaces == "1"` (spans=true → separate=OFF) to block activation.
