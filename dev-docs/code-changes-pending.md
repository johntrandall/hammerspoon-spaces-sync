# Pending Code Changes — v3 Verify-Based Redesign

Running list of code changes for the v3 redesign and the bug fixes that go alongside. **Nothing here is implemented yet.** When we decide to build, this is the inbox to work from.

Last updated: 2026-05-10 (after second council review). Reflects design decisions made after BOTH council reviews:
- **Fire and verify** (per-target polling with timeout) replaces fixed `switchDelay`
- **Eager `lastActiveSpaces` writes** per target before each dispatch — eliminates `debounceSeconds`
- **Hard block** on missing Accessibility at `:start`
- **Second entry path** via `hs.screen.watcher` for display reconfig

See `dev-docs/diagrams/workflow-roadmap.mermaid` for the v3 design diagram.

## Status legend

- 🏗 **v3 core** — required for the verify-based redesign; ship together
- ⚠ **Important** — real bug or correctness gap; should ship with or before v3
- 🛠 **Cleanup** — improves clarity / maintainability without behavior change
- 💡 **Nice-to-have** — known limitation, deferred until measurably bites
- 🔬 **Spike** — measure first

---

## ⚠ HARD PREREQUISITES — must land before any v3 code

### P1. Polling spike (calibration, not "decide if")

The OmniFocus task originally framed the spike as "decide if polling is the right approach." After the second council review, that question is answered (yes, polling is right, but with a `MIN_DISPATCH_GAP` floor). Re-scope the spike to **calibrate**:

- Run experiments E1 (when does activeSpaceOnScreen flip vs animation) and E2 (drop-rate vs inter-dispatch gap) from the spike's note.
- Output: empirical floor for `MIN_DISPATCH_GAP` (the council expects 150-200ms).
- Without this data, v3 ships a hypothesis. The Hammerspoon-expert review cited project's own findings (F-001/F-002/F-009) as evidence that **Model A is more likely than Model B** — meaning polling alone is unsafe.

### P2. Watcher single-exit refactor

The current watcher callback (`init.lua:961-1057`) has 4 exit paths sprinkled through a 96-line anonymous closure. v3's universal verifier needs them to converge to a single tail. **Pure structural refactor** — no behavior change — but it's the largest single edit and is currently invisible in the diagram. Implementation-feasibility council flagged this as the load-bearing change that the planning doc didn't surface.

### P3. Manual test checklist

Per CLAUDE.md: "No automated tests. Testing requires a multi-monitor Mac." Write `dev-docs/manual-test-checklist.md` covering ~18-22 scenarios (single swipe per group size, mid-chain disable, mid-chain monitor unplug/replug, lid close, Accessibility revoked, etc.) **before the first code change**. Run it against current v0.2 to establish baseline behavior, then re-run after each stage of v3 lands.

## V3 core changes (one coordinated landing)

**The coordinated bundle.** Items 0+1+2+5+5b cannot be sub-divided per implementation-feasibility review. Eager writes without poll-verify creates phantom states; dropping debounce without eager writes causes echo loops. Ship together or not at all.

### 0. 🏗 Compute `expectedEndState` at chain start (the load-bearing data structure)

**Where:** new step at the start of `syncNext` (or right before the first call), inside the watcher callback after `LOCK`.

**Shape:**
```lua
-- At chain start, after syncInProgress = true:
local expectedEndState = {}

-- Snapshot starting world
for uuid, spaceID in pairs(hs.spaces.activeSpaces() or {}) do
  expectedEndState[uuid] = spaceID
end

-- Override sync-group target entries with the Space ID they should reach
for _, targetUUID in ipairs(targets) do
  local targetSpaceID = getSpaceAtIndex(targetUUID, triggerIndex)
  if targetSpaceID then
    expectedEndState[targetUUID] = targetSpaceID
  end
  -- if nil, target has no Space at this index — leave entry alone (skip)
end
```

**Why it matters:** this single map is the source of truth for the rest of the chain. Used twice:

1. **During the chain (item 2 — eager writes):** `state.lastActiveSpaces[targetUUID] = expectedEndState[targetUUID]` — no separate "compute expected ID per target" logic needed.
2. **At end of chain (item 5b — verification):** diff `hs.spaces.activeSpaces()` against `expectedEndState` and log mismatches. The diff itself tells you what's wrong; no role-based branching at check time.

