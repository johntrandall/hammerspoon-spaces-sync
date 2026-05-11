-- L6 — Scenario 10: rapid double-toggle (no leaked timers)
--
-- Automates dev-docs/manual-test-checklist.md Group B scenario 10
-- ("Rapid double-toggle: press ⌃⌥⌘Y twice in <100 ms").
--
-- WHAT THIS PROVES
--   * `:toggle()` called twice in rapid succession (off then on) leaves
--     the Spoon cleanly enabled with no leaked chain timers and
--     `syncInProgress == false`.
--   * `:status()` returns the documented 12-key public shape after the
--     stop/start cycle (no fields silently dropped, no extras leaked).
--   * `chainGeneration` advances on the first toggle's `:stop()` (bumped
--     by +1, per init.lua:1747) AND is reset to 0 on the second toggle's
--     `:start()` (per init.lua:1709 — `:start()` re-initializes chain
--     state from scratch, including resetting the generation counter).
--     We verify BOTH halves: stop bumps, start resets. Capturing the
--     mid-arm value (between the two toggles) is required because the
--     final state alone is indistinguishable from "never advanced".
--
-- WHY THIS MATTERS
--   The user's hotkey can be hit twice within a single runloop tick
--   (e.g. autorepeat, double-tap). If `:stop()` and `:start()` don't
--   compose cleanly (orphaned timers from the brief enabled window
--   between them, half-cancelled chain, double-registered watchers),
--   the Spoon ends up in an inconsistent state where the menubar says
--   "on" but no sync happens. The manual checklist used to verify this
--   by hand — this scenario automates it.
--
-- ORCHESTRATION SHAPE (no disrupt phase — simpler than scenario-08/09):
--   1. probe()    — ensure Spoon is enabled, capture pre_chain_gen.
--   2. arm()      — perform the rapid double-toggle synchronously. Both
--                   `:toggle()` calls happen in a single `hs -c`
--                   invocation, so the gap between them is microseconds
--                   (well under the 100 ms manual-checklist threshold).
--   3. (run.sh sleeps SLEEP_BETWEEN seconds — any leaked timer would
--    fire and disturb state during this window.)
--   4. assert_()  — verify enabled, no leaked timers, syncInProgress
--                   false, chainGeneration bumped, status() shape sane.
--
-- IMPORTANT: this scenario performs no Space changes, so no restore is
-- needed. The arm() takes the Spoon off and back on; the post-arm sleep
-- gives any leaked timer time to misbehave.

local M = {}

local PLAN_KEY = "_SpacesSyncL6_Scenario10_Plan"

-- Canonical 12-key public shape of `:status()`. Authoritative source
-- is tests/L3/contract.lua's STATUS_SHAPE table — keep these in sync.
-- Keys flagged `nullable` are valid as nil per L3 contract (e.g.
-- lastVerifierResult is nil immediately after a fresh :start() before
-- any chain has completed a verifier pass).
local STATUS_KEYS = {
  { name = "enabled",            nullable = false },
  { name = "osBlocked",           nullable = false },
  { name = "syncInProgress",      nullable = false },
  { name = "chainGeneration",     nullable = false },
  { name = "activeChainTimers",   nullable = false },
  { name = "totalScreens",        nullable = false },
  { name = "positionMap",         nullable = false },
  { name = "syncGroups",          nullable = false },
  { name = "lastActiveSpaces",    nullable = false },
  { name = "lastVerifierResult",  nullable = true  },
  { name = "pollTimeout",         nullable = false },
  { name = "pollInterval",        nullable = false },
}

-- ---------------------------------------------------------------------------
-- Phase: probe — ensure enabled, snapshot baseline
-- ---------------------------------------------------------------------------

function M.probe()
  if not spoon or not spoon.SpacesSync then
    return "L6 SKIP: spoon.SpacesSync not loaded"
  end
  local s = spoon.SpacesSync
  if not s:isEnabled() then
    return "L6 SKIP: spoon.SpacesSync not :start()-ed (this test toggles twice; rerun after :start())"
  end

  local status = s:status()

  -- Don't run if a prior chain is still in flight — the stop() half of
  -- the first toggle would cancel its timers, polluting the "no leaked
  -- timers" assertion's signal.
  if status.syncInProgress then
    return "L6 SKIP: chain still in flight from prior activity (run.sh settle insufficient?)"
  end

  _G[PLAN_KEY] = {
    pre_chain_gen = status.chainGeneration,
  }

  return string.format(
    "L6 PROBE READY: enabled, syncInProgress=false, pre_gen=%d",
    status.chainGeneration)
end

-- ---------------------------------------------------------------------------
-- Phase: arm — rapid double-toggle (off then on, synchronously)
-- ---------------------------------------------------------------------------
--
-- Both `:toggle()` calls run inside the same `hs -c` invocation on the
-- same runloop tick — the gap between them is the cost of two Lua
-- method calls (microseconds), comfortably under the <100 ms threshold
-- the manual checklist describes.

