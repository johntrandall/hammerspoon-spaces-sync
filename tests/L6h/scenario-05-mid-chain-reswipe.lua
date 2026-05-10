-- L6h — Scenario 5: user re-swipes trigger mid-chain
--
-- Automates dev-docs/manual-test-checklist.md Group B scenario 5.
--
-- WHY THIS IS L6h, NOT L6
--   The L6 prototype (now removed; commit 62b9701) proved that a
--   second `hs.spaces.gotoSpace` call fired while SpacesSync's own
--   chain is in flight is silently dropped by Mission Control. A
--   real trackpad swipe goes through a different input path that
--   Mission Control prioritizes. So the SECOND swipe must come from
--   a human; the FIRST and the assertions are automated.
--
-- WHAT THIS PROVES
--   1. GATE_RUNNING — when `state.syncInProgress = true`, the watcher
--      drops a Space-change event without starting a second chain.
--   2. End-of-chain `verifyEndState` detects the resulting drift:
--      `expectedEndState[trigger]` was captured as the FIRST swipe's
--      destination Space-ID, but actual at chain end is the SECOND
--      swipe's destination. Verifier reports `wrong-space` on the
--      trigger with `expectedIdx = first_dest`, `actualIdx = second_dest`.
--
-- PHASE SHAPE (driven by tests/L6h/run.sh)
--   probe()         — find a viable trigger/target pair where the
--                     trigger has 3+ Spaces (need cur + first_dest +
--                     second_dest distinct). Stash plan.
--   instructions()  — human-readable instructions for the user.
--   arm()           — fire the automated first swipe.
--   [user manually swipes trigger to second_dest within ~1s]
--   [shell sleep SETTLE_AFTER_USER]
--   assert_()       — read lastVerifierResult, verify the trigger
--                     wrong-space mismatch with expected idx pair.

local M = {}

