# Pending Code Changes — v3 Verify-Based Redesign

Running list of code changes for the v3 redesign and the bug fixes that go alongside. **Nothing here is implemented yet.** When we decide to build, this is the inbox to work from.

Last updated: 2026-05-10. Reflects design decisions made after the council review:
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

## V3 core changes (one coordinated landing)

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

### 1. 🏗 Per-target fire-and-verify chain

**Where:** `Source/SpacesSync.spoon/init.lua` — `syncTarget` (line 903), `syncNext` (line 1023).

**Replaces:** the fixed `switchDelay` wait between dispatches.

**Shape:**
```
For each target i:
  1. Compute expectedSpaceID = Space at trigger's index on target_i.
  2. Eager-write: state.lastActiveSpaces[targetUUID] = expectedSpaceID.
  3. Dispatch hs.spaces.gotoSpace(expectedSpaceID).
  4. Poll hs.spaces.activeSpaceOnScreen(target) every ~30 ms.
     Stop when it matches expectedSpaceID OR pollTimeout (~1 s) elapses.
  5. If matched → continue. If timeout → log warning, continue.
```

**New config knob:** `obj.pollTimeout = 1.0` (seconds). Replaces `obj.switchDelay`.
**Knob removed:** `obj.switchDelay` (and its validation in `:start`).

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

### 5b. 🏗 Universal end-of-callback verifier (`verifyAndRefreshBaseline`)

**Where:** new function called as the LAST step on every path that ends in DONE — not just the sync-group chain.

**The invariant:** `state.lastActiveSpaces` matches the actual world. The watcher re-arms only when this holds. If it doesn't, we log and refresh the baseline so the *next* watcher fire diffs against truth.

**Runs on every path:**
- `NO_CHANGE` path (FIND-no)
- Independent-display path (after `UPDATE_BASELINE`)
- Sync-group path (after `CLEAR`)
- Screen-reconfig path (after `STATUS_HUD`)
- (Disabled / drop paths return early; they don't reach the verifier and don't need to — they didn't update our model.)

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
