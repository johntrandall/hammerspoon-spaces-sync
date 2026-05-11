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
-- Separate key for the saved sync-group config so cleanup() can run
-- independently of plan lifecycle. Populated by probe; cleared by
-- cleanup. Survives the assert_-time nil-out of PLAN_KEY.
local CLEANUP_KEY = "_SpacesSyncL6h_Scenario05_Cleanup"

-- The sync-group configuration this scenario REQUIRES. probe() saves
-- the current obj.syncGroups, swaps in this value, and calls
-- :stop():start() to re-arm. cleanup() restores the original. The
-- test does not assume John's host already has this configured.
M.required_sync_groups = { { 2, 3 } }

-- pollTimeout AND pollInterval overrides during this scenario. Why
-- both:
--   * pollTimeout = MAX time the chain will wait for the target to
--     land. NOT the chain duration — if the target lands in 100 ms,
--     the chain ends in ~100 ms regardless of pollTimeout.
--   * pollInterval = how often the chain polls activeSpaces during
--     the wait. The chain only "notices" the target has landed at
--     the next poll tick. So pollInterval is effectively the
--     MINIMUM chain duration after dispatch.
--
-- Default pollInterval is ~0.25 s, so the chain ends ~0.25 s after
-- the target's gotoSpace lands — a tight ~1 s window for the user
-- to mid-chain-swipe before the chain has already finished.
--
-- Bumping pollInterval to 4.0 makes the chain take AT LEAST 4 s
-- (one full poll cycle) regardless of how fast the target lands.
-- That matches the user's 4-second action window. pollTimeout=8.0
-- gives headroom for slow targets. Both restored in cleanup.
M.required_pollTimeout  = 8.0
M.required_pollInterval = 4.0

-- Time-window mode (see tests/L6h/run.sh § PHASE 4). After arm the
-- runner prints "GO!", sleeps this many seconds, and proceeds to
-- settle + assert. NO second Enter prompt. Necessary because the
-- user's swipe moves Spaces on the trigger display, and any terminal
-- on that display would vanish along with the prior Space — making
-- a follow-up Enter prompt invisible to the user.
M.action_window_seconds = 4

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

-- "1st", "2nd", "3rd", "4th", ...
local function ordinal(n)
  if n == 1 then return "1st"
  elseif n == 2 then return "2nd"
  elseif n == 3 then return "3rd"
  else return tostring(n) .. "th" end
end

