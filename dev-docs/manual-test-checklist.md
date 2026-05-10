# SpacesSync v3 Manual Test Checklist

**Purpose:** verify v3 behavior against expected outcomes. Required prerequisite for landing v3 (item P3 in `code-changes-pending.md`).

**How to use:**
1. **Run against current `init.lua` (v0.2) FIRST** to establish baseline behavior. Some scenarios will fail under v0.2 — that's expected (they're the bugs v3 fixes). Record actual v0.2 outcomes in the "v0.2 actual" column.
2. After each v3 implementation stage lands, re-run the relevant scenarios. The "v3 expected" column is the contract.
3. A scenario is **passing** when actual matches expected.

**Test environment:** SusanBones (or any 4-display Mac with multiple Spaces per display). At minimum 2 displays with 2+ Spaces each are needed.

**Setup before each test:** `spoon.SpacesSync.logger.setLogLevel('debug')`; tail console with `hs -c 'return hs.console.getConsole()' | grep SpacesSync`.

---

**v0.2 baseline analysis approach:** literal 30-scenario interactive run takes hours of swiping and disrupts live use. v0.2 actuals below are filled in via code analysis where determinable from the source (e.g., known bugs in syncNext that have no `state.enabled` check). Interactive-only scenarios are marked as such and will be re-validated against v3 only.

## Group A — happy paths

| # | Scenario | Setup | Steps | v0.2 expected | v3 expected | v0.2 actual | v3 actual |
|---|----------|-------|-------|---------------|-------------|-------------|-----------|
| 1 | Single swipe, 2-display group | `syncGroups = {{1,2}}`, both at index 1 | Swipe display 1 to index 2 | Display 2 follows in ~0.3-1.1 s | Display 2 follows in ~0.75 s | code: matches expected (fixed switchDelay=0.3 s + dispatch); interactive-only | |
| 2 | Single swipe, 3-display group | `syncGroups = {{1,2,3}}` | Swipe 1 to index 2 | All 3 within ~1.4 s | All 3 within ~1.5 s typical | code: matches expected; interactive-only | |
| 3 | Single swipe, 4-display group | `syncGroups = {{1,2,3,4}}` | Swipe 1 to index 2 | Sync within ~1.7 s | ~2.3 s typical | code: matches expected; interactive-only | |
| 4 | Mixed Space counts | Group `{1,2,3}`, D3 has fewer Spaces; swipe to index that exists in 1, 2 but not 3 | Swipe 1 | D3 logs SKIP at info | Same; D3 skipped at item-1 step 0 (no dispatch) | code: `syncTarget` line 913-916 logs SKIP at info when `triggerIndex > targetCount` — matches expected | |

## Group B — race conditions and recovery

| # | Scenario | Setup | Steps | v0.2 expected | v3 expected | v0.2 actual | v3 actual |
|---|----------|-------|-------|---------------|-------------|-------------|-----------|
| 5 | User re-swipes trigger mid-chain | `{{1,2,3,4}}` | Swipe 1 to idx 2; within 0.5 s swipe 1 to idx 3 | Second swipe dropped silently (B2) | VERIFY_END_STATE detects; ERROR log; baseline refreshed | code: GATE_RUNNING drops watcher fires while `syncInProgress=true` — matches "dropped silently" | |
| 6 | User swipes target mid-chain | `{{1,2,3,4}}` | Swipe 1; within 0.5 s manually swipe target D3 to a different index | Target lands wherever user put it; baseline stale | VERIFY_END_STATE detects; ERROR log; baseline refreshed | code: same as #5 — interactive-only | |
| 7 | User swipes independent display mid-chain | `{{1,2}}`, D3 and D4 independent | Swipe 1; within 0.5 s swipe D4 | D4 swipe dropped silently | VERIFY_END_STATE detects; INFO log; baseline refreshed | code: same as #5 — interactive-only | |
| 8 | Mid-chain `:stop()` | `{{1,2,3,4}}` | Swipe 1; within 1 s `hs -c 'spoon.SpacesSync:stop()'` | Chain keeps dispatching (B2 bug) | Chain halts within 50 ms; no further dispatch | code: `syncNext` (lines 1023-1054) has no `state.enabled` check — confirms B2 bug | |
| 9 | Mid-chain toggle hotkey | Same as 8 but use ⌃⌥⌘Y | Same as 8 | Same as 8 | Same as 8 | same as #8 | |
| 10 | Rapid double-toggle | | Press ⌃⌥⌘Y twice in <100 ms | Possibly off-then-on race | Cleanly off; cleanly on; no leaked timers | interactive-only | |

## Group C — display reconfiguration

| # | Scenario | Setup | Steps | v0.2 expected | v3 expected | v0.2 actual | v3 actual |
|---|----------|-------|-------|---------------|-------------|-------------|-----------|
| 11 | Unplug target mid-chain | `{{1,2,3}}` | Swipe 1; mid-chain unplug D3 | Map stale; targets-from-now-on broken until `:stop` + `:start` | Screen-watcher fires; BAIL_CHAIN; rebuild; status HUD; subsequent swipe works | code: no `hs.screen.watcher` in v0.2 (`grep "screen.watcher" init.lua` → 0 hits) — confirms map stays stale | |
| 12 | Unplug trigger mid-chain | Same | Swipe 1; mid-chain unplug D1 | Same as 11 | Same as 11 | code: same — no screen.watcher | |
| 13 | Plug new monitor (idle) | 3 monitors connected; v3 running | Plug a 4th | Map stale | Screen-watcher rebuilds; status HUD | code: same — no screen.watcher | |
| 14 | Lid close (laptop trigger) | Laptop is D1, in `{{1,2}}` | Mid-chain close lid | Map stale | Same as 11 | code: same — no screen.watcher | |
| 15 | Display rearrange in System Settings | `{{1,2}}` | Open System Settings → Displays; drag display positions | Map stale until restart | Screen-watcher rebuilds; if `syncGroups` references out-of-range position, log warning | code: same — no screen.watcher | |

