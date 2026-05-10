# Pending Code Changes — v3 Verify-Based Redesign

Running list of code changes for the v3 redesign and the bug fixes that go alongside. **Nothing here is implemented yet.** When we decide to build, this is the inbox to work from.

Last updated: 2026-05-10 (after second council review). Reflects design decisions made after BOTH council reviews:
- **Fire and verify** (per-target polling with timeout) replaces fixed `switchDelay`
- **Per-target observed-value `lastActiveSpaces` writes** — after each poll-verify, write the value `activeSpaceOnScreen` actually returned. Eliminates `debounceSeconds` (Q1 resolution per F-010 §6.2)
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

### P1. Polling spike — ✅ DONE (2026-05-10)

Resolved by `dev-docs/findings/F-010-polling-model-a-vs-b.md`. Empirical result: **Model B holds** — `activeSpaceOnScreen` flips at end of MC animation; polling alone is a sufficient ready signal. 0 drops in 160 trials at gap=0. `MIN_DISPATCH_GAP = 0` (removed from design); `pollTimeout = 2.0 s` (revised up from 1.0 s).

F-010 also surfaced these out-of-scope items now filed as follow-ups (not blocking v3):
- macOS 16 (Tahoe) — re-run F-010 when porting (see F-010 §7.1)
- Reduce Motion ON regime (see F-010 §7.3 for re-run protocol)
- Heavy CPU/GPU load regime (see F-010 §7.2)

### P2. Watcher single-exit refactor

The current watcher callback (`init.lua:961-1057`) has 4 exit paths sprinkled through a 96-line anonymous closure. v3's universal verifier needs them to converge to a single tail. **Pure structural refactor** — no behavior change — but it's the largest single edit and is currently invisible in the diagram. Implementation-feasibility council flagged this as the load-bearing change that the planning doc didn't surface.

### P3. Manual test checklist — ✅ DONE (2026-05-10)

`dev-docs/manual-test-checklist.md` written, baseline filled against v0.2,
v3 actuals filled after implementation. Automated complement designed
separately as `dev-docs/test-strategy.md` (test code itself not yet
authored as of 2026-05-10).

## V3 core changes (one coordinated landing)

**The coordinated bundle.** Items 0+1+2+5+5b cannot be sub-divided per implementation-feasibility review. Per-target observed-value writes depend on poll-verify producing the value to write; dropping debounce depends on those writes being in place to absorb echoes. Ship together or not at all.

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

1. **During the chain (item 1 — dispatch):** `gotoSpace(expectedEndState[targetUUID])` — gives `syncTarget` the per-target Space ID to ask Mission Control for. (Note: `lastActiveSpaces` itself is NOT written from this map; per Q1 we use the post-poll observed value — see item 2.)
2. **At end of chain (item 5b — verification):** diff `hs.spaces.activeSpaces()` against `expectedEndState` and log mismatches. The diff itself tells you what's wrong; no role-based branching at check time.

This unification simplifies the implementation, eliminates a class of bugs (computing the expected ID inconsistently in the dispatch step vs. the verify step), and makes the chain's intent explicit in one place.

**Storage:** local to the chain; doesn't need to live on `state` unless we want it queryable from `:status()`.

---

### 0a. 🏗 `chainGeneration` token (council mitigation)

**Where:** new `state.chainGeneration` integer; bumped at chain start (LOCK), BAIL_CHAIN, watchdog fire, `:stop()`, and on screen-watcher reconfig. Consolidated state-additions table in `dev-docs/v3-implementation-handoff.md` §2.

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

