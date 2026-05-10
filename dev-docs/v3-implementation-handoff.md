# SpacesSync v3 — Implementation Handoff

**Audience:** an engineer (or fresh AI agent) who will implement v3. You have not seen the design conversation. You know Lua and Hammerspoon basics; you have not worked in this codebase.

**Reading order — read these files in this order before writing any code:**

1. **This file.** Orients you.
2. `dev-docs/code-changes-pending.md` — the catalog of code changes (items 0-12 grouped by status).
3. `dev-docs/diagrams/workflow-roadmap.mermaid` — the v3 design diagram (open in a Mermaid renderer).
4. `dev-docs/findings/F-010-polling-model-a-vs-b.md` — empirical basis for `pollTimeout` and Q1.
5. `dev-docs/hammerspoon-and-spaces-quirks.md` — gotchas about `hs.spaces`.
6. `Source/SpacesSync.spoon/init.lua` lines 950-1060 — the current watcher, which P2 must refactor.
7. `dev-docs/test-strategy.md` — testing levels, gating, and L6 operational notes (peer artifact to `manual-test-checklist.md`).

After reading, you should be able to answer:
- What does v3 change vs. v0.2 at a high level? (Polling-with-verify replaces fixed `switchDelay`/`debounceSeconds`; per-target observed-value baseline writes; second entry path via `hs.screen.watcher`; hard block on missing Accessibility.)
- Why is the polling spike load-bearing? (F-010 confirmed Model B; without that data v3 would have needed a `MIN_DISPATCH_GAP` floor.)
- What's the build order? (See §3 below.)

---

## 1. Current code map

The line numbers below are accurate as of commit `08c6162` (~v0.2 of the spoon). They will drift if any edit lands; pair with symbol names so `grep` recovers them.

| Symbol | Lines (current) | v3 disposition |
|---|---|---|
| `state` table init | ~185-193 | Add fields: `chainGeneration` (int, init 0), `chainTimers` (list, init `{}`), `watchdogTimer` (handle, init nil). See §2 below. |
| `getSpaceAtIndex` | ~280 | KEEP. Used by item 0. |
| `getTargetsFor` | ~238 | KEEP. Used by item 0. |
| `syncTarget` | ~903-948 | REPLACE body. v0.2 dispatches `gotoSpace` + logs. v3: returns the expected `targetSpaceID` to the chain runner; dispatch moves into `syncNext`. |
| `setupWatcher` | 954-1057 | REFACTOR (item P2 — single-exit). Watcher callback is currently a 96-line anonymous closure with 4 exit paths. Extract body to a function returning a path-tag; outer wrapper calls the universal verifier. See §5 below for target shape. |
| `syncNext` (closure) | 1023-1054 | REPLACE entirely with poll-loop chain (item 1). Adds step 0 (skip-or-dispatch), poll, observed-value write. |
| `state.lastActiveSpaces` writes | 959, 1000, 1011, 1025, 1043, 1254 | See item 9 in code-changes-pending. Stage 1 removes lines 1025 + 1254 (pure cleanup); Stage 3 removes 1043 and adds per-target observed writes. |
| `:start` | ~1138-1266 | Add Accessibility hard-block (item 4). Drop racy `state.lastActiveSpaces = ...` at line 1254 (item 8). Initialize new state fields. |
| `:stop` | ~1277-1295 | Add `chainGeneration` bump + baseline refresh (item 6). Order matters — see item 6. |
| `:toggle`, `:isEnabled` | ~1297-1326 | KEEP (no changes). |
| `:showNames`, `:renameCurrentSpace` | ~1328-1453 | KEEP (no changes). |
| `:bindHotkeys` | ~1455-1479 | KEEP. (Future: `syncNow`, `openSettings` per the settings track — out of v3 scope.) |
| `obj.switchDelay` | line 105 | DEPRECATE per `code-changes-pending.md` item 1. |
| `obj.debounceSeconds` | line 113 | DEPRECATE per `code-changes-pending.md` item 2 (same lifecycle as item 1). |

## 2. State additions

v3 adds three fields to the `state` table. Initialize them in the existing init block (~line 185). Per-item rationale lives in `code-changes-pending.md` items 0a (chainGeneration), 1 (chainTimers), 7 (watchdogTimer).

