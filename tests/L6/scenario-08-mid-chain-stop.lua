-- L6 — Scenario 8: mid-chain :stop()
--
-- Automates dev-docs/manual-test-checklist.md Group B scenario 8.
--
-- Per dev-docs/test-strategy.md § Active Levels L6 + § Operational Notes
-- + § Test Layout (L6 test design note):
--
-- WHAT THIS PROVES
--   * `:stop()` invoked while a sync chain is in flight halts the chain:
--     no further dispatch, all chain-owned timers drained, and the
--     `chainGeneration` bail token (init.lua item 0a) is bumped so any
--     callback closure still queued by `hs.timer` bails on its next tick.
--   * `:start()` after stop returns the live session to a healthy state.
--
-- WHY THIS MATTERS
--   The chainGeneration bail logic is the v3 invariant that prevents a
--   long-tail callback from a previous chain (e.g. a watchdog scheduled
--   3 × pollTimeout seconds ago) from racing against state set up by a
--   newer chain or a clean shutdown. A regression here would be silent
--   — the chain would "stop" but stale callbacks would still execute,
--   corrupting `state.lastActiveSpaces` or re-igniting dispatch.
--
-- ORCHESTRATION SHAPE (5 phases, see tests/L6/run.sh)
--   1. probe()    — find a viable trigger/target pair, stash plan.
--   2. arm()      — dispatch gotoSpace, return immediately. Runner
--                   then sleeps MID_SLEEP=1s so the watcher fires and
--                   the chain enters its first poll cycle.
--   3. disrupt()  — capture in-flight observables, call :stop(),
--                   capture post-stop observables. Returns immediately.
--                   Runner then sleeps SLEEP_BETWEEN so any stale
--                   callback (watchdog, poll tick) has time to fire
--                   AND bail.
--   4. assert_()  — verify state remained quiescent through the post-
--                   disrupt sleep (chainGeneration STABLE, timers 0,
--                   syncInProgress false). Then :start() to leave the
--                   live session healthy for subsequent tests / users.
--
-- IMPORTANT: this is the only L6 scenario that calls :stop() / :start()
-- on the live Spoon. It MUST restart the Spoon in assert_ regardless of
-- pass/fail outcome — otherwise the user is left without sync.

local M = {}

local PLAN_KEY = "_SpacesSyncL6_Scenario08_Plan"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Sort screens by frame x then y, matching the Spoon's positionMap convention.
local function screens_in_position_order()
  local screens = {}
  for _, s in ipairs(hs.screen.allScreens()) do
    table.insert(screens, s)
  end
  table.sort(screens, function(a, b)
    local fa, fb = a:frame(), b:frame()
    if fa.x ~= fb.x then return fa.x < fb.x end
    return fa.y < fb.y
  end)
  return screens
end

local function index_of(spaces, sid)
  for i, v in ipairs(spaces) do
    if v == sid then return i end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Phase: probe
-- ---------------------------------------------------------------------------