**Shape (v3 + council + F-010 mitigations):**
```
For each target i:
  0. Skip-or-dispatch decision:
     • If expectedEndState[targetUUID] equals activeSpaceOnScreen(target) → already at
       expected Space (or target has no Space at trigger's index, expectedEndState
       was left at current — see item 0). Skip the rest of this iteration.
     • Otherwise → proceed to step 1.
  1. Dispatch hs.spaces.gotoSpace(expectedEndState[targetUUID]).
  2. Poll hs.spaces.activeSpaceOnScreen(target) every ~30 ms.
     Each poll iteration re-checks state.enabled AND chainGeneration; bails if either changed.
     Stop when activeSpaceOnScreen matches expectedSpaceID OR pollTimeout (~2 s) elapses.
  3. Branch on outcome:
     • Matched (success) → continue.
     • Timeout (macOS dropped) → log at WARN level, continue.
  4. Read activeSpaceOnScreen(target) once more and write the OBSERVED value into
     state.lastActiveSpaces[targetUUID]. (See Q1 resolution: observed-value writes,
     not pre-dispatch expected-value writes.) On success this equals expectedSpaceID;
     on timeout it captures macOS's actual stuck state, which the end-of-chain
     verifier will flag.
  5. Continue to next target — no inter-dispatch wait. F-010 confirmed Model B
     (160/160 dispatches at gap=0); polling alone is a sufficient ready signal.
```

**Step 0 covers two cases cleanly:**
- Target has fewer Spaces than the trigger's index (`getSpaceAtIndex` returned nil at chain start; item 0 left `expectedEndState[targetUUID]` at its snapshot value, which equals `activeSpaceOnScreen` now too). Skip — we already know there's no Space to go to.
- Target is already at the trigger's index (no-op sync). Skip — saves one round of dispatch + ~750 ms of polling per already-aligned target.

Adversarial round 4 surfaced this: without step 0, the chain dispatches no-op `gotoSpace(currentSpaceID)` calls in both cases. Behavior is technically correct but spammy. Step 0 makes the no-op explicit.

**New config knobs:**
- `obj.pollTimeout = 2.0` (seconds). Replaces fixed `switchDelay`. **See F-010 §6.1** for calibration rationale.
- `obj.pollInterval = 0.030` (seconds). Polling cadence.

**Old knobs (deprecated, not removed):** `obj.switchDelay` and `obj.debounceSeconds`. Implementation-feasibility review flagged these as part of the public API at lines 99-113 of init.lua. Keep them with deprecation warnings for one release; ignore values silently. Removing in next major version.

**Polling cancellation:** all in-flight poll timers must be tracked in `state.chainTimers` (a list, not a single field) so BAIL_CHAIN and `:stop()` can cancel all of them in one call. The current `state.pendingSyncTimer` is a single field — insufficient for v3.

**Why polling instead of fixed wait:** the system is wonky enough that arbitrary waits feel fragile. Polling proceeds when macOS actually settled, not when a clock fires. Worst case (timeout) is roughly the same wait as today; best case is much shorter.

### 2. 🏗 Per-target `lastActiveSpaces` writes (observed-value variant per Q1)

**Where:** Step 4 of each per-target iteration in `syncNext` (after poll-verify completes).

**Replaces:** the `debounceSeconds` post-chain wait.

**Shape:** After the per-target poll-verify (step 3 of item 1), read `activeSpaceOnScreen(target)` one more time and write it into `state.lastActiveSpaces[targetUUID]`. Subsequent watcher fires from our own `gotoSpace` see `currentSpaces[targetUUID] == lastActiveSpaces[targetUUID]` and exit via NO_CHANGE — no debounce window needed.

**Knob deprecated:** `obj.debounceSeconds`. Same lifecycle as item 1 — keep parseable for one release, no-op the value.

**Why observed value, not expected:** see F-010 §6.2 (canonical rationale). Briefly: zero extra reads, and on timeout the baseline matches reality instead of optimism.

**Sequencing note:** during the polling window itself, `state.lastActiveSpaces[target]` still reflects the PRE-dispatch state, not the in-flight expectation. The `syncInProgress` gate suppresses watcher fires during the window so the (briefly stale) diff doesn't trigger anything. Once polling completes, the observed-value write makes the baseline current. The gate clears immediately after the end-of-chain verifier (no debounce padding).

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

