-- L6 — Scenario 1: single swipe, 2-display group
--
-- Automates dev-docs/manual-test-checklist.md Group A scenario 1.
--
-- Per dev-docs/test-strategy.md § Active Levels L6 + § Operational Notes
-- + § Test Layout (L6 test design note):
--   * Three-phase orchestration: probe / arm / assert (the runloop-
--     blocking property of `hs -c` rules out single-invocation waits).
--   * Probe MUST read positionMap and syncGroups from :status() to
--     discover a viable trigger/target pair at runtime — picking a
--     trigger whose current Space index has somewhere to go and whose
--     target display has a Space at the candidate destination index.
--     SKIP if no viable pair exists.
--   * Restore via real gotoSpace(triggerStart); the resulting sync
--     chain lands the targets back. The test does NOT assert on
--     restore success.
--   * CRITICAL: assert phase MUST read :status().lastVerifierResult
--     BEFORE dispatching restore (the restore chain's verifier
--     overwrites that field when it completes).
--
-- Plan is stashed in _G[PLAN_KEY] between phases so subsequent `hs -c`
-- invocations see it.
--
-- Phases (the runner invokes each separately):
--   M.probe()    — preflight + plan; returns "L6 PROBE READY" or
--                  "L6 SKIP: <reason>" or "L6 FAIL: <reason>".
--   M.arm()      — dispatch trigger; returns "L6 ARM OK" / "L6 FAIL".
--   M.assert_()  — read result, restore Spaces; returns "L6 PASS" /
--                  "L6 FAIL: <reason>".

local M = {}

local PLAN_KEY = "_SpacesSyncL6_Scenario01_Plan"

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
    return "L6 SKIP: spoon.SpacesSync not :start()-ed"
  end

  local status = s:status()

  -- Need at least one sync group with >= 2 members AT POSITIONS that
  -- are currently connected.
  local screens = screens_in_position_order()
  if #screens < 2 then
    return "L6 SKIP: only " .. #screens .. " display(s) connected; L6 needs >= 2"
  end

  local trigger_screen, trigger_pos
  local target_screen,  target_pos
  local trigger_spaces, target_spaces
  local trigger_start_idx, dest_idx
  local trigger_start_sid, dest_sid

  for _, group in ipairs(status.syncGroups or {}) do
    if type(group) == "table" and #group >= 2 then
      -- Try each pairing within the group: pick the FIRST viable one.
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
                  -- Pick a destination index different from current AND
                  -- existing on BOTH trigger and target.
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
                    trigger_spaces   = tsps
                    target_spaces    = xsps
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

  -- Stash plan for arm + assert phases.
  _G[PLAN_KEY] = {
    trigger_uuid       = trigger_screen:getUUID(),
    target_uuid        = target_screen:getUUID(),
    trigger_pos        = trigger_pos,
    target_pos         = target_pos,
    trigger_start_sid  = trigger_start_sid,
    trigger_start_idx  = trigger_start_idx,
    dest_idx           = dest_idx,
    dest_sid           = dest_sid,
    -- Capture pre-test verifier timestamp so assert can detect a NEW
    -- result (vs. a stale one from a prior chain).
    pre_verifier_ts    = (status.lastVerifierResult and status.lastVerifierResult.timestamp) or 0,
  }

  return string.format(
    "L6 PROBE READY: trigger pos %d (idx %d -> %d), target pos %d, dest sid=%s",
    trigger_pos, trigger_start_idx, dest_idx, target_pos, tostring(dest_sid))
end

-- ---------------------------------------------------------------------------
-- Phase: arm
-- ---------------------------------------------------------------------------

function M.arm()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: arm called without prior probe"
  end
  -- Dispatch the trigger swipe. Returns immediately; the runloop
  -- pumps the watcher / chain / verifier once this hs -c call returns
  -- and the shell sleeps before assert.
  hs.spaces.gotoSpace(plan.dest_sid)
  return "L6 ARM OK: dispatched gotoSpace(" .. tostring(plan.dest_sid) .. ")"
end

-- ---------------------------------------------------------------------------
-- Phase: assert
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

  -- CRITICAL: read :status() and capture lastVerifierResult BEFORE
  -- dispatching restore. The restore chain's verifier will overwrite
  -- the field once it runs.
  local status = s:status()
  local lvr = status.lastVerifierResult

  -- Did a NEW chain run? Compare timestamp to the pre-test capture.
  local new_chain_ran = lvr and lvr.timestamp > plan.pre_verifier_ts

  -- Capture the actual target Space NOW (before restore moves it).
  local target_screen = hs.screen.find(plan.target_uuid)
  local target_active = target_screen and hs.spaces.activeSpaceOnScreen(target_screen)
  local target_actual_idx
  if target_screen and target_active then
    local tsps = hs.spaces.spacesForScreen(target_screen) or {}
    target_actual_idx = index_of(tsps, target_active)
  end

  -- Trigger restore now (fire-and-forget). The chain it starts will
  -- overwrite lastVerifierResult, but we already captured what we need.
  local restore_dispatched = false
  if plan.trigger_start_sid then
    local ok = pcall(function() hs.spaces.gotoSpace(plan.trigger_start_sid) end)
    restore_dispatched = ok
  end
  -- Clear plan so a stale plan can't poison the next run.
  _G[PLAN_KEY] = nil

  -- Now evaluate the result.
  if status.syncInProgress then
    return string.format(
      "L6 FAIL: chain still in progress at assert time " ..
      "(SLEEP_BETWEEN may be too short — formula is max(8, 3*pollTimeout+2); " ..
      "current pollTimeout=%g) [restore dispatched: %s]",
      status.pollTimeout, tostring(restore_dispatched))
  end

  if not new_chain_ran then
    return string.format(
      "L6 FAIL: no new verifier result observed " ..
      "(pre_ts=%s, post_ts=%s) — did the trigger fire? [restore: %s]",
      tostring(plan.pre_verifier_ts),
      tostring(lvr and lvr.timestamp),
      tostring(restore_dispatched))
  end

  if #lvr.mismatches ~= 0 then
    -- Verifier saw mismatches — sync chain didn't fully land.
    local kinds = {}
    for _, m in ipairs(lvr.mismatches) do
      table.insert(kinds, m.kind)
    end
    return string.format(
      "L6 FAIL: verifier reported %d mismatch(es): %s [restore: %s]",
      #lvr.mismatches, table.concat(kinds, ", "), tostring(restore_dispatched))
  end

  -- Did the target actually land at the destination index?
  if target_actual_idx ~= plan.dest_idx then
    return string.format(
      "L6 FAIL: target ended at idx %s, expected idx %d [restore: %s]",
      tostring(target_actual_idx), plan.dest_idx, tostring(restore_dispatched))
  end

  return string.format(
    "L6 PASS: scenario 1 — trigger pos %d -> idx %d, target pos %d followed " ..
    "[verifier clean, restore: %s]",
    plan.trigger_pos, plan.dest_idx, plan.target_pos, tostring(restore_dispatched))
end

return M
