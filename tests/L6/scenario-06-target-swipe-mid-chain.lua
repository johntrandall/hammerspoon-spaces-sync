-- L6 — Scenario 6: TARGET swipe mid-chain (fully automated via keystroke)
--
-- Automates dev-docs/manual-test-checklist.md Group B scenario 6.
--
-- HOW THIS DIFFERS FROM SCENARIO-05
--
--   Scenario-05: user re-swipes the TRIGGER mid-chain → trigger drift.
--   Scenario-06: user swipes a TARGET mid-chain → target drift.
--
--   The chain dispatches gotoSpace to the target (first_dest_idx).
--   While the chain is in flight, the user (here: an AppleScript
--   ⌃-rightArrow keystroke with the cursor on the target monitor)
--   moves the target's active Space by +1. The chain's
--   expectedEndState[target] = first_dest_sid; actual at chain end
--   = the +1 sid. Verifier flags target uuid with wrong-space.
--
--   See scenario-05's header for the full rationale on:
--     * why AppleScript ⌃-rightArrow vs hs.eventtap.keyStroke
--     * why pollInterval is bumped to 3.0
--     * why we poll until both displays have landed before firing
--       the keystroke (avoids Mission Control coalescing).
--
-- WHAT THIS PROVES
--   End-of-chain verifier detects TARGET drift caused by a user
--   swipe on the target display while the chain is in flight. The
--   GATE_RUNNING guard still drops the resulting watcher fire (no
--   second chain starts), but verifier catches the diff.
--
-- PHASE SHAPE (mirrors scenario-05)
--   1. probe()    — find trigger (2+ Spaces) and target (3+ Spaces,
--                   with cur_target_idx and cur_target_idx+1 both in
--                   range so ⌃-rightArrow moves target +1).
--   2. arm()      — gotoSpace(first_dest_sid) on the TRIGGER.
--   3. mid-sleep  — 1.0s; chain enters polling.
--   4. disrupt()  — poll until both displays land at first_dest_idx,
--                   then move cursor to TARGET center + ⌃-rightArrow.
--   5. sleep      — SLEEP_BETWEEN; chain finishes + verifier runs.
--   6. assert_()  — verify lvr has a wrong-space mismatch on the
--                   TARGET uuid with the right idx pair.

local M = {}

local PLAN_KEY = "_SpacesSyncL6_Scenario06_Plan"

