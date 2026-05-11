-- L6 — Scenario 3: single swipe, 4-display sync group
--
-- Automates dev-docs/manual-test-checklist.md Group A scenario 3.
-- Same shape as scenario-02 but with N=4. Verifies the chain's
-- N-target recursion holds at the largest realistic group size.
--
-- CONFIG (set by the L6 dispatcher via M.required_syncGroups):
--   obj.syncGroups = {{1, 2, 3, 4}}  — trigger + three targets

local M = {}

local PLAN_KEY = "_SpacesSyncL6_Scenario03_Plan"

M.required_syncGroups = { { 1, 2, 3, 4 } }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

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
  local waited = 0
  while status.syncInProgress and waited < 5.0 do
    hs.timer.usleep(250000)
    waited = waited + 0.25
    status = s:status()
  end
  if status.syncInProgress then
    return "L6 SKIP: chain still in flight after 5 s wait"
  end

  local screens = screens_in_position_order()
  if #screens < 4 then
    return "L6 SKIP: only " .. #screens .. " display(s) connected; scenario-03 needs >= 4"
  end

  local trigger_scr = screens[1]
  local target_scrs = { screens[2], screens[3], screens[4] }

  local trigger_spaces = hs.spaces.spacesForScreen(trigger_scr) or {}
  local trigger_start_sid = hs.spaces.activeSpaceOnScreen(trigger_scr)
  local trigger_start_idx = index_of(trigger_spaces, trigger_start_sid)
  if not trigger_start_idx then
    return "L6 SKIP: cannot resolve current index of trigger Space"
  end

  -- Find destination idx that exists on trigger AND all targets.
  local max_common = #trigger_spaces
  for _, tscr in ipairs(target_scrs) do
    local tsps = hs.spaces.spacesForScreen(tscr) or {}
    if #tsps < max_common then max_common = #tsps end
  end
  if max_common < 2 then
    return "L6 SKIP: not all displays have 2+ Spaces"
  end

  local dest_idx
  for cand = 1, max_common do
    if cand ~= trigger_start_idx then
      dest_idx = cand
      break
    end
  end
  if not dest_idx then
    return "L6 SKIP: trigger has no Space to swipe to"
  end
  local dest_sid = trigger_spaces[dest_idx]

  _G[PLAN_KEY] = {
    trigger_uuid       = trigger_scr:getUUID(),
    target_uuids       = {
      target_scrs[1]:getUUID(),
      target_scrs[2]:getUUID(),
      target_scrs[3]:getUUID(),
    },
    trigger_start_sid  = trigger_start_sid,
    trigger_start_idx  = trigger_start_idx,
    dest_idx           = dest_idx,
    dest_sid           = dest_sid,
    pre_verifier_ts    = (status.lastVerifierResult and status.lastVerifierResult.timestamp) or 0,
  }

  return string.format(
    "L6 PROBE READY: trigger pos 1 (idx %d -> %d), 3 targets (pos 2, 3, 4), dest_sid=%s",
    trigger_start_idx, dest_idx, tostring(dest_sid))
end

-- ---------------------------------------------------------------------------
-- Phase: arm
-- ---------------------------------------------------------------------------

function M.arm()
  local plan = _G[PLAN_KEY]
  if not plan then return "L6 FAIL: arm called without prior probe" end
  hs.spaces.gotoSpace(plan.dest_sid)
  return "L6 ARM OK: dispatched gotoSpace(" .. tostring(plan.dest_sid) .. ")"
end

-- ---------------------------------------------------------------------------
-- Phase: assert_
-- ---------------------------------------------------------------------------

function M.assert_()
  local plan = _G[PLAN_KEY]
  if not plan then return "L6 FAIL: assert called without prior probe" end
  if not spoon or not spoon.SpacesSync then return "L6 FAIL: spoon.SpacesSync vanished" end
  local s = spoon.SpacesSync

  local status = s:status()
  local lvr = status.lastVerifierResult
  local new_chain_ran = lvr and lvr.timestamp > plan.pre_verifier_ts

  -- Capture per-target actual idx now, before restore overwrites.
  local actuals = {}
  for i, uuid in ipairs(plan.target_uuids) do
    local scr = hs.screen.find(uuid)
    local active = scr and hs.spaces.activeSpaceOnScreen(scr)
    local sps = scr and (hs.spaces.spacesForScreen(scr) or {})
    local idx
    if sps then idx = index_of(sps, active) end
    actuals[i] = { uuid = uuid, idx = idx, sid = active }
  end

  -- Best-effort restore.
  local restore_ok = pcall(function()
    hs.spaces.gotoSpace(plan.trigger_start_sid)
  end)
  _G[PLAN_KEY] = nil

  if status.syncInProgress then
    return string.format("L6 FAIL: chain still in flight at assert (pollTimeout=%g)",
      status.pollTimeout)
  end
  if not new_chain_ran then
    return string.format("L6 FAIL: no new verifier result (pre_ts=%s, post_ts=%s)",
      tostring(plan.pre_verifier_ts), tostring(lvr and lvr.timestamp))
  end
  if #lvr.mismatches ~= 0 then
    local kinds = {}
    for _, m in ipairs(lvr.mismatches) do
      table.insert(kinds, m.kind or "?")
    end
    return string.format("L6 FAIL: verifier reported %d mismatch(es): %s",
      #lvr.mismatches, table.concat(kinds, ", "))
  end

  for i, a in ipairs(actuals) do
    if a.idx ~= plan.dest_idx then
      return string.format(
        "L6 FAIL: target %d (pos %d) at idx %s, expected idx %d [restore: %s]",
        i, i + 1, tostring(a.idx), plan.dest_idx, tostring(restore_ok))
    end
  end

  return string.format(
    "L6 PASS: scenario 3 — trigger pos 1 -> idx %d, all 3 targets (pos 2, 3, 4) followed " ..
    "[verifier clean, restore: %s]",
    plan.dest_idx, tostring(restore_ok))
end

return M
