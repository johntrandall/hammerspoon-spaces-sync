-- L6 — Scenario 7: INDEPENDENT display swipe mid-chain (fully automated)
--
-- Automates dev-docs/manual-test-checklist.md Group B scenario 7.
--
-- HOW THIS DIFFERS FROM SCENARIO-05 / SCENARIO-06
--
--   Scenario-05: user re-swipes the TRIGGER (in sync group)  → trigger drift.
--   Scenario-06: user swipes a   TARGET   (in sync group)    → target drift.
--   Scenario-07: user swipes an  INDEPENDENT display (NOT in any sync group)
--                while a chain is in flight on a different sync group.
--
--   The chain does NOT dispatch to the independent display (not a
--   target). BUT — captureExpectedEndState() snapshots EVERY connected
--   display's active sid at chain start, including independents. At
--   chain end, the verifier walks all displays and compares actual
--   vs expectedEndState. The independent display's sid changed (due
--   to the user's keystroke), so it flags as wrong-space on the
--   INDEPENDENT uuid — not on the trigger, not on the target.
--
--   This proves the verifier's coverage extends to non-sync-group
--   displays — it doesn't just check the displays the chain touched.
--
--   See scenario-05's header for the full rationale on:
--     * why AppleScript ⌃-rightArrow vs hs.eventtap.keyStroke
--     * why pollInterval is bumped to 3.0
--     * why we poll until the chain-touched displays have landed
--       before firing the keystroke.
--
-- PHASE SHAPE
--   1. probe()    — find a sync group with 2+ displays (trigger+target)
--                   AND a third display OUTSIDE the sync group with
--                   2+ consecutive Spaces (independent display).
--   2. arm()      — gotoSpace(first_dest_sid) on the TRIGGER (in group).
--   3. mid-sleep  — 1.0s; chain enters polling.
--   4. disrupt()  — poll until trigger+target landed, then move cursor
--                   to the INDEPENDENT monitor + ⌃-rightArrow.
--   5. sleep      — SLEEP_BETWEEN; chain finishes + verifier runs.
--   6. assert_()  — verify lvr has a wrong-space mismatch on the
--                   INDEPENDENT uuid (NOT trigger, NOT target).

local M = {}

local PLAN_KEY = "_SpacesSyncL6_Scenario07_Plan"

-- Required config: bumped pollInterval to keep chain in flight, and
-- sync group { 2, 3 } so positions 1 and 4 are candidates for the
-- independent display.
M.required_syncGroups   = { { 2, 3 } }
M.required_pollInterval = 3.0
M.required_pollTimeout  = 8.0

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