function M.arm()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: arm called without prior probe"
  end
  if not spoon or not spoon.SpacesSync then
    return "L6 FAIL: spoon.SpacesSync vanished"
  end
  local s = spoon.SpacesSync

  -- Capture chainGeneration between the two toggles so assert_ can
  -- verify both halves of the contract:
  --   * after toggle #1 (:stop): gen advanced from pre_chain_gen
  --   * after toggle #2 (:start): gen reset to 0 (init.lua:1709)
  -- Both reads use :status() (the public surface), not state directly.

  -- First toggle: from enabled state, dispatches to :stop().
  s:toggle()
  plan.mid_chain_gen = s:status().chainGeneration

  -- Second toggle: from disabled state, dispatches to :start().
  s:toggle()
  plan.post_chain_gen = s:status().chainGeneration

  return string.format(
    "L6 ARM OK: double-toggled (pre=%d, mid=%d, post=%d)",
    plan.pre_chain_gen, plan.mid_chain_gen, plan.post_chain_gen)
end

-- ---------------------------------------------------------------------------
-- Phase: assert_ — verify clean state after the post-arm sleep
-- ---------------------------------------------------------------------------

function M.assert_()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: assert called without prior probe"
  end
  if not spoon or not spoon.SpacesSync then
    return "L6 FAIL: spoon.SpacesSync vanished"
  end
  local s = spoon.SpacesSync

  local final = s:status()
  _G[PLAN_KEY] = nil

  -- 1. We're back on.
  if final.enabled ~= true then
    return string.format(
      "L6 FAIL: enabled=%s after double-toggle, expected true",
      tostring(final.enabled))
  end

  -- 2. No leaked timers — the brief enabled window between toggle #1
  --    and toggle #2 shouldn't have spawned any timer that survived
  --    the :stop() reached via toggle #1. (Or if it did, the :start()
  --    reached via toggle #2 didn't double-register on top of it.)
  if final.activeChainTimers ~= 0 then
    return string.format(
      "L6 FAIL: activeChainTimers=%d after double-toggle + sleep, expected 0 " ..
      "(possible leaked timer from stop/start cycle)",
      final.activeChainTimers)
  end

  -- 3. No chain in flight. The double-toggle performed no Space
  --    changes, so nothing should have dispatched a sync.
  if final.syncInProgress ~= false then
    return string.format(
      "L6 FAIL: syncInProgress=%s after double-toggle + sleep, expected false",
      tostring(final.syncInProgress))
  end

  -- 4a. Toggle #1's :stop() bumped chainGeneration (init.lua:1747).
  if plan.mid_chain_gen <= plan.pre_chain_gen then
    return string.format(
      "L6 FAIL: toggle #1 (:stop) did not bump chainGeneration " ..
      "(pre=%d, mid=%d) — expected mid > pre",
      plan.pre_chain_gen, plan.mid_chain_gen)
  end

  -- 4b. Toggle #2's :start() reset chainGeneration to 0 (init.lua:1709).
  if plan.post_chain_gen ~= 0 then
    return string.format(
      "L6 FAIL: toggle #2 (:start) did not reset chainGeneration to 0 " ..
      "(post=%d) — :start() re-inits chain state per init.lua:1709",
      plan.post_chain_gen)
  end

  -- 4c. The 8s post-arm sleep didn't kick off any chain that would
  --     bump generation again.
  if final.chainGeneration ~= plan.post_chain_gen then
    return string.format(
      "L6 FAIL: chainGeneration drifted during post-arm sleep " ..
      "(post=%d, final=%d) — should be stable when no Space changes occurred",
      plan.post_chain_gen, final.chainGeneration)
  end

  -- 5. :status() returns the documented 12-key shape.
  --    Non-nullable keys must be present; nullable keys may be nil
  --    (a fresh :start() leaves lastVerifierResult nil until the
  --    first chain runs).
  local missing = {}
  local expected = {}
  for _, spec in ipairs(STATUS_KEYS) do
    expected[spec.name] = true
    if not spec.nullable and final[spec.name] == nil then
      table.insert(missing, spec.name)
    end
  end
  if #missing > 0 then
    return string.format(
      "L6 FAIL: :status() missing required keys after double-toggle: %s",
      table.concat(missing, ", "))
  end

  local extras = {}
  for k, _ in pairs(final) do
    if not expected[k] then
      table.insert(extras, k)
    end
  end
  if #extras > 0 then
    return string.format(
      "L6 FAIL: :status() returned unexpected extra keys after double-toggle: %s",
      table.concat(extras, ", "))
  end

  return string.format(
    "L6 PASS: scenario 10 — rapid double-toggle clean " ..
    "(enabled=true, timers=0, syncInProgress=false, gen %d -> %d (stop) -> %d (start), status 12-key shape OK)",
    plan.pre_chain_gen, plan.mid_chain_gen, plan.post_chain_gen)
end

return M