| Field | Init | Lifecycle |
|---|---|---|
| `state.chainGeneration` | `0` | Bumped at: chain start (item 0/LOCK), BAIL_CHAIN, watchdog fire, `:stop()`. Captured by every poll/dispatch closure as `local myGen = state.chainGeneration`. Closure bails if `myGen ~= state.chainGeneration`. |
| `state.chainTimers` | `{}` | List of all chain-owned `hs.timer` handles (per-target poll timers, watchdog). Cleared at chain end and on BAIL_CHAIN/`:stop()`. Replaces `state.pendingSyncTimer` (single field). |
| `state.watchdogTimer` | `nil` | One handle, registered into `chainTimers`. Set when chain starts; nil'd at chain end. |
| (existing) `state.syncInProgress` | `false` | Same as v0.2. Set at chain start; cleared LAST in BAIL_CHAIN / chain-end / `:stop` (after baseline refresh). |
| (existing) `state.enabled` | `false` | Same as v0.2. Set true in `:start`, false in `:stop`. |
| (existing) `state.lastActiveSpaces` | `{}` | Same as v0.2 but with observed-value writes per target during the chain (item 2). |

Reload survival: Lua state is destroyed on `hs.reload()`. All v3 fields re-init from scratch in `:start()`. An in-flight chain at reload time is abandoned; macOS-side dispatched `gotoSpace` calls complete on their own; new `setupWatcher` re-snapshots `lastActiveSpaces` from the post-reload world. This is identical to v0.2's reload behavior — no special handling needed.

## 3. Build order — stage-by-stage

Each stage is independently shippable and testable. Stage N's tests run BEFORE Stage N+1 starts.

### Stage 0 (one-time): seed the manual test checklist

Write `dev-docs/manual-test-checklist.md` (see §4 below). Run it against current `init.lua` (v0.2) to establish baseline behavior. Some scenarios will already fail (B1 race, B2 mid-chain `:stop`); record those as known v0.2 baselines so you can prove they're fixed in later stages.

### Stage 1: Pure cleanup (no behavior change)

- **Item 8** — remove `state.lastActiveSpaces = ...` at `init.lua:1254` (`:start` race fix).
- **Item 9a** — remove redundant write at `init.lua:1025` (chain end; line 1043 overwrites it 0.8s later).

Done when: checklist scenarios 1-4 still pass at v0.2 baseline; B1 no longer reproduces.

### Stage 2: Hardening (loud failures, no chain logic change yet)