local PLAN_KEY = "_SpacesSyncL6h_Scenario05_Plan"

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
    return "L6H SKIP: spoon.SpacesSync not loaded"
  end
  local s = spoon.SpacesSync
  if not s:isEnabled() then
    return "L6H SKIP: spoon.SpacesSync not :start()-ed"
  end

  local status = s:status()
  if status.syncInProgress then
    return "L6H SKIP: chain still in flight from prior activity"
  end

  local screens = screens_in_position_order()
  if #screens < 2 then
    return "L6H SKIP: only " .. #screens .. " display(s) connected; L6h needs >= 2"
  end

  local trigger_screen, trigger_pos
  local target_screen,  target_pos
  local cur_idx, first_dest_idx, second_dest_idx
  local trigger_start_sid, first_dest_sid, second_dest_sid

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
              if #tsps >= 3 then
                local tcur = hs.spaces.activeSpaceOnScreen(tscr)
                local tcur_idx = index_of(tsps, tcur)
                if tcur_idx then
                  local picks = {}
                  for cand = 1, math.min(#tsps, #xsps) do
                    if cand ~= tcur_idx then
                      table.insert(picks, cand)
                      if #picks >= 2 then break end
                    end
                  end
                  if #picks >= 2 then
                    trigger_screen   = tscr
                    trigger_pos      = tp
                    target_screen    = xscr
                    target_pos       = xp
                    cur_idx          = tcur_idx
                    first_dest_idx   = picks[1]
                    second_dest_idx  = picks[2]
                    trigger_start_sid = tcur
                    first_dest_sid   = tsps[picks[1]]
                    second_dest_sid  = tsps[picks[2]]
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
    return "L6H SKIP: no viable trigger/target pair " ..
           "(need a sync group with 2+ connected displays, trigger having 3+ Spaces)"
  end

  _G[PLAN_KEY] = {
    trigger_uuid       = trigger_screen:getUUID(),
    target_uuid        = target_screen:getUUID(),
    trigger_pos        = trigger_pos,
    target_pos         = target_pos,
    trigger_start_sid  = trigger_start_sid,
    cur_idx            = cur_idx,
    first_dest_sid     = first_dest_sid,
    first_dest_idx     = first_dest_idx,
    second_dest_sid    = second_dest_sid,
    second_dest_idx    = second_dest_idx,
    pre_verifier_ts    = (status.lastVerifierResult and status.lastVerifierResult.timestamp) or 0,
  }

  return string.format(
    "L6H PROBE READY: trigger pos %d (idx %d -> %d via auto, then -> %d via YOU), target pos %d",
    trigger_pos, cur_idx, first_dest_idx, second_dest_idx, target_pos)
end

-- ---------------------------------------------------------------------------
-- Phase: instructions (human-readable)
-- ---------------------------------------------------------------------------

function M.instructions()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "(probe not run yet)"
  end
  return string.format([[
This scenario tests that SpacesSync flags the trigger as drifted when
you swipe the trigger display a SECOND time while the sync chain is
still in flight.

SETUP CHECK
  * Trigger display: position %d
  * Trigger currently at: Space index %d
  * Target display:  position %d

THE PROCEDURE
  1. When I print ">>> NOW PERFORM THE MANUAL ACTION <<<" below,
     the trigger display will have just been programmatically
     swiped to Space index %d.

  2. WITHIN ~1 SECOND of seeing it land, swipe the SAME trigger
     display (position %d) ONE Space to the right — to Space
     index %d. Use the trackpad three-finger gesture (or
     ⌃-rightArrow on that display).

  3. The target display (position %d) is going to try to follow
     you to idx %d via the chain. That's fine — when YOU swipe
     the trigger to idx %d, the chain is still polling for the
     idx %d target landing. The watcher's second event is GATE_RUNNING-
     dropped (no second chain), and at chain end the verifier should
     flag the trigger as drifted.

  4. After your swipe, press Enter.

EXPECTED OUTCOME (asserted programmatically)
  * lastVerifierResult.mismatches has one entry for the trigger
    uuid with kind="wrong-space", expectedIdx=%d, actualIdx=%d.
  * No second chain ran (only one gen bump, not two).
]],
    plan.trigger_pos, plan.cur_idx, plan.target_pos,
    plan.first_dest_idx,
    plan.trigger_pos, plan.second_dest_idx,
    plan.target_pos, plan.first_dest_idx,
    plan.second_dest_idx, plan.first_dest_idx,
    plan.first_dest_idx, plan.second_dest_idx)
end

-- ---------------------------------------------------------------------------
-- Phase: arm — first (automated) swipe
-- ---------------------------------------------------------------------------

function M.arm()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6H FAIL: arm called without prior probe"
  end
  hs.spaces.gotoSpace(plan.first_dest_sid)
  return string.format(
    "L6H ARM OK: dispatched first gotoSpace(%s), idx %d -> %d. NOW SWIPE TO IDX %d.",
    tostring(plan.first_dest_sid), plan.cur_idx, plan.first_dest_idx, plan.second_dest_idx)
end

-- ---------------------------------------------------------------------------
-- Phase: assert_
-- ---------------------------------------------------------------------------

function M.assert_()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6H FAIL: assert called without prior probe"
  end
  if not spoon or not spoon.SpacesSync then
    return "L6H FAIL: spoon.SpacesSync vanished"
  end
  local s = spoon.SpacesSync

  -- CRITICAL: capture lastVerifierResult BEFORE restore (restore
  -- chain will overwrite it).
  local status = s:status()
  local lvr = status.lastVerifierResult

  -- Diagnostic: where IS the trigger now?
  local trigger_screen = hs.screen.find(plan.trigger_uuid)
  local trigger_active_now = trigger_screen and hs.spaces.activeSpaceOnScreen(trigger_screen)

  -- Best-effort restore. Fire-and-forget; the inter-test SETTLE in
  -- run.sh covers the resulting chain (or, if this is the last test,
  -- the user just lives with a displaced Space, which they can fix
  -- by swiping).
  local restore_ok = pcall(function()
    hs.spaces.gotoSpace(plan.trigger_start_sid)
  end)
  _G[PLAN_KEY] = nil

  if status.syncInProgress then
    return string.format(
      "L6H FAIL: chain still in flight at assert (SETTLE_AFTER_USER too short? pollTimeout=%g) [restore: %s]",
      status.pollTimeout, tostring(restore_ok))
  end
  if not lvr or lvr.timestamp <= plan.pre_verifier_ts then
    return string.format(
      "L6H FAIL: no new verifier result observed (pre_ts=%s, post_ts=%s) — " ..
      "did the first swipe land? [trigger_active_now=%s, restore: %s]",
      tostring(plan.pre_verifier_ts),
      tostring(lvr and lvr.timestamp),
      tostring(trigger_active_now), tostring(restore_ok))
  end

  -- Hard contract: trigger mismatch with the specific idx pair.
  local found
  for _, m in ipairs(lvr.mismatches or {}) do
    if m.uuid == plan.trigger_uuid and m.kind == "wrong-space" then
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
      "L6H FAIL: expected trigger wrong-space mismatch, none found. " ..
      "Saw %d mismatch(es): %s; trigger_active_at_assert=%s, " ..
      "expected_after_user_swipe=%s [restore: %s]",
      #(lvr.mismatches or {}),
      #kinds > 0 and table.concat(kinds, ", ") or "(none)",
      tostring(trigger_active_now),
      tostring(plan.second_dest_sid),
      tostring(restore_ok))
  end

  if found.expectedIdx ~= plan.first_dest_idx then
    return string.format(
      "L6H FAIL: trigger mismatch expectedIdx=%s, wanted first_dest_idx=%d [restore: %s]",
      tostring(found.expectedIdx), plan.first_dest_idx, tostring(restore_ok))
  end
  if found.actualIdx ~= plan.second_dest_idx then
    return string.format(
      "L6H FAIL: trigger mismatch actualIdx=%s, wanted second_dest_idx=%d " ..
      "(did you swipe to the right destination?) [restore: %s]",
      tostring(found.actualIdx), plan.second_dest_idx, tostring(restore_ok))
  end

  return string.format(
    "L6H PASS: scenario 5 — verifier flagged trigger drift " ..
    "(expectedIdx=%d, actualIdx=%d) [restore: %s]",
    found.expectedIdx, found.actualIdx, tostring(restore_ok))
end

return M