## Group D — macOS misbehavior

| # | Scenario | Setup | Steps | v0.2 expected | v3 expected | v0.2 actual | v3 actual |
|---|----------|-------|-------|---------------|-------------|-------------|-----------|
| 16 | Forced gotoSpace drop | Lower `obj.pollTimeout = 0.05` (v3 only) | Swipe 1 in `{{1,2,3,4}}` | n/a | Per-target verify times out; WARN log per target; chain continues; VERIFY_END_STATE flags drift | | |
| 17 ⊘ | Stage Manager toggled on **(out-of-scope; documented limitation)** | Enable Stage Manager mid-session | Swipe with fullscreen Space active | Untested | Polling likely times out on fullscreen Space; flagged in OmniFocus task as known-broken | | |
| 18 | Add Space via Mission Control | Mid-chain | Cmd+Up; press +; close MC | Possibly errors | NO_CHANGE absorbs spurious watcher fires | | |
| 19 ⊘ | Reorder Spaces via Mission Control **(out-of-scope; documented limitation)** | Mid-chain | Cmd+Up; drag a Space to new position | Index-based sync may go to wrong Space (Spaces have stable IDs but their index shifts) | Same — Space IDs stable, indices not. Out-of-scope follow-up | | |
| 20 | Display sleep + wake | Sleep all displays via menubar | Wait 30 s; wake | May not refire watcher | Same as v0.2 | | |
| 21 | `hs.reload()` mid-chain | Swipe; `hs -c 'hs.reload()'` within 1 s | | New VM; chain abandoned; baseline re-init | Same | | |

## Group E — lifecycle and configuration

| # | Scenario | Setup | Steps | v0.2 expected | v3 expected | v0.2 actual | v3 actual |
|---|----------|-------|-------|---------------|-------------|-------------|-----------|
| 22 | Accessibility revoked at `:start` | Revoke in System Settings → Privacy → Accessibility | `hs.reload()` | `gotoSpace` silently no-ops | Hard block: alert + abort; `state.osBlocked = true` | code: `:start` does NOT call `hs.accessibilityState` — confirms silent no-op | |
| 23 | Accessibility revoked at runtime | Revoke after `:start` succeeded | Swipe | gotoSpace silent fail | Per-target verify times out; logged at WARN | code: same — interactive-only | |
| 24 | Misconfigured syncGroups | `syncGroups = {{1,5}}` on 4-display setup | `:start` | Position 5 logs warning at start; never participates | Same; VALIDATE_CONFIG also logs on later screen-watcher fire | code: `getTargetsFor` lines 252-254 logs warning per missing position — matches | |
| 25 | `:status()` returns table | v3 only | `hs -c 'return spoon.SpacesSync:status()'` | n/a | Returns table per handoff doc §7 | n/a (v3-only) | |

## Group F — UI surfaces

| # | Scenario | Setup | Steps | v0.2 expected | v3 expected | v0.2 actual | v3 actual |
|---|----------|-------|-------|---------------|-------------|-------------|-----------|
| 26 | Picker hotkey during sync | | Swipe; mid-chain press ⌃⌥⌘N | Picker appears; existing behavior | Same | | |
| 27 | Rename hotkey | | ⌃⌥⌘R | Existing dialog | Same | | |
| 28 | Status HUD on toggle | | ⌃⌥⌘Y on then off | "ON"/"OFF" HUD shows | Same | | |
| 29 | Popup after sync | After scenario 1 | Visual | Popup on D1 with names | Same | | |
| 30 | Status HUD on display reconfig | | Plug/unplug a monitor | n/a | "SpacesSync: display layout changed" HUD | | |

---

## Reproducibility helpers

```bash
# Watch SpacesSync log lines:
hs -c 'return hs.console.getConsole()' | grep SpacesSync | tail -50

# Force a chain:
hs -c 'spoon.SpacesSync:stop(); spoon.SpacesSync:start()'

# Inspect v3 state (once item 10 lands):
hs -c 'return spoon.SpacesSync:status()'

# Reset all displays to Space index 1 (helper for setup):
hs -c '
for _, scr in ipairs(hs.screen.allScreens()) do
  local sps = hs.spaces.spacesForScreen(scr)
  if sps and sps[1] then hs.spaces.gotoSpace(sps[1]) end
end'
```

---

## What "passing" means per stage

- **After Stage 1 (cleanup):** all v0.2 scenarios still pass; B1 (`:start` race, scenario implicit in 1) no longer reproduces.
- **After Stage 2 (hardening):** scenarios 8, 22 newly pass; everything else unchanged from v0.2.
- **After Stage 3 (verify-core):** scenarios 1-3 pass with new timing; 5, 6, 7 newly pass; 16, 18, 24 pass.
- **After Stage 4 (screen watcher):** scenarios 11-15 newly pass.
- **After Stage 5 (diagnostics):** scenario 25 passes.

A v3 release is shippable when scenarios 1-16, 18, 21-25, 28-30 all pass; 17 (Stage Manager) and 19 (mid-chain reorder) are documented known limitations.