**Why safe:** the per-target observed-value writes (item 2) mean `lastActiveSpaces` matches macOS's actual confirmed state when the gate clears. Any echoes arriving after that diff to no-change and exit cleanly via NO_CHANGE.

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

**Fix:** at the top of `syncNext` AND at the top of the new poll-loop tick (item 1), bail if EITHER `state.enabled` is false OR the captured `chainGeneration` no longer matches `state.chainGeneration` (item 0a). The two checks compose: `state.enabled` catches `:stop()`; `chainGeneration` catches BAIL_CHAIN, watchdog, and any other mid-chain abort.

```lua
if not state.enabled or myGen ~= state.chainGeneration then return end
```

**`:stop()` must also restore baseline truth, in this order:**

1. Bump `chainGeneration` (so any captured closure bails on next tick).
2. Stop chain-owned timers (`chainTimers`).
3. Refresh `state.lastActiveSpaces = hs.spaces.activeSpaces() or {}`.
4. Set `state.enabled = false` LAST.

Keeping `state.enabled = false` until step 4 ensures the watcher's `enabled?` gate stays "yes" while we're restoring the baseline, so any spaces-watcher fire that arrives mid-restore is suppressed by the existing guards rather than leaking through with a Frankenstein baseline. Same ordering applies to BAIL_CHAIN's `syncInProgress = false`.

Without this, the next watcher fire after `:start()` (or after another bail-and-recover) diffs against a half-written baseline.

### 7. ⚠ Watchdog timer for stuck `syncInProgress` [B4]

**Where:** new safety timer set when `syncInProgress = true`.

**Bound:** `numTargets × pollTimeout + safety_margin`. With item 1's `pollTimeout = 2.0 s` and a 4-display group (3 targets), bound is `3 × 2 + 2 = 8 s`. Adjust safety_margin to ≥ 1 s; total should comfortably exceed the worst-case chain duration computed in item 1's POLL spec. The bound deliberately does NOT include the popup display window — the popup is fire-and-forget; the watchdog is only protecting the chain itself.