-- pollInterval bump — same rationale as scenario-05: keep the chain
-- in flight ≥ 3s so the disrupt phase fires while syncInProgress=true.
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

  -- Wait briefly for any inter-test residual chain to settle.
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
  if #screens < 2 then
    return "L6 SKIP: only " .. #screens .. " display(s) connected; L6 needs >= 2"
  end

  -- Find a trigger/target pair. Trigger needs 2+ Spaces (so chain
  -- can dispatch it to first_dest_idx). Target needs 3+ Spaces
  -- AND cur_target_idx and cur_target_idx+1 must both be ≤ #target_spaces
  -- so ⌃-rightArrow on the target moves it +1 reliably. The chain
  -- dispatches the target to first_dest_idx (matching the trigger);
  -- the keystroke then moves target from first_dest_idx → first_dest_idx+1.
  -- So we need: first_dest_idx + 1 ≤ #target_spaces.
  local trigger_screen, trigger_pos
  local target_screen,  target_pos
  local cur_trigger_idx, first_dest_idx, target_drift_idx
  local trigger_start_sid, first_dest_sid_trigger
  local target_start_sid, target_first_dest_sid, target_drift_sid

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
              -- Trigger: 2+ Spaces. Target: 3+ Spaces.
              if #tsps >= 2 and #xsps >= 3 then
                local tcur = hs.spaces.activeSpaceOnScreen(tscr)
                local tcur_idx = index_of(tsps, tcur)
                if tcur_idx then
                  -- Pick first_dest_idx for the chain such that:
                  --   * first_dest_idx ≠ tcur_idx (so chain actually moves trigger)
                  --   * first_dest_idx + 1 ≤ #xsps (so target can drift +1)
                  --   * first_dest_idx ≤ #xsps (so chain can dispatch target there)
                  -- Iterate candidates 1..min(#tsps, #xsps - 1).
                  local maxFirst = math.min(#tsps, #xsps - 1)
                  local picked
                  for cand = 1, maxFirst do
                    if cand ~= tcur_idx then
                      picked = cand
                      break
                    end
                  end
                  if picked then
                    trigger_screen          = tscr
                    trigger_pos             = tp
                    target_screen           = xscr
                    target_pos              = xp
                    cur_trigger_idx         = tcur_idx
                    first_dest_idx          = picked
                    target_drift_idx        = picked + 1
                    trigger_start_sid       = tcur
                    first_dest_sid_trigger  = tsps[picked]
                    target_start_sid        = hs.spaces.activeSpaceOnScreen(xscr)
                    target_first_dest_sid   = xsps[picked]
                    target_drift_sid        = xsps[picked + 1]
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
           "(need sync group with 2+ displays; trigger 2+ Spaces, target 3+ Spaces with room for +1 drift)"
  end

  -- NOTE: M.required_* fields are applied by the dispatcher BEFORE
  -- probe runs. We do not touch them here.

  -- Frame center of the TARGET display (cursor goes here for the
  -- ⌃-rightArrow keystroke).
  local tf = target_screen:frame()

  _G[PLAN_KEY] = {
    trigger_uuid           = trigger_screen:getUUID(),
    target_uuid            = target_screen:getUUID(),
    trigger_pos            = trigger_pos,
    target_pos             = target_pos,
    cur_trigger_idx        = cur_trigger_idx,
    first_dest_idx         = first_dest_idx,
    target_drift_idx       = target_drift_idx,
    trigger_start_sid      = trigger_start_sid,
    first_dest_sid_trigger = first_dest_sid_trigger,
    target_start_sid       = target_start_sid,
    target_first_dest_sid  = target_first_dest_sid,
    target_drift_sid       = target_drift_sid,
    target_cx              = tf.x + tf.w / 2,
    target_cy              = tf.y + tf.h / 2,
    pre_verifier_ts        = (status.lastVerifierResult and status.lastVerifierResult.timestamp) or 0,
  }

  return string.format(
    "L6 PROBE READY: trigger pos %d (idx %d -> %d), target pos %d (chain -> idx %d, keystroke -> idx %d), pollInterval=%g",
    trigger_pos, cur_trigger_idx, first_dest_idx,
    target_pos, first_dest_idx, target_drift_idx,
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
-- Phase: disrupt — cursor on TARGET + ⌃-rightArrow
-- ---------------------------------------------------------------------------
--
-- Same shape as scenario-05's disrupt, but the cursor lands on the
-- TARGET monitor (not the trigger). The keystroke moves the target's
-- active Space from first_dest_idx → first_dest_idx + 1.
--
-- Watcher fires for the target's Space change; GATE_RUNNING drops it
-- (syncInProgress=true). At chain end, verifier sees:
--   expectedEndState[target] = target_first_dest_sid
--   actual[target]           = target_drift_sid (one to the right)
-- → wrong-space mismatch on target uuid.

function M.disrupt()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: disrupt called without prior probe"
  end

  local status = spoon.SpacesSync:status()
  if not status.syncInProgress then
    return "L6 FAIL: chain not in flight at disrupt time (pollInterval too low? chain ended too fast?)"
  end

  if plan.target_drift_idx ~= plan.first_dest_idx + 1 then
    return string.format(
      "L6 FAIL: keystroke moves +1, but plan wants target %d -> %d",
      plan.first_dest_idx, plan.target_drift_idx)
  end

  local trigger_screen = hs.screen.find(plan.trigger_uuid)
  local target_screen  = hs.screen.find(plan.target_uuid)
  if not trigger_screen or not target_screen then
    return "L6 FAIL: trigger or target screen vanished"
  end

  -- Poll until BOTH the trigger and the target have landed at their
  -- first-pass destinations. See scenario-05 disrupt header for why
  -- this is necessary (Mission Control idle → keystroke lands).
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

  -- Capture cursor for restore, move to TARGET center.
  local saved_mouse = hs.mouse.absolutePosition()
  hs.mouse.absolutePosition({ x = plan.target_cx, y = plan.target_cy })

  hs.timer.usleep(150000)

  local applescript_ok, applescript_err = hs.osascript.applescript(
    [[tell application "System Events" to key code 124 using {control down}]])

  hs.mouse.absolutePosition(saved_mouse)

  if not applescript_ok then
    return string.format(
      "L6 FAIL: AppleScript ⌃-rightArrow failed: %s", tostring(applescript_err))
  end

  return string.format(
    "L6 DISRUPT OK: both landed after %gs poll, then ⌃-rightArrow sent " ..
    "via AppleScript at TARGET cursor=(%.0f,%.0f); chain still in_progress",
    waited, plan.target_cx, plan.target_cy)
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
  local target_screen = hs.screen.find(plan.target_uuid)
  local target_active_now = target_screen and hs.spaces.activeSpaceOnScreen(target_screen)

  -- Restore trigger to its original Space. Best-effort. (The dispatcher's
  -- syncGroups restore + stop/start cycle will pull both displays back
  -- to a consistent state on next user activity.)
  local restore_ok = pcall(function()
    hs.spaces.gotoSpace(plan.trigger_start_sid)
  end)

  _G[PLAN_KEY] = nil

  -- ---- assertions ----

  if status.syncInProgress then
    return string.format(
      "L6 FAIL: chain still in flight at assert (SLEEP_BETWEEN too short? pollInterval=%g) [restore: %s]",
      status.pollInterval, tostring(restore_ok))
  end
  if not lvr or lvr.timestamp <= plan.pre_verifier_ts then
    return string.format(
      "L6 FAIL: no new verifier result observed (pre_ts=%s, post_ts=%s) — " ..
      "did the arm fire? [target_active_now=%s, restore: %s]",
      tostring(plan.pre_verifier_ts),
      tostring(lvr and lvr.timestamp),
      tostring(target_active_now), tostring(restore_ok))
  end

  -- Hard contract: TARGET mismatch with the specific idx pair.
  local found
  for _, m in ipairs(lvr.mismatches or {}) do
    if m.uuid == plan.target_uuid and m.kind == "wrong-space" then
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
      "L6 FAIL: expected TARGET wrong-space mismatch, none found. " ..
      "Saw %d mismatch(es): %s; target_active_at_assert=%s, " ..
      "expected_after_keystroke=%s [restore: %s]",
      #(lvr.mismatches or {}),
      #kinds > 0 and table.concat(kinds, ", ") or "(none)",
      tostring(target_active_now),
      tostring(plan.target_drift_sid),
      tostring(restore_ok))
  end

  if found.expectedIdx ~= plan.first_dest_idx then
    return string.format(
      "L6 FAIL: target mismatch expectedIdx=%s, wanted first_dest_idx=%d [restore: %s]",
      tostring(found.expectedIdx), plan.first_dest_idx, tostring(restore_ok))
  end
  if found.actualIdx ~= plan.target_drift_idx then
    return string.format(
      "L6 FAIL: target mismatch actualIdx=%s, wanted target_drift_idx=%d " ..
      "(did the keystroke land on the TARGET monitor?) [restore: %s]",
      tostring(found.actualIdx), plan.target_drift_idx, tostring(restore_ok))
  end

  return string.format(
    "L6 PASS: scenario 6 — keystroke-driven TARGET swipe flagged target drift " ..
    "(expectedIdx=%d, actualIdx=%d) [restore: %s]",
    found.expectedIdx, found.actualIdx, tostring(restore_ok))
end

return M