This unification simplifies the implementation, eliminates a class of bugs (computing the expected ID inconsistently in the eager-write step vs. the verify step), and makes the chain's intent explicit in one place.

**Storage:** local to the chain; doesn't need to live on `state` unless we want it queryable from `:status()`.

---

### 0a. 🏗 `chainGeneration` token (council mitigation)

**Where:** new `state.chainGeneration` integer; bumped at chain start (LOCK), BAIL_CHAIN, watchdog fire, `:stop()`, and on screen-watcher reconfig.

**Why:** Hammerspoon timer callbacks queue on the main loop and yield between iterations. Without a generation token, a poll-loop closure captured before BAIL_CHAIN can still execute its next tick after the chain has been bailed, dispatching `gotoSpace` against a stale `expectedEndState` or a target that no longer exists.

**Shape:**
```lua
-- In state init: state.chainGeneration = 0
-- At chain start (item 0):
state.chainGeneration = state.chainGeneration + 1
local myGen = state.chainGeneration
-- Every poll-loop and dispatch closure captures myGen
-- and bails if myGen ~= state.chainGeneration:
if myGen ~= state.chainGeneration then return end
```

**Bumped on:** chain start, BAIL_CHAIN, watchdog, `:stop()`. Cheap; eliminates the chain-leaks-past-bail class of races (concurrency review races N3, N4, N7).

### 1. 🏗 Per-target fire-and-verify chain

**Where:** `Source/SpacesSync.spoon/init.lua` — `syncTarget` (line 903), `syncNext` (line 1023).

**Replaces:** the fixed `switchDelay` wait between dispatches.

**Shape (v3 + council mitigations):**
```
For each target i:
  1. Eager-write: state.lastActiveSpaces[targetUUID] = expectedEndState[targetUUID].
     (Computed at chain start in item 0.)
  2. Dispatch hs.spaces.gotoSpace(expectedEndState[targetUUID]).
  3. Poll hs.spaces.activeSpaceOnScreen(target) every ~30 ms.
     Each poll iteration re-checks state.enabled AND chainGeneration; bails if either changed.
     Stop when activeSpaceOnScreen matches expectedSpaceID OR pollTimeout (~1 s) elapses.
  4. If matched → continue. If timeout → log warning, continue.
  5. Wait MIN_DISPATCH_GAP (~150 ms, calibrate via spike) before dispatching the NEXT target.
     activeSpaceOnScreen flips when macOS commits the Space, but Mission Control's accessibility
     tree may not be ready for the next gotoSpace yet (Model A). The floor covers MC's UI teardown.
```

**New config knobs:**
- `obj.pollTimeout = 1.0` (seconds). Replaces fixed `switchDelay`.
- `obj.minDispatchGap = 0.15` (seconds). New floor between dispatches even when polling green-lights.
- `obj.pollInterval = 0.030` (seconds). Polling cadence.

**Old knobs (deprecated, not removed):** `obj.switchDelay` and `obj.debounceSeconds`. Implementation-feasibility review flagged these as part of the public API at lines 99-113 of init.lua. Keep them with deprecation warnings for one release; ignore values silently. Removing in next major version.

**Polling cancellation:** all in-flight poll timers must be tracked in `state.chainTimers` (a list, not a single field) so BAIL_CHAIN and `:stop()` can cancel all of them in one call. The current `state.pendingSyncTimer` is a single field — insufficient for v3.

**Why polling instead of fixed wait:** the system is wonky enough that arbitrary waits feel fragile. Polling proceeds when macOS actually settled, not when a clock fires. Worst case (timeout) is roughly the same wait as today; best case is much shorter.

### 2. 🏗 Eager `lastActiveSpaces` writes

**Where:** New step inside the chain, before each `gotoSpace` dispatch.

**Replaces:** the `debounceSeconds` post-chain wait.

**Shape:** Before dispatching `gotoSpace(targetSpaceID)`, set `state.lastActiveSpaces[targetUUID] = targetSpaceID`. Subsequent watcher fires from our own dispatch see `currentSpaces[targetUUID] == lastActiveSpaces[targetUUID]` and exit via NO_CHANGE.