function M.probe()
  if not spoon or not spoon.SpacesSync then
    return "L6 SKIP: spoon.SpacesSync not loaded"
  end
  local s = spoon.SpacesSync
  if not s:isEnabled() then
    return "L6 SKIP: spoon.SpacesSync not :start()-ed (this test will restart it; rerun after :start())"
  end

  local status = s:status()

  -- Don't run if a prior chain is still in flight — it would pollute
  -- our chainGeneration baseline. Caller (run.sh) is expected to settle
  -- between tests, so this is a guard, not a routine condition.
  if status.syncInProgress then
    return "L6 SKIP: chain still in flight from prior activity (run.sh settle insufficient?)"
  end

  local screens = screens_in_position_order()
  if #screens < 2 then
    return "L6 SKIP: only " .. #screens .. " display(s) connected; L6 needs >= 2"
  end

  -- Same trigger/target discovery as scenario-01.
  local trigger_screen, trigger_pos
  local target_screen,  target_pos
  local trigger_start_idx, dest_idx
  local trigger_start_sid, dest_sid

  for _, group in ipairs(status.syncGroups or {}) do
    if type(group) == "table" and #group >= 2 then
      for i = 1, #group do
        for j = 1, #group do
          if i ~= j then
            local tp = group[i]
            local xp = group[j]
            local tscr = screens[tp]
            local xscr = screens[xp]
            if tscr and xscr then
              local tsps = hs.spaces.spacesForScreen(tscr) or {}
              local xsps = hs.spaces.spacesForScreen(xscr) or {}
              if #tsps >= 2 and #xsps >= 2 then
                local tcur = hs.spaces.activeSpaceOnScreen(tscr)
                local tcur_idx = index_of(tsps, tcur)
                if tcur_idx then
                  local candidate_idx
                  for cand = 1, math.min(#tsps, #xsps) do
                    if cand ~= tcur_idx then
                      candidate_idx = cand
                      break
                    end
                  end
                  if candidate_idx then
                    trigger_screen   = tscr
                    trigger_pos      = tp
                    target_screen    = xscr
                    target_pos       = xp
                    trigger_start_idx = tcur_idx
                    dest_idx         = candidate_idx
                    trigger_start_sid = tcur
                    dest_sid         = tsps[candidate_idx]
                    break
                  end
                end
              end
            end
          end
          if trigger_screen then break end
        end
        if trigger_screen then break end
      end
    end
    if trigger_screen then break end
  end

  if not trigger_screen then
    return "L6 SKIP: no viable trigger/target pair " ..
           "(need a sync group with 2+ connected displays each with 2+ Spaces, " ..
           "and at least one alternate Space available on the trigger)"
  end

  _G[PLAN_KEY] = {
    trigger_uuid       = trigger_screen:getUUID(),
    target_uuid        = target_screen:getUUID(),
    trigger_pos        = trigger_pos,
    target_pos         = target_pos,
    trigger_start_sid  = trigger_start_sid,
    trigger_start_idx  = trigger_start_idx,
    dest_idx           = dest_idx,
    dest_sid           = dest_sid,
    pre_chain_gen      = status.chainGeneration,
    -- Filled in during disrupt():
    during_chain_gen   = nil,
    during_in_progress = nil,
    during_timers      = nil,
    post_stop_gen      = nil,
    post_stop_enabled  = nil,
    post_stop_timers   = nil,
  }

  return string.format(
    "L6 PROBE READY: trigger pos %d (idx %d -> %d), target pos %d, dest sid=%s, pre_gen=%d",
    trigger_pos, trigger_start_idx, dest_idx, target_pos,
    tostring(dest_sid), status.chainGeneration)
end

-- ---------------------------------------------------------------------------
-- Phase: arm
-- ---------------------------------------------------------------------------

function M.arm()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: arm called without prior probe"
  end
  hs.spaces.gotoSpace(plan.dest_sid)
  return "L6 ARM OK: dispatched gotoSpace(" .. tostring(plan.dest_sid) .. ")"
end

-- ---------------------------------------------------------------------------
-- Phase: disrupt — capture in-flight state, then :stop()
-- ---------------------------------------------------------------------------
--
-- Called after MID_SLEEP=1s shell-sleep. At pollTimeout=2.0 the chain
-- should be in its first poll cycle when this runs (watcher fires
-- immediately on Space change; chain dispatches gotoSpace on targets;
-- first poll fires at +pollInterval ≈ 0.25s; chain still polling at
-- t=1s). If the chain has already finished, we still test :stop() on
-- an idle Spoon but flag the run as "did not exercise mid-chain bail".

function M.disrupt()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: disrupt called without prior probe"
  end
  if not spoon or not spoon.SpacesSync then
    return "L6 FAIL: spoon.SpacesSync vanished"
  end
  local s = spoon.SpacesSync

  -- Snapshot state DURING the chain (or post-completion if chain was fast).
  local during = s:status()
  plan.during_chain_gen   = during.chainGeneration
  plan.during_in_progress = during.syncInProgress
  plan.during_timers      = during.activeChainTimers

  -- The disruption itself.
  s:stop()

  -- Snapshot state immediately after stop (synchronously, before the
  -- runloop pumps anything).
  local post = s:status()
  plan.post_stop_gen     = post.chainGeneration
  plan.post_stop_enabled = post.enabled
  plan.post_stop_timers  = post.activeChainTimers
  plan.post_stop_inprog  = post.syncInProgress

  return string.format(
    "L6 DISRUPT OK: during={gen=%d, inProgress=%s, timers=%d} " ..
    "post-stop={gen=%d, enabled=%s, timers=%d, inProgress=%s}",
    plan.during_chain_gen, tostring(plan.during_in_progress), plan.during_timers,
    plan.post_stop_gen, tostring(plan.post_stop_enabled),
    plan.post_stop_timers, tostring(plan.post_stop_inprog))
end

-- ---------------------------------------------------------------------------
-- Phase: assert_ — verify post-disrupt sleep was quiescent, then restart
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

  -- Snapshot state at end of post-disrupt sleep. By this point any
  -- stale callback (poll tick, watchdog) should have fired AND bailed
  -- via the chainGeneration check. If chainGeneration is stable and
  -- timers are still 0 and enabled is still false, the bail logic
  -- worked.
  local final = s:status()

  -- ALWAYS restart the Spoon at the end of this test, regardless of
  -- pass/fail. Otherwise the live user session is left without sync.
  -- Use pcall so a restart failure doesn't mask the test result.
  local restart_ok, restart_err = pcall(function() s:start() end)

  -- Best-effort restore: :stop() halted the chain mid-flight, so the
  -- trigger and possibly some targets are at the destination Space,
  -- not where the user / next test had them. Dispatch a restore
  -- gotoSpace so the active Space rotates back. Fire-and-forget; the
  -- next-test SETTLE_BETWEEN_TESTS sleep lets the resulting chain
  -- settle before the next probe.
  local restore_ok = false
  if restart_ok and plan.trigger_start_sid then
    restore_ok = pcall(function() hs.spaces.gotoSpace(plan.trigger_start_sid) end)
  end

  _G[PLAN_KEY] = nil

  -- Assertions on the captured state.

  -- 1. Immediately after stop, enabled MUST be false. (Hard contract:
  --    if this fails, :stop() itself is broken.)
  if plan.post_stop_enabled ~= false then
    return string.format(
      "L6 FAIL: post-stop enabled=%s, expected false [restart: %s/%s]",
      tostring(plan.post_stop_enabled),
      tostring(restart_ok), tostring(restart_err))
  end

  -- 2. Immediately after stop, syncInProgress MUST be false.
  if plan.post_stop_inprog ~= false then
    return string.format(
      "L6 FAIL: post-stop syncInProgress=%s, expected false [restart: %s/%s]",
      tostring(plan.post_stop_inprog),
      tostring(restart_ok), tostring(restart_err))
  end

  -- 3. Immediately after stop, activeChainTimers MUST be 0
  --    (cancelChainTimers was called inside :stop).
  if plan.post_stop_timers ~= 0 then
    return string.format(
      "L6 FAIL: post-stop activeChainTimers=%d, expected 0 [restart: %s/%s]",
      plan.post_stop_timers, tostring(restart_ok), tostring(restart_err))
  end

  -- 4. :stop() bumped chainGeneration (so any in-flight chain's myGen
  --    is now stale and its callbacks will bail).
  if plan.post_stop_gen <= plan.during_chain_gen then
    return string.format(
      "L6 FAIL: chainGeneration not bumped by :stop() " ..
      "(during=%d, post-stop=%d) [restart: %s/%s]",
      plan.during_chain_gen, plan.post_stop_gen,
      tostring(restart_ok), tostring(restart_err))
  end

  -- 5. After the post-disrupt sleep, chainGeneration MUST be stable
  --    (no NEW chain started, no stale callback resurrected anything).
  --    Note: by this point we've ALREADY called :start() above, which
  --    bumps generation back to 0 — so compare `final` (captured
  --    BEFORE restart) to post-stop, not the live status.
  if final.chainGeneration ~= plan.post_stop_gen then
    return string.format(
      "L6 FAIL: chainGeneration moved during post-disrupt sleep " ..
      "(post-stop=%d, end-of-sleep=%d) — a stale callback may have re-armed " ..
      "or a new chain started [restart: %s/%s]",
      plan.post_stop_gen, final.chainGeneration,
      tostring(restart_ok), tostring(restart_err))
  end

  -- 6. activeChainTimers MUST be 0 at end of post-disrupt sleep
  --    (no timer should have re-armed itself).
  if final.activeChainTimers ~= 0 then
    return string.format(
      "L6 FAIL: activeChainTimers=%d at end of post-disrupt sleep, expected 0 " ..
      "[restart: %s/%s]",
      final.activeChainTimers, tostring(restart_ok), tostring(restart_err))
  end

  -- 7. enabled MUST still be false at end of post-disrupt sleep.
  if final.enabled ~= false then
    return string.format(
      "L6 FAIL: enabled=%s at end of post-disrupt sleep, expected false " ..
      "[restart: %s/%s]",
      tostring(final.enabled), tostring(restart_ok), tostring(restart_err))
  end

  if not restart_ok then
    return string.format(
      "L6 FAIL: assertions passed but :start() restart failed: %s",
      tostring(restart_err))
  end

  -- Report whether we actually caught the chain mid-flight (soft signal).
  local caught_in_flight = plan.during_in_progress == true
  return string.format(
    "L6 PASS: scenario 8 — :stop() halted chain " ..
    "(caught_in_flight=%s, gen %d->%d->%d, restart: ok, restore: %s)",
    tostring(caught_in_flight),
    plan.pre_chain_gen, plan.during_chain_gen, plan.post_stop_gen,
    tostring(restore_ok))
end

return M