- **Item 4** — Accessibility hard-block in `:start`. Adds 8 lines after the existing `checkEnvironment()` call.
- **Item 6** — `:stop` mid-chain halt. Add `state.enabled` check at top of `syncNext`. (Note: `chainGeneration` arm is added in Stage 3; for now, only `state.enabled` is checked.) Add baseline refresh + ordering (see item 6 in code-changes-pending).
- **Item 7** — Watchdog timer for stuck `syncInProgress`. **Stage-2 transient shape:** hard-code `8 s` bound; use a single `state.watchdogTimer` field (NOT `state.chainTimers` — that data structure doesn't exist yet). The §2 state table describes the END state of v3; in Stage 2, `state.watchdogTimer` is its own field. Stage 3 refactors it into `state.chainTimers` along with the new poll timers.

Done when: checklist scenarios 8, 22 pass; watchdog fires + clears flag if induced via injected `error()` in `syncTarget` (no checklist scenario; verify manually).

### Stage 3: Verify-based core (one coordinated landing — cannot be sub-divided)

- **Item P2** — watcher single-exit refactor. See §5 for target shape.
- **Item 0** — compute `expectedEndState` at chain start.
- **Item 0a** — `chainGeneration` token. Refactor item 6 to add the `chainGeneration` arm to its guard.
- **Item 1** — per-target poll-verify loop with skip-or-dispatch step 0.
- **Item 2** — per-target observed-value `lastActiveSpaces` writes.
- **Item 5** — drop `debounceSeconds` padding.
- **Item 5b** — end-of-chain VERIFY_END_STATE.
- **Item 9b** — remove `lastActiveSpaces` write at `init.lua:1043` (was the debounce timer; debounce is gone).
- Refactor item 7's watchdog to register in `chainTimers`, capture `chainGeneration`.
- Deprecate `obj.switchDelay` and `obj.debounceSeconds` (warn-and-no-op).

Done when: checklist scenarios 1-3 pass at v3 timings; 5, 6, 7 newly pass; 16, 18, 24 pass; `obj.pollTimeout` is the only timing knob in active use (`switchDelay`, `debounceSeconds` deprecated and no-op).

### Stage 4: Second entry path

- **Item 3** — `hs.screen.watcher` second entry path with debounce (see SW_DEBOUNCE node in diagram for the burst-coalescing pattern).

Done when: checklist scenarios 11-15 newly pass.

### Stage 5: Diagnostics

- **Item 10** — `:status()` method. Returns a table; see §7 below.
- Update `README.md` options table (drop `switchDelay`/`debounceSeconds`, add `pollTimeout`/`pollInterval`).
- Update `docs.json` (regenerate via Hammerspoon Spoon docs build).

## 4. Manual test checklist (P3 prerequisite)

The full checklist lives in **`dev-docs/manual-test-checklist.md`** — 30 scenarios across 6 groups (happy paths, races, reconfig, macOS misbehavior, lifecycle, UI surfaces). Each row has v0.2 expected, v3 expected, and blank "actual" columns to fill in.

Per-stage gating ("which scenarios pass at each stage") is documented in that file's "What passing means per stage" section.

Order of operations:
1. Run the checklist against current `init.lua` (v0.2) FIRST. Some scenarios will fail (B1 race, B2 mid-chain `:stop`); record those as v0.2 baselines.
2. After each implementation stage lands, re-run the relevant scenarios from §3 below.
3. v3 is shippable when scenarios 1-16, 18, 21-25, 28-30 all pass; 17 (Stage Manager) and 19 (mid-chain reorder) are documented known limitations per the checklist.

## 5. P2 single-exit refactor — target shape

Today's watcher callback (`init.lua:961-1057`) has multiple early returns. v3 needs every non-drop path to converge to a single tail so the universal verifier (item 5b) can run before re-arming.

Target shape:

```lua
state.spaceWatcher = hs.spaces.watcher.new(function()
  -- Guard layer (early returns, no convergence needed)
  if not state.enabled then return end
  if state.syncInProgress then
    obj.logger.d("WATCHER: ignored (sync in progress)")
    return
  end

  -- Diff layer
  local currentSpaces = hs.spaces.activeSpaces() or {}
  local changedUUID, changedSpaceID, newIndex = findChange(currentSpaces, state.lastActiveSpaces)

  if not changedUUID then
    -- NO_CHANGE path
    state.lastActiveSpaces = currentSpaces
    return
  end

  local targets = getTargetsFor(changedUUID)
  if not targets or #targets == 0 then
    -- INDEPENDENT path
    showPopup(changedUUID, newIndex)
    state.lastActiveSpaces = currentSpaces
    return
  end

  -- SYNC-GROUP path: chain runs, calls back when done
  runSyncChain(changedUUID, changedSpaceID, newIndex, targets, currentSpaces)
end)
```

Where `runSyncChain` is the new function that owns: LOCK → COMPUTE_EXPECTED → SYNCNEXT loop → POPUP → VERIFY_END_STATE → CLEAR. It bumps `chainGeneration`, manages `chainTimers`, and ends with both the verifier and `state.syncInProgress = false`.

The single-exit-needed property is *only* on the SYNC-GROUP path: VERIFY_END_STATE must run before CLEAR, and CLEAR must run before any return. Everything else (NO_CHANGE, INDEPENDENT) is unchanged from v0.2.

This is much simpler than "every path converges" and is what the diagram actually requires.

## 6. Acceptance criteria per item

Append these to each item in `code-changes-pending.md` as you implement.

| Item | Done when |
|---|---|
| 0 | `expectedEndState` produced at chain start matches: snapshot of `activeSpaces` with sync-group target entries replaced by `getSpaceAtIndex(target, triggerIndex)`. Targets where that returns nil keep snapshot value. Verified by injecting a logger.d call. |
| 0a | `chainGeneration` is incremented at LOCK, BAIL_CHAIN, watchdog fire, `:stop()`. Closure with stale `myGen` returns immediately on next tick. Verified by setting a long pollInterval and bumping generation manually mid-poll. |
| 1 | (a) A 4-display sync chain completes with `obj.switchDelay` deprecated; (b) average chain duration ≈ F-010 §4.1 mean × numTargets; (c) one forced dispatch drop (lower `obj.pollTimeout`) produces a single WARN log and the chain continues to the next target. Verified by checklist scenarios 1-3, 16. |
| 2 | After each per-target poll, `state.lastActiveSpaces[targetUUID]` equals what `activeSpaceOnScreen(target)` returned post-poll (success → expected; timeout → old value). Verified by checklist scenarios 5, 13. |
| 3 | Plug + unplug fires screen watcher; rebuild runs ONCE per real reconfig (not per fire); status HUD appears once per reconfig. Verified by checklist scenarios 8-11. |
| 4 | Revoking Accessibility before `:start` produces alert + sets `osBlocked = true`; `:start` returns without arming watcher. |
| 5 | `obj.debounceSeconds` no longer affects timing; chain ends immediately after VERIFY_END_STATE. |
| 5b | VERIFY_END_STATE runs only on sync-group path; produces ERROR/INFO log per role; refreshes `state.lastActiveSpaces`; writes a one-shot summary into `state.lastVerifierResult = {timestamp = ..., mismatches = {...}}` for `:status()` (item 10) to surface. Verified by manual-test-checklist scenarios 5, 6, 7. |
| 6 | `:stop()` mid-chain halts dispatch within 50 ms (scenario 7). |
| 7 | Injecting `error()` in `syncTarget` causes watchdog to fire within 8 s; logs at ERROR; clears `syncInProgress`; refreshes baseline. |
| 8 | Calling `:start` then immediately swiping does NOT silently absorb the swipe (scenario reproduces). |
| 9a | Lines 1025, 1254 in `init.lua` deleted; full test suite still passes. |
| 9b | Line 1043 in `init.lua` deleted; per-target writes from item 2 cover the path. |
| 10 | `hs -c 'spoon.SpacesSync:status()'` returns a table (see §7). |

## 7. `:status()` return shape

```lua
function obj:status()
  return {
    enabled            = state.enabled,
    osBlocked          = state.osBlocked,
    syncInProgress     = state.syncInProgress,
    chainGeneration    = state.chainGeneration,
    activeChainTimers  = #state.chainTimers,
    totalScreens       = totalScreens,
    positionMap        = positionToUUID,  -- copy
    syncGroups         = obj.syncGroups,  -- copy
    lastActiveSpaces   = state.lastActiveSpaces,  -- copy
    lastVerifierResult = state.lastVerifierResult,  -- {timestamp, mismatches} or nil
    pollTimeout        = obj.pollTimeout,
    pollInterval       = obj.pollInterval,
  }
end
```

Also log a one-line human-readable summary at info level: `"SpacesSync v0.3: enabled, idle, 4 screens, 2 sync groups, last verify clean at HH:MM:SS"` (the version string is `obj.version`, currently `"0.3"`).

Document in README under a new "Debugging" subsection.

## 8. Open design questions

These were considered during design and are *settled*; you do not need to relitigate. Listed for traceability.

- **Q1** (eager-writes vs v2.5) — RESOLVED in favor of observed-value writes. See `code-changes-pending.md` "Resolved design questions" + F-010 §6.2.
- **Model A vs B** — RESOLVED. Model B confirmed empirically. See F-010.
- **`MIN_DISPATCH_GAP`** — RESOLVED to 0 (removed from design).
- **eager-write semantics** — RESOLVED to observed-value (post-poll), not pre-dispatch.
- **Reload behavior** — accepted: in-flight chain abandoned cleanly; new `:start` re-snapshots from scratch.

If something feels under-specified that you'd want to relitigate, write a finding in `dev-docs/findings/` and surface it before implementing.

## 9. Council review provenance

The v3 design absorbed feedback from multiple structured review rounds (referenced in `code-changes-pending.md`). You don't need to read those council outputs — the design has already incorporated them. References like "concurrency review" or "Hammerspoon-expert review" are provenance markers, not load-bearing dependencies.

## 10. Out of scope

- Settings/config GUI (`SpacesSync.json`, `hs.webview` settings pane, `hs.pathwatcher`) — separate track. See `dev-docs/v3-vs-settings-track-harmonization.md`.
- Stage Manager / fullscreen Spaces correctness — filed as nice-to-have OmniFocus item.
- Multi-changed-display handling (when multiple displays change in one watcher fire) — filed as nice-to-have.
- Per-display "currently driving" set (replaces global `syncInProgress`) — filed as nice-to-have for multi-group correctness.
- macOS 16 / Tahoe — assumed not working until F-010 is re-run.
- Reduce Motion regime — not measured; potential follow-up.