**Knob removed:** `obj.debounceSeconds` (and its validation in `:start`).

**Subtlety:** during the in-flight polling window, the eager write is "ahead of" macOS's actual state. The `syncInProgress` gate still suppresses watcher fires in that window so the false diff doesn't trigger anything. The gate clears immediately when polling completes (no padding).

### 3. 🏗 `hs.screen.watcher` second entry path

**Where:** new `screenWatcher` setup in `:start`, teardown in `:stop`.

**Behavior on fire:**
1. Bail any in-flight chain (set `syncInProgress = false`, stop pending timers).
2. Call `rebuildPositionMap()` (existing function).
3. Refresh `state.lastActiveSpaces = hs.spaces.activeSpaces() or {}`.
4. Validate `obj.syncGroups` against new `totalScreens` — log warning per out-of-range position.
5. Show status HUD: `"SpacesSync: display layout changed"`.

**Closes:** silent breakage when monitors are plugged/unplugged, lid is opened/closed, displays are rearranged in System Settings.

### 4. 🏗 Hard block on missing Accessibility at `:start`

**Where:** `:start()` in `Source/SpacesSync.spoon/init.lua` — after the existing environment checks (~line 1211).

**Shape:**
```lua
if not hs.accessibilityState(true) then
  obj.logger.e("Accessibility permission required. Grant it in System Settings → Privacy & Security → Accessibility, then restart Hammerspoon.")
  hs.alert.show("SpacesSync: Accessibility permission required")
  state.osBlocked = true
  return self
end
```

**Closes:** silent failure of `gotoSpace` and `eventtap` when Accessibility is revoked or never granted.

### 5. 🏗 Drop `state.syncInProgress` debounce padding

**Where:** end of `syncNext` chain — replaces the current debounce timer.

**Shape:** Once the last target verifies (or times out), set `syncInProgress = false` immediately. No `hs.timer.doAfter(debounceSeconds, ...)` wrapper.

**Why safe:** eager writes mean any echoes that arrive after the gate clears diff to no-change and exit cleanly via NO_CHANGE.

### 5b. 🏗 End-of-chain verifier (sync-group path only — council scope reduction)

**Where:** runs at the end of the sync-group chain ONLY, immediately before `CLEAR`. Order: poll-verify each target → end-of-chain verifier → CLEAR (re-arm) → DONE.

**The invariant:** `expectedEndState` (computed at chain start) matches actual at chain end. If it doesn't, the chain succeeded for some targets and failed for others; refresh `lastActiveSpaces` from actual so the next watcher fire diffs against truth.

**Council scope reduction:** the original v3 design had this run on every path. Devil's-advocate and Hammerspoon agents both flagged this as unnecessary work:
- NO_CHANGE just confirmed nothing changed (verifying again is theater)
- Independent path didn't dispatch anything (no chain to verify)
- Screen-reconfig path already rebuilt baseline from `activeSpaces()` (verifying current vs current is a no-op)

So: scope to the sync-group path only.

**Order matters.** Concurrency review flagged the original design (CLEAR → VERIFY) as race-unsafe — clearing the gate before verifier reads state lets a new watcher fire interleave with the verify. Reordered to **VERIFY → CLEAR**. Verifier runs while the gate is still closed.