-- ASCII row of monitors with the trigger / target highlighted.
-- e.g. for plan.total_screens=4 and trigger_pos=2, target_pos=3:
--   [ #1 ] [*#2*] [ #3 ] [ #4 ]   (left-to-right, your physical layout)
local function display_row(plan)
  local boxes = {}
  for i = 1, plan.total_screens do
    if i == plan.trigger_pos then
      table.insert(boxes, "[*#" .. i .. "*]")
    else
      table.insert(boxes, "[ #" .. i .. " ]")
    end
  end
  return table.concat(boxes, " ")
end

-- One-line action summary, surfaced by the runner IMMEDIATELY BEFORE
-- the "fire when ready" prompt. The user reads the full instructions
-- once at scenario start; this one-liner is the in-the-moment cue.
function M.user_action_summary()
  local plan = _G[PLAN_KEY]
  if not plan then return "(probe not run yet)" end
  return string.format(
    'Move CURSOR onto the TRIGGER monitor "%s" (%s from your left). ' ..
    'Three-finger swipe RIGHT to send it from its %s Space to its %s Space.',
    plan.trigger_name, ordinal(plan.trigger_pos),
    ordinal(plan.first_dest_idx), ordinal(plan.second_dest_idx))
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

  -- Test-owned sync group configuration. Deep-copy the current
  -- obj.syncGroups so cleanup() can restore it byte-for-byte even
  -- if a future change makes the structure deeper.
  local saved_syncGroups = {}
  if type(s.syncGroups) == "table" then
    for gi, g in ipairs(s.syncGroups) do
      if type(g) == "table" then
        saved_syncGroups[gi] = {}
        for pi, p in ipairs(g) do
          saved_syncGroups[gi][pi] = p
        end
      end
    end
  end

  -- Swap in this scenario's required config (deep-copy from M to be
  -- safe against future mutation), then re-arm via stop/start so the
  -- watcher's baseline reflects the new groups. NB: this resets
  -- chainGeneration and lastVerifierResult on the live Spoon.
  local required = {}
  for gi, g in ipairs(M.required_sync_groups) do
    required[gi] = {}
    for pi, p in ipairs(g) do required[gi][pi] = p end
  end
  s.syncGroups = required

  -- Save + override timing knobs. See M.required_pollTimeout /
  -- M.required_pollInterval comments at the top of this file.
  local saved_pollTimeout  = s.pollTimeout
  local saved_pollInterval = s.pollInterval
  s.pollTimeout  = M.required_pollTimeout
  s.pollInterval = M.required_pollInterval

  s:stop()
  s:start()
  -- Stash the saved config for cleanup() — survives the assert_-time
  -- nil-out of PLAN_KEY so cleanup is independent.
  _G[CLEANUP_KEY] = {
    syncGroups   = saved_syncGroups,
    pollTimeout  = saved_pollTimeout,
    pollInterval = saved_pollInterval,
  }
  -- Re-fetch status now that the new config is live.
  status = s:status()

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
    trigger_name       = trigger_screen:name() or ("position " .. trigger_pos),
    target_pos         = target_pos,
    target_name        = target_screen:name() or ("position " .. target_pos),
    total_screens      = #screens,
    trigger_start_sid  = trigger_start_sid,
    cur_idx            = cur_idx,
    first_dest_sid     = first_dest_sid,
    first_dest_idx     = first_dest_idx,
    second_dest_sid    = second_dest_sid,
    second_dest_idx    = second_dest_idx,
    pre_verifier_ts    = (status.lastVerifierResult and status.lastVerifierResult.timestamp) or 0,
    saved_syncGroups   = saved_syncGroups,
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

  -- Build the "independent monitors" list for the config blurb.
  local indep = {}
  for i = 1, plan.total_screens do
    if i ~= plan.trigger_pos and i ~= plan.target_pos then
      table.insert(indep, tostring(i))
    end
  end
  local indep_str = #indep > 0 and table.concat(indep, " and ") or "(none)"

  return string.format([[
This scenario tests that SpacesSync flags the TRIGGER monitor as
drifted when you swipe IT a second time while the sync chain is
still in flight.

CONFIGURATION (set by the test; restored on cleanup)
  * obj.syncGroups = {{%d, %d}}
       — only the %s and %s monitors sync with each other
       — the %s monitor(s) (%s from left) are INDEPENDENT

YOUR MONITORS (left to right)
    %s
              ^^^^^
              this is the TRIGGER monitor

  * TRIGGER: "%s"   (the %s monitor from your left)
       ← you'll swipe THIS monitor mid-chain
  * TARGET:  "%s"   (the %s monitor from your left)
       ← the chain will pull this along to follow the trigger

  Your terminal was moved to a NON-sync-group monitor at startup;
  it should stay visible throughout the test.

PREPARATION (do THIS BEFORE pressing Enter at the next prompt)
  * Move your cursor onto the TRIGGER monitor ("%s" — the %s
    from your left) and keep it there.
  * This is REQUIRED. Three-finger trackpad swipes only affect
    the monitor under the cursor. You won't have time to move
    the cursor after the chain starts.
  * Your fingers should be on the trackpad, ready to swipe right.

THE PROCEDURE
  1. Press Enter at the next prompt. The test programmatically
     moves the TRIGGER monitor ("%s") to its %s Space. You do
     nothing for this step — just watch that monitor change.

  2. As soon as the TRIGGER monitor lands on its %s Space, do
     a three-finger trackpad swipe RIGHT. (Cursor is already on
     the TRIGGER monitor from preparation.) This sends it from
     its %s Space to its %s Space.

  3. After your swipe, do nothing. The runner sleeps the action
     window, then ~%ds for the chain to settle, then asserts.
     NO ENTER NEEDED after your swipe.

EXPECTED OUTCOME (asserted programmatically)
  * The verifier flags the TRIGGER monitor as drifted:
      expected: its %s Space (where the chain dispatched it)
      actual:   its %s Space (where you swiped to)
  * Only ONE chain ran — your re-swipe should be GATE_RUNNING-
    dropped, not start a second chain.
]],
    plan.trigger_pos, plan.target_pos,                            -- 1,2 config {{N,N}}
    plan.trigger_name, plan.target_name,                          -- 3,4 config "X and Y monitors"
    (#indep > 0 and "remaining" or "(no)"),                       -- 5   config word
    indep_str,                                                    -- 6   config "1 and 4 from left"
    display_row(plan),                                            -- 7   layout row
    plan.trigger_name, ordinal(plan.trigger_pos),                 -- 8,9 layout trigger line
    plan.target_name, ordinal(plan.target_pos),                   -- 10,11 layout target line
    plan.trigger_name, ordinal(plan.trigger_pos),                 -- 12,13 PREPARATION
    plan.trigger_name, ordinal(plan.first_dest_idx),              -- 14,15 step 1
    ordinal(plan.first_dest_idx),                                 -- 16    step 2 "lands on its X Space"
    ordinal(plan.first_dest_idx), ordinal(plan.second_dest_idx),  -- 17,18 step 2 "from X to Y"
    -- approximate settle = 3 * pollTimeout + 2 (capped at 8); we
    -- can't know the exact value without re-reading status, but
    -- for required_pollTimeout=8 it's 26s.
    math.floor(3 * (M.required_pollTimeout or 2) + 2),            -- 19   step 3 settle seconds
    ordinal(plan.first_dest_idx), ordinal(plan.second_dest_idx))  -- 20,21 expected outcome
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

-- ---------------------------------------------------------------------------
-- Phase: cleanup — restore original syncGroups
-- ---------------------------------------------------------------------------
--
-- The runner invokes this AFTER every scenario that returned PROBE
-- READY, regardless of subsequent phase outcomes. The plan was
-- cleared in assert_, so we re-read the saved config from a runner-
-- side cache. Belt-and-suspenders: also accept a stash on _G that
-- assert_ may leave behind if it ran. For simplicity in this test
-- we keep the plan alive in a second key for cleanup only.

function M.cleanup()
  local saved = _G[CLEANUP_KEY]
  if not saved then
    return "L6H CLEANUP SKIP: no saved config (probe didn't run, or already restored)"
  end
  if not spoon or not spoon.SpacesSync then
    return "L6H CLEANUP FAIL: spoon.SpacesSync vanished"
  end
  local s = spoon.SpacesSync
  -- Deep-copy on restore — the runner might call cleanup more than
  -- once across separate hs -c invocations.
  local restored = {}
  for gi, g in ipairs(saved.syncGroups or {}) do
    if type(g) == "table" then
      restored[gi] = {}
      for pi, p in ipairs(g) do restored[gi][pi] = p end
    end
  end
  s.syncGroups = restored
  if type(saved.pollTimeout) == "number" then
    s.pollTimeout = saved.pollTimeout
  end
  if type(saved.pollInterval) == "number" then
    s.pollInterval = saved.pollInterval
  end
  s:stop()
  s:start()
  _G[CLEANUP_KEY] = nil
  return "L6H CLEANUP OK: restored syncGroups + pollTimeout + pollInterval"
end

return M