-- Build a set of positions that appear in any sync group.
local function positions_in_any_group(groups)
  local in_group = {}
  for _, group in ipairs(groups or {}) do
    if type(group) == "table" then
      for _, pos in ipairs(group) do
        in_group[pos] = true
      end
    end
  end
  return in_group
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

  -- Wait for inter-test residual chain to settle.
  local status = s:status()
  local waited = 0
  while status.syncInProgress and waited < 5.0 do
    hs.timer.usleep(250000)
    waited = waited + 0.25
    status = s:status()
  end
  if status.syncInProgress then
    return "L6 SKIP: chain still in flight after 5s wait (prior scenario didn't settle)"
  end

  local screens = screens_in_position_order()
  if #screens < 3 then
    return "L6 SKIP: only " .. #screens .. " display(s) connected; scenario-07 needs >= 3 " ..
           "(2 in sync group + 1 independent)"
  end

  -- Find a (trigger, target) pair in a sync group AND an independent
  -- display NOT in any sync group with 2+ consecutive Spaces.
  local in_group = positions_in_any_group(status.syncGroups)

  local trigger_screen, trigger_pos
  local target_screen,  target_pos
  local cur_trigger_idx, first_dest_idx
  local trigger_start_sid, first_dest_sid_trigger
  local target_first_dest_sid

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
                  local maxIdx = math.min(#tsps, #xsps)
                  for cand = 1, maxIdx do
                    if cand ~= tcur_idx then
                      trigger_screen          = tscr
                      trigger_pos             = tp
                      target_screen           = xscr
                      target_pos              = xp
                      cur_trigger_idx         = tcur_idx
                      first_dest_idx          = cand
                      trigger_start_sid       = tcur
                      first_dest_sid_trigger  = tsps[cand]
                      target_first_dest_sid   = xsps[cand]
                      break
                    end
                  end
                  if trigger_screen then break end
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
    return "L6 SKIP: no viable trigger/target pair in any sync group"
  end

  -- Find an INDEPENDENT display: a position NOT in any sync group,
  -- with 2+ Spaces and current idx + 1 in range (so ⌃-rightArrow
  -- moves it +1 reliably).
  local indep_screen, indep_pos
  local cur_indep_idx, indep_drift_idx
  local indep_start_sid, indep_drift_sid

  for pos = 1, #screens do
    if not in_group[pos] then
      local iscr = screens[pos]
      local isps = hs.spaces.spacesForScreen(iscr) or {}
      if #isps >= 2 then
        local icur = hs.spaces.activeSpaceOnScreen(iscr)
        local icur_idx = index_of(isps, icur)
        if icur_idx and (icur_idx + 1) <= #isps then
          indep_screen     = iscr
          indep_pos        = pos
          cur_indep_idx    = icur_idx
          indep_drift_idx  = icur_idx + 1
          indep_start_sid  = icur
          indep_drift_sid  = isps[icur_idx + 1]
          break
        end
      end
    end
  end

  if not indep_screen then
    return "L6 SKIP: no viable independent display (need a non-sync-group display " ..
           "with 2+ Spaces and cur_idx+1 in range)"
  end

  -- NOTE: M.required_* fields are applied by the dispatcher BEFORE
  -- probe runs. We do not touch them here.

  local indf = indep_screen:frame()

  _G[PLAN_KEY] = {
    trigger_uuid           = trigger_screen:getUUID(),
    target_uuid            = target_screen:getUUID(),
    indep_uuid             = indep_screen:getUUID(),
    trigger_pos            = trigger_pos,
    target_pos             = target_pos,
    indep_pos              = indep_pos,
    cur_trigger_idx        = cur_trigger_idx,
    first_dest_idx         = first_dest_idx,
    cur_indep_idx          = cur_indep_idx,
    indep_drift_idx        = indep_drift_idx,
    trigger_start_sid      = trigger_start_sid,
    first_dest_sid_trigger = first_dest_sid_trigger,
    target_first_dest_sid  = target_first_dest_sid,
    indep_start_sid        = indep_start_sid,
    indep_drift_sid        = indep_drift_sid,
    indep_cx               = indf.x + indf.w / 2,
    indep_cy               = indf.y + indf.h / 2,
    pre_verifier_ts        = (status.lastVerifierResult and status.lastVerifierResult.timestamp) or 0,
  }

  return string.format(
    "L6 PROBE READY: trigger pos %d (idx %d -> %d), target pos %d, " ..
    "INDEPENDENT pos %d (idx %d -> %d via keystroke), pollInterval=%g",
    trigger_pos, cur_trigger_idx, first_dest_idx,
    target_pos,
    indep_pos, cur_indep_idx, indep_drift_idx,
    M.required_pollInterval)
end

-- ---------------------------------------------------------------------------
-- Phase: arm — automated first swipe on the TRIGGER
-- ---------------------------------------------------------------------------

function M.arm()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: arm called without prior probe"
  end
  hs.spaces.gotoSpace(plan.first_dest_sid_trigger)
  return "L6 ARM OK: dispatched first gotoSpace(" .. tostring(plan.first_dest_sid_trigger) ..
         ") on trigger, idx " .. tostring(plan.cur_trigger_idx) .. " -> " .. tostring(plan.first_dest_idx)
end

-- ---------------------------------------------------------------------------
-- Phase: disrupt — cursor on INDEPENDENT display + ⌃-rightArrow
-- ---------------------------------------------------------------------------
--
-- Wait for trigger + target to land at first_dest_idx (the chain's
-- targets in the sync group), then place cursor on the INDEPENDENT
-- monitor and send ⌃-rightArrow. The keystroke moves the independent's
-- active Space by +1.
--
-- The watcher fires for the independent display's Space change. Since
-- syncInProgress=true (chain still polling), GATE_RUNNING drops the
-- event. At chain end, the verifier walks ALL displays and finds:
--   expectedEndState[indep] = indep_start_sid (captured at chain start)
--   actual[indep]           = indep_drift_sid (after keystroke)
-- → wrong-space mismatch on independent uuid.

function M.disrupt()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: disrupt called without prior probe"
  end

  local status = spoon.SpacesSync:status()
  if not status.syncInProgress then
    return "L6 FAIL: chain not in flight at disrupt time (pollInterval too low? chain ended too fast?)"
  end

  if plan.indep_drift_idx ~= plan.cur_indep_idx + 1 then
    return string.format(
      "L6 FAIL: keystroke moves +1, but plan wants indep %d -> %d",
      plan.cur_indep_idx, plan.indep_drift_idx)
  end

  local trigger_screen = hs.screen.find(plan.trigger_uuid)
  local target_screen  = hs.screen.find(plan.target_uuid)
  local indep_screen   = hs.screen.find(plan.indep_uuid)
  if not trigger_screen or not target_screen or not indep_screen then
    return "L6 FAIL: trigger, target, or independent screen vanished"
  end

  -- Poll until trigger + target landed. (Independent is untouched
  -- by the chain, so we don't wait on it.)
  local waited = 0
  while waited < 2.5 do
    local trigger_at = hs.spaces.activeSpaceOnScreen(trigger_screen)
    local target_at  = hs.spaces.activeSpaceOnScreen(target_screen)
    if trigger_at == plan.first_dest_sid_trigger and target_at == plan.target_first_dest_sid then
      break
    end
    hs.timer.usleep(100000)
    waited = waited + 0.1
  end

  local trigger_landed = hs.spaces.activeSpaceOnScreen(trigger_screen) == plan.first_dest_sid_trigger
  local target_landed  = hs.spaces.activeSpaceOnScreen(target_screen)  == plan.target_first_dest_sid
  if not (trigger_landed and target_landed) then
    return string.format(
      "L6 FAIL: not both landed after %gs poll — trigger_landed=%s, target_landed=%s",
      waited, tostring(trigger_landed), tostring(target_landed))
  end

  status = spoon.SpacesSync:status()
  if not status.syncInProgress then
    return string.format(
      "L6 FAIL: chain ended during %gs-wait for landing (pollInterval too low?)",
      waited)
  end

  -- Capture cursor, move to INDEPENDENT center.
  local saved_mouse = hs.mouse.absolutePosition()
  hs.mouse.absolutePosition({ x = plan.indep_cx, y = plan.indep_cy })

  hs.timer.usleep(150000)

  local applescript_ok, applescript_err = hs.osascript.applescript(
    [[tell application "System Events" to key code 124 using {control down}]])

  hs.mouse.absolutePosition(saved_mouse)

  if not applescript_ok then
    return string.format(
      "L6 FAIL: AppleScript ⌃-rightArrow failed: %s", tostring(applescript_err))
  end

  return string.format(
    "L6 DISRUPT OK: trigger+target landed after %gs poll, then ⌃-rightArrow sent " ..
    "via AppleScript at INDEPENDENT cursor=(%.0f,%.0f); chain still in_progress",
    waited, plan.indep_cx, plan.indep_cy)
end

-- ---------------------------------------------------------------------------
-- Phase: assert_
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

  -- CRITICAL: capture lvr BEFORE the restore gotoSpace.
  local status = s:status()
  local lvr = status.lastVerifierResult

  -- Diagnostic captures.
  local indep_screen = hs.screen.find(plan.indep_uuid)
  local indep_active_now = indep_screen and hs.spaces.activeSpaceOnScreen(indep_screen)

  -- Restore: pull trigger back (chain will re-sync the target). The
  -- independent display we leave at its drifted state — the user may
  -- want to keep it there, and the next scenario's probe doesn't
  -- depend on the independent being at any particular Space.
  -- Actually: be polite. Try to restore the independent too.
  local restore_trigger_ok = pcall(function()
    hs.spaces.gotoSpace(plan.trigger_start_sid)
  end)
  local restore_indep_ok = pcall(function()
    hs.spaces.gotoSpace(plan.indep_start_sid)
  end)

  _G[PLAN_KEY] = nil

  -- ---- assertions ----

  if status.syncInProgress then
    return string.format(
      "L6 FAIL: chain still in flight at assert (SLEEP_BETWEEN too short? pollInterval=%g) " ..
      "[restore trigger: %s, indep: %s]",
      status.pollInterval, tostring(restore_trigger_ok), tostring(restore_indep_ok))
  end
  if not lvr or lvr.timestamp <= plan.pre_verifier_ts then
    return string.format(
      "L6 FAIL: no new verifier result observed (pre_ts=%s, post_ts=%s) — " ..
      "did the arm fire? [indep_active_now=%s, restore trigger: %s, indep: %s]",
      tostring(plan.pre_verifier_ts),
      tostring(lvr and lvr.timestamp),
      tostring(indep_active_now),
      tostring(restore_trigger_ok), tostring(restore_indep_ok))
  end

  -- Hard contract: INDEPENDENT mismatch with the specific idx pair.
  -- Must NOT be on trigger or target uuids.
  local found
  for _, m in ipairs(lvr.mismatches or {}) do
    if m.uuid == plan.indep_uuid and m.kind == "wrong-space" then
      found = m
      break
    end
  end

  if not found then
    local kinds = {}
    for _, m in ipairs(lvr.mismatches or {}) do
      table.insert(kinds, (m.uuid or "?") .. "/" .. (m.kind or "?"))
    end
    return string.format(
      "L6 FAIL: expected INDEPENDENT wrong-space mismatch, none found. " ..
      "Saw %d mismatch(es): %s; indep_active_at_assert=%s, " ..
      "expected_after_keystroke=%s [restore trigger: %s, indep: %s]",
      #(lvr.mismatches or {}),
      #kinds > 0 and table.concat(kinds, ", ") or "(none)",
      tostring(indep_active_now),
      tostring(plan.indep_drift_sid),
      tostring(restore_trigger_ok), tostring(restore_indep_ok))
  end

  if found.expectedIdx ~= plan.cur_indep_idx then
    return string.format(
      "L6 FAIL: independent mismatch expectedIdx=%s, wanted cur_indep_idx=%d " ..
      "[restore trigger: %s, indep: %s]",
      tostring(found.expectedIdx), plan.cur_indep_idx,
      tostring(restore_trigger_ok), tostring(restore_indep_ok))
  end
  if found.actualIdx ~= plan.indep_drift_idx then
    return string.format(
      "L6 FAIL: independent mismatch actualIdx=%s, wanted indep_drift_idx=%d " ..
      "(did the keystroke land on the INDEPENDENT monitor?) [restore trigger: %s, indep: %s]",
      tostring(found.actualIdx), plan.indep_drift_idx,
      tostring(restore_trigger_ok), tostring(restore_indep_ok))
  end

  return string.format(
    "L6 PASS: scenario 7 — keystroke on INDEPENDENT display flagged drift " ..
    "(expectedIdx=%d, actualIdx=%d) [restore trigger: %s, indep: %s]",
    found.expectedIdx, found.actualIdx,
    tostring(restore_trigger_ok), tostring(restore_indep_ok))
end

return M