**Shape:**
```lua
local function verifyAndRefreshBaseline(context)
  local actual = hs.spaces.activeSpaces() or {}
  local expected = state.lastActiveSpaces  -- whatever the path just set
  local mismatches = {}

  -- Displays in expected but missing or different in actual
  for uuid, expectedSpaceID in pairs(expected) do
    local actualSpaceID = actual[uuid]
    if actualSpaceID == nil then
      table.insert(mismatches, { uuid=uuid, kind="vanished" })
    elseif actualSpaceID ~= expectedSpaceID then
      table.insert(mismatches, {
        uuid=uuid, kind="wrong-space",
        expectedIdx = getSpaceIndex(uuid, expectedSpaceID) or "?",
        actualIdx   = getSpaceIndex(uuid, actualSpaceID) or "?",
      })
    end
  end

  -- Displays in actual that we don't have in expected (appeared mid-callback)
  for uuid, _ in pairs(actual) do
    if expected[uuid] == nil then
      table.insert(mismatches, { uuid=uuid, kind="appeared" })
    end
  end

  if #mismatches > 0 then
    obj.logger.e("State-check failed (path: " .. context .. "):")
    for _, m in ipairs(mismatches) do
      if m.kind == "wrong-space" then
        obj.logger.e("  " .. getDisplayLabel(m.uuid) ..
          ": expected idx " .. tostring(m.expectedIdx) ..
          ", got idx " .. tostring(m.actualIdx))
      else
        obj.logger.e("  " .. getDisplayLabel(m.uuid) .. ": " .. m.kind)
      end
    end
    -- Restore the invariant: the next watcher fire diffs against truth, not our stale model
    state.lastActiveSpaces = actual
  end

  return #mismatches == 0
end
```

**Why this is simpler than the earlier role-based design:**