**Lifecycle integration:**
- Register the watchdog timer in `state.chainTimers` (item 1) so `BAIL_CHAIN` and `:stop()` cancel it cleanly.
- Capture `chainGeneration` (item 0a) in the watchdog closure; on fire, no-op if `myGen ~= state.chainGeneration` (a new chain has already started, the new one's watchdog will cover it).

**Note on dependency:** the formula references `obj.pollTimeout` and `state.chainTimers` introduced in item 1 (stage 3). If this item ships in stage 2 (per the build order) before item 1 lands, hard-code `8 s` and a single `state.watchdogTimer` field; refactor when item 1 lands.

**Action on fire (when generation matches), in order:**

1. Bump `state.chainGeneration` (so any closure still queued in `chainTimers` bails on next tick — consistent with item 0a's "bumped at chain start, BAIL_CHAIN, watchdog fire, `:stop()`").
2. Stop any remaining `chainTimers` (defensive — they should already be drained, but cheap to be sure).
3. Refresh `state.lastActiveSpaces = hs.spaces.activeSpaces() or {}` (so the next watcher fire diffs against truth — see item 6 / BAIL_CHAIN fix).
4. Set `state.syncInProgress = false` LAST (same ordering rationale as BAIL_CHAIN).
5. Log at error level: `"Sync watchdog fired — flag was stuck after Ns; chain abandoned"`.

Cheap insurance against unhandled errors anywhere in the chain.

### 8. ⚠ `:start()` snapshot/setup-watcher race [B1]

**Where:** `Source/SpacesSync.spoon/init.lua` line 1254.

**Problem:** `state.lastActiveSpaces = hs.spaces.activeSpaces() or {}` is set in `:start()` AND again inside `setupWatcher()` at line 959. A user swipe between the two is silently absorbed.

**Fix:** Remove the assignment at line 1254. `setupWatcher()` already initializes correctly.

### 9. 🛠 Consolidate `lastActiveSpaces` baseline writes [D2]

Split into two parts so each can ship in its proper build stage:

**9a. Pure cleanup (stage 1 — pre-v3 foundation, no behavior change):**

- Line 1025 (chain end, redundant — debounce overwrites it 0.8 s later) — REMOVE
- Line 1254 (`:start()` race with line 959 — see item 8) — REMOVE

These are bug fixes that stand alone without v3. Safe to land first.

**9b. v3-coupled (stage 3 — rolls into items 1+2):**

- Line 1043 (debounce timer write) — REMOVE (debounce is gone in v3 — item 5)
- New: per-target observed-value writes inside the chain (one site per target, after poll-verify) — landed as part of item 2

This part cannot land without items 1+2. It is logically the *removal* of one write site (line 1043) plus the *addition* of N per-target write sites (item 2's responsibility); listed here only to keep the inventory complete.

**Untouched (existing baseline-update sites that v3 keeps):**
- Line 959 (setupWatcher init)
- Line 1000 (NO_CHANGE branch)
- Line 1011 (INDEPENDENT path)

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

## Resolved design questions

### Q1 — RESOLVED: per-target observed-value writes (per F-010 §6.2)

**The original split (historical):**

- **Devil's-advocate v2.5** — drop eager writes, keep `syncInProgress`, shrink `debounceSeconds` to 0.2s.
- **Hammerspoon-expert surgical fix** — keep the per-target write but use the *observed* post-poll value, not the *expected* pre-dispatch value.

**Resolution (2026-05-10):** the polling spike (F-010) empirically confirmed Model B. **F-010 §6.2 is the canonical rationale** — read it for the empirical reasoning. One-line summary: observed-value writes cost no extra system calls (we already poll), match expected on success, and never lie on timeout. v2.5's debounce-shrink alternative leaves a residual echo window; observed-value writes close it entirely.

**Implications for items above:**

- Item 0 (`expectedEndState`) — KEEP. The chain-start expectation map is still useful: it tells `syncTarget` which Space ID to dispatch to per target. The Q1 resolution affects what we *write into `lastActiveSpaces`*, not what we use as the dispatch target.
- Item 1 (per-target poll-verify) — adjust to write `lastActiveSpaces[targetUUID] = activeSpaceOnScreen(target)` (the observed value) at the **end** of each per-target verify, not at the **beginning** before dispatch. The expected value still drives the dispatch and the verify-target.
- Item 2 — already retitled "Per-target `lastActiveSpaces` writes (observed-value variant per Q1)." Same place in the chain (per target), different value source (post-poll observation, not pre-dispatch expectation). Done.
- Item 5b (end-of-chain verifier) — unchanged. Still scoped to sync-group path only, still runs before CLEAR.
- `pollTimeout` raised to 2.0s per F-010 §6.1.

The Q1 resolution adds zero new code paths; it just changes what value is written at each per-target write site.

## Decided NOT to do

- **Pending trigger / drain step / bounded retry loop.** Council reviewed; not necessary now that we have per-target observed-value writes + end-of-chain verification. Drops are still possible but are now bounded by actual chain duration, not an arbitrary ceiling. User re-swipes if needed.
- **Echo classifier (`expectedActiveSpaces`).** Solved by per-target observed-value writes (the baseline matches macOS's actual confirmed state, so echoes diff to no-change).
- **`switchDelay` adaptive tuning.** Polling makes the question moot.

---

## Build order

**Canonical build order with per-stage shape, transient-state notes, and acceptance criteria lives in `dev-docs/v3-implementation-handoff.md` §3.** Summary:

1. **Foundation** — item 9a, item 8 (pure cleanup)
2. **Hardening** — items 4, 7, 6 (loud failures, no chain logic change)
3. **Verify-based core** — items 0, 0a, 1, 2, 5, 5b, 9b (coordinated bundle; cannot sub-divide)
4. **Second entry path** — item 3 (screen watcher)
5. **Diagnostics** — item 10 (`:status` method) + README/docs.json updates

Manual test checklist (`dev-docs/manual-test-checklist.md`) must pass at each stage per its "What passing means per stage" section.