The earlier draft branched at check time on whether each display was a sync-group member or independent. That logic lived twice: once when we computed `expectedEndState`, once at the verify step. Pulling it into a single map (`expectedEndState` for the chain, or just `state.lastActiveSpaces` after each path's update) means the verifier is a pure dictionary diff. The path-specific work is "tell the verifier what should be true" by writing into `lastActiveSpaces`; the verifier's job is just "does reality match?"

**The diff itself tells you what's wrong** — no role-based severity needed at check time. Mismatches mean: something drifted in the milliseconds between when the path last updated our model and when we re-armed. For the sync-group path that's most likely a dispatch failure or user override mid-chain. For other paths it's a rare display reconfig race.

**What it catches that per-target verify (item 1) doesn't:**

- Target drifted after its individual verify passed (user override mid-chain)
- The trigger itself moving mid-chain (gate dropped that signal — without this we never know)
- Anything that changed during the popup display window between baseline update and DONE
- Display reconfig races (screen-watcher missed a tick)
- Per-target verify false positives

**Action on mismatch:** log at error level + refresh `lastActiveSpaces` to current truth so the next watcher fire diffs cleanly. Don't auto-retry; the user sees the drift visually and re-swipes if they care.

**Why refresh on mismatch:** if we don't, `state.lastActiveSpaces` remains stale and the next watcher fire's diff will be wrong (could miss a real change or react to a phantom one). Refreshing restores the invariant immediately.

**Optional future:** integrate with the planned `:status()` method (item 10) so the last verifier result and last-seen mismatches are queryable from the CLI.

---

## Bug fixes (ship with v3, not after)

### 6. ⚠ `:stop()` mid-chain doesn't actually halt the chain [B2]

**Where:** `Source/SpacesSync.spoon/init.lua` — `syncNext` (lines 1023-1054), `:stop` (lines 1277-1295).

**Problem:** `syncNext` recurses via `pendingSyncTimer` callbacks. If the timer is queued by `hs.timer` but its closure hasn't executed when `:stop()` runs, the chain keeps going because `syncNext` never re-checks `state.enabled`.

**Fix:** Add `if not state.enabled then return end` at the top of `syncNext` (and at the top of the new poll loop).

### 7. ⚠ Watchdog timer for stuck `syncInProgress` [B4]

**Where:** new safety timer set when `syncInProgress = true`.

**Bound:** `numTargets × pollTimeout + safety_margin` (~5 s).

**Action on fire:** force-clear `syncInProgress = false`, log at error level: `"Sync watchdog fired — flag was stuck"`. Cheap insurance against unhandled errors anywhere in the chain.

### 8. ⚠ `:start()` snapshot/setup-watcher race [B1]

**Where:** `Source/SpacesSync.spoon/init.lua` line 1254.

**Problem:** `state.lastActiveSpaces = hs.spaces.activeSpaces() or {}` is set in `:start()` AND again inside `setupWatcher()` at line 959. A user swipe between the two is silently absorbed.

**Fix:** Remove the assignment at line 1254. `setupWatcher()` already initializes correctly.

### 9. 🛠 Consolidate `lastActiveSpaces` baseline writes [D2]

**Where:** lines 959, 1000, 1011, 1025, 1043, 1254 in current code.

**Problem:** Six write sites today, two of them buggy (line 1025 redundant, line 1254 racy — see [B1]).

**Fix in v3:**
- Line 959 (setupWatcher init) — KEEP
- Line 1000 (NO_CHANGE) — KEEP
- Line 1011 (INDEPENDENT path) — KEEP
- Line 1025 (chain end, redundant) — REMOVE
- Line 1043 (debounce timer) — REMOVE (debounce is gone)
- Line 1254 (`:start()` race) — REMOVE
- New: per-target eager writes inside the chain (one site per dispatch)

Optional: extract a `refreshBaseline()` or `setBaseline(uuid, spaceID)` helper.

---

## Post-v3 hardening (defer until v3 lands and is stable)

### 10. 🛠 `:status()` method for diagnostics

Single CLI call returns `enabled`, `osBlocked`, `syncInProgress`, position map, last sync timestamp. Nice for debugging.

---

## Already filed in OmniFocus (deferred)

These are real but won't ship with v3:

| Item | OmniFocus status |
|---|---|
| Per-display "currently driving" set (replace global `syncInProgress`) | filed — `nice-to-have` |
| switchDelay polling spike → repurposed as **pollTimeout calibration spike** | filed — re-scope to "calibrate v3 polling parameters" |
| Stage Manager / fullscreen Spaces support | filed — `nice-to-have`, `spike` |
| Multi-changed-display handling | filed — `nice-to-have` |
| Refactor: consolidate baseline writes (D2) | filed — now superseded by item 9 above (rolled into v3 core) |

---

## Open design question (post second council review)

### Q1. Eager writes: keep with observed-value fix, or drop entirely?

The second council split on this:

- **Devil's-advocate proposed v2.5:** drop eager writes + `expectedEndState` + universal verifier entirely. Keep `syncInProgress` and shrink `debounceSeconds` to 0.2s. Captures ~80% of v3's correctness gains at ~30% of complexity. Defer eager writes until a logged drift event proves they're needed.
- **Hammerspoon-expert proposed surgical fix:** keep eager writes BUT write the *observed* post-dispatch value (read after poll) instead of the *expected* value (write before dispatch). Eliminates the baseline-poisoning hazard when macOS drops a dispatch. Costs one extra `activeSpaceOnScreen` read per target — already cheap.

The trade-off:
- v2.5 (drop): simpler model, ~150 LOC instead of ~280-360, fewer interacting invariants. Harder to detect mid-chain drift.
- Observed-eager-write: keeps v3's ability to absorb echoes naturally via NO_CHANGE, fixes the poisoning hazard, marginal extra LOC.

**Decision deferred** — depends partly on the polling spike (P1) results. If Model A holds strongly, the observed-eager-write approach is more attractive (it's already paying the polling cost; might as well use the post-poll read as the source of truth). If Model B holds, v2.5's debounce-shrink is enough.

## Decided NOT to do

- **Pending trigger / drain step / bounded retry loop.** Council reviewed; not necessary now that we have eager writes + verification. Drops are still possible but are now bounded by actual chain duration, not an arbitrary ceiling. User re-swipes if needed.
- **Echo classifier (`expectedActiveSpaces`).** Solved by eager writes.
- **`switchDelay` adaptive tuning.** Polling makes the question moot.

---

## Build order

If we land v3 in stages rather than one giant patch:

1. **Foundation (no behavior change):** item 9 (consolidate baseline writes), item 8 (fix `:start()` race). These are pure cleanup.
2. **Hardening (loud failures):** item 4 (Accessibility hard block), item 7 (watchdog), item 6 (`:stop` halt fix). These add safety nets without changing the sync flow.
3. **Verify-based core:** items 1, 2, 5, 5b (per-target verify, eager writes, drop debounce, end-of-chain consistency check). The diagram's main change.
4. **Second entry path:** item 3 (screen watcher). Independent of the verify changes; can land before or after.
5. **Diagnostics:** item 10 (`:status` method).

Manual test checklist from `dev-docs/manual-test-checklist.md` (TBD — should be written before stage 1 starts) needs to pass at each stage.
