-- L6 — Scenario 5: mid-chain re-swipe (fully automated via keystroke)
--
-- Automates dev-docs/manual-test-checklist.md Group B scenario 5.
--
-- HOW THIS WORKS — and why it can be FULLY AUTOMATED (unlike the
-- L6h version in tests/L6h/scenario-05-mid-chain-reswipe.lua)
--
--   The original problem: a second `hs.spaces.gotoSpace(sid)` fired
--   while SpacesSync's chain is in flight is silently dropped by
--   Mission Control. See dev-docs/hammerspoon-and-spaces-quirks.md
--   § "Rapid gotoSpace() calls get silently dropped" + L6 testing
--   footnote. That's why scenario-05 was originally moved to L6h
--   (human-in-loop) — only a real trackpad swipe could provoke the
--   second Space change.
--
--   This implementation goes through a DIFFERENT input path: an
--   AppleScript "tell System Events to key code 124 using {control
--   down}" invoked via hs.osascript. Mission Control treats this
--   as a user-driven Space switch (same as the trackpad), NOT as
--   another AX gotoSpace call. So it survives the in-flight-chain
--   serialization that drops AX gotoSpace.
--
--   Why AppleScript-via-System-Events and not hs.eventtap.keyStroke?
--   We tested both: `hs.eventtap.keyStroke({"ctrl"}, "right", 0)`
--   fires (no error) but Mission Control does NOT receive it —
--   keyStroke posts to the frontmost app's input queue, while
--   Mission Control hotkeys are handled at the system level before
--   app routing. AppleScript's System Events posts at a higher
--   level that the system hotkey path observes. Verified empirically:
--   AppleScript-via-System-Events moves Display 2 from idx 2 to
--   idx 3 reliably; hs.eventtap.keyStroke does not.
--
--   The cursor must be on the trigger monitor for ⌃-rightArrow to
--   target THAT monitor's Spaces — we move it programmatically via
--   `hs.mouse.absolutePosition()`, then restore it.
--
-- WHAT THIS PROVES (same as the L6h version):
--   1. GATE_RUNNING — watcher drops a second Space-change event
--      while state.syncInProgress=true; no second chain starts.
--   2. End-of-chain verifier detects the trigger drift:
--      expectedEndState[trigger] = first_dest_sid (where the chain
--      dispatched it), but actual at chain end = second_dest_sid
--      (where the keystroke moved it).
--
-- PHASE SHAPE (5 phases — reuses scenario-08's disrupt-phase shape)
--   1. probe()    — find trigger/target with 3+ Spaces; save +
--                   override pollInterval (so the chain stays in
--                   flight ≥ 1 s); stash plan + cleanup record.
--   2. arm()      — fire the automated FIRST gotoSpace.
--   3. mid-sleep  — 1.0s; watcher fires, chain enters polling.
--   4. disrupt()  — move cursor to trigger monitor + send
--                   ⌃-rightArrow keystroke. Watcher fires for the
--                   resulting Space change; GATE_RUNNING drops it.
--   5. sleep      — SLEEP_BETWEEN; chain finishes polling + verifier.
--   6. assert_()  — verify lastVerifierResult has a wrong-space
--                   mismatch on the trigger with the right idx pair.
--                   Restore pollInterval. Restore syncGroups (if
--                   they were swapped — currently a no-op since
--                   we don't change them in this test).

local M = {}

local PLAN_KEY = "_SpacesSyncL6_Scenario05_Plan"

-- pollInterval bump during this test. The chain's minimum duration
-- is bounded BELOW by pollInterval (chain only "notices" the target
-- has landed at the next poll tick). Default pollInterval ~= 0.25 s
-- means the chain ends ~0.5 s after the target lands — far too short
-- for the disrupt phase to fire while the chain is still in flight.
-- Bumping to 3.0 keeps the chain in flight ≥ 3 s; MID_SLEEP=1 s
-- leaves 2+ s of in-flight time when disrupt() runs.
M.required_pollInterval = 3.0
-- pollTimeout headroom so the bumped pollInterval doesn't bump up
-- against the deadline.
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

  -- Wait briefly for any inter-test residual chain to settle (e.g.
  -- the restore gotoSpace from the prior scenario's assert phase
  -- can still be polling). Without this, scenario-05 deterministically
  -- SKIPs when it runs second in the L6 dispatcher.
  local status = s:status()
  local waited = 0
  while status.syncInProgress and waited < 5.0 do
    hs.timer.usleep(250000)  -- 250 ms
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

  -- Find a pair: trigger needs 3+ Spaces (cur + first_dest + second_dest),
  -- target needs >= first_dest_idx Spaces.
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
                  -- Pick CONSECUTIVE destinations: first_dest and
                  -- second_dest = first_dest + 1. The disrupt phase
                  -- sends ⌃-rightArrow which moves +1 index, so the
                  -- two destinations must be adjacent. Also both must
                  -- be ≠ cur_idx and within range of BOTH displays.
                  local maxIdx = math.min(#tsps, #xsps)
                  local picks = {}
                  for cand = 1, maxIdx - 1 do
                    if cand ~= tcur_idx and (cand + 1) ~= tcur_idx and (cand + 1) <= maxIdx then
                      picks = { cand, cand + 1 }
                      break
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
    return "L6 SKIP: no viable trigger/target pair " ..
           "(need a sync group with 2+ connected displays, trigger having 3+ Spaces)"
  end

  -- Bump pollInterval + pollTimeout so the chain stays in flight long
  -- enough for the disrupt phase to catch it. Save originals for assert_
  -- to restore.
  local saved_pollInterval = s.pollInterval
  local saved_pollTimeout  = s.pollTimeout
  s.pollInterval = M.required_pollInterval
  s.pollTimeout  = M.required_pollTimeout
  -- Re-arm so the new timing takes effect on the next chain.
  s:stop()
  s:start()

  -- Re-resolve the trigger Space sids — :stop/:start might have shuffled
  -- the active Space (it shouldn't, but be defensive).
  local tsps_post = hs.spaces.spacesForScreen(trigger_screen) or {}
  trigger_start_sid = hs.spaces.activeSpaceOnScreen(trigger_screen)
  cur_idx = index_of(tsps_post, trigger_start_sid) or cur_idx
  -- first_dest_sid / second_dest_sid by index — sids may have re-numbered
  -- but indices remain stable across :stop/:start.
  if tsps_post[first_dest_idx] then first_dest_sid = tsps_post[first_dest_idx] end
  if tsps_post[second_dest_idx] then second_dest_sid = tsps_post[second_dest_idx] end

  -- Frame center for cursor placement during disrupt.
  local f = trigger_screen:frame()

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
    trigger_cx         = f.x + f.w / 2,
    trigger_cy         = f.y + f.h / 2,
    pre_verifier_ts    = (status.lastVerifierResult and status.lastVerifierResult.timestamp) or 0,
    saved_pollInterval = saved_pollInterval,
    saved_pollTimeout  = saved_pollTimeout,
  }

  return string.format(
    "L6 PROBE READY: trigger pos %d (idx %d -> %d via arm, then -> %d via keystroke), target pos %d, pollInterval=%g",
    trigger_pos, cur_idx, first_dest_idx, second_dest_idx, target_pos, M.required_pollInterval)
end

-- ---------------------------------------------------------------------------
-- Phase: arm — first (auto) swipe via hs.spaces.gotoSpace
-- ---------------------------------------------------------------------------

function M.arm()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: arm called without prior probe"
  end
  hs.spaces.gotoSpace(plan.first_dest_sid)
  return "L6 ARM OK: dispatched first gotoSpace(" .. tostring(plan.first_dest_sid) ..
         "), idx " .. tostring(plan.cur_idx) .. " -> " .. tostring(plan.first_dest_idx)
end

-- ---------------------------------------------------------------------------
-- Phase: disrupt — cursor + keystroke for the SECOND swipe
-- ---------------------------------------------------------------------------
--
-- Called after MID_SLEEP=1s. The first chain is in flight
-- (pollInterval=3s keeps it running for ≥3s after arm). We:
--   1. Capture the cursor's current position (for restore).
--   2. Move cursor to the center of the trigger monitor.
--   3. Brief sleep so the cursor placement is registered by macOS.
--   4. Send ⌃-rightArrow via hs.eventtap.keyStroke.
--   5. Restore cursor position.
--
-- The keystroke moves the trigger monitor's active Space ONE position
-- to the right (cur_idx -> cur_idx+1). For the test to assert
-- correctly, we need the keystroke's destination to MATCH plan.second_dest_idx
-- — i.e. first_dest_idx + 1.
--
-- The watcher fires for the keystroke-driven Space change. Since
-- syncInProgress=true (chain still in flight from the gotoSpace at
-- arm time), the GATE_RUNNING guard drops it. No second chain starts.
-- At chain end, the verifier sees actual[trigger] = second_dest_sid,
-- expectedEndState[trigger] = first_dest_sid → wrong-space mismatch.

function M.disrupt()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: disrupt called without prior probe"
  end

  -- Sanity: chain should be in flight.
  local status = spoon.SpacesSync:status()
  if not status.syncInProgress then
    return "L6 FAIL: chain not in flight at disrupt time (pollInterval too low? chain ended too fast?)"
  end

  -- Validate that the keystroke's destination matches our plan. The
  -- keystroke sends "next Space" — i.e. cur+1. For our test:
  -- after arm, trigger should be at first_dest_idx. After keystroke,
  -- trigger goes to first_dest_idx+1. plan.second_dest_idx was chosen
  -- as the SECOND viable cand after current; that may NOT equal
  -- first_dest+1 in pathological cases (e.g. cur_idx=2, picks={1,3}).
  -- For this scenario to be deterministic we need second_dest_idx == first_dest_idx+1.
  -- (Probe already picks them in order of "first cand ≠ cur" so this
  -- holds when cur_idx > picks[1], but not otherwise.)
  if plan.second_dest_idx ~= plan.first_dest_idx + 1 then
    return string.format(
      "L6 FAIL: keystroke can only move +1 idx, but plan wants %d -> %d (need +1)",
      plan.first_dest_idx, plan.second_dest_idx)
  end

  -- Capture cursor for restore.
  local saved_mouse = hs.mouse.absolutePosition()

  -- Move cursor to trigger monitor center.
  hs.mouse.absolutePosition({ x = plan.trigger_cx, y = plan.trigger_cy })

  -- Brief sleep so the OS registers the cursor at its new position
  -- BEFORE the keystroke fires.
  hs.timer.usleep(150000)  -- 150 ms

  -- Send ⌃-rightArrow via System Events. Key code 124 = right arrow.
  -- hs.eventtap.keyStroke posts to the frontmost app, NOT to Mission
  -- Control's system-hotkey handler — verified empirically that it
  -- does NOT switch Spaces. AppleScript's System Events works.
  local applescript_ok, applescript_err = hs.osascript.applescript(
    [[tell application "System Events" to key code 124 using {control down}]])

  -- Restore cursor position. Don't wait — the keystroke has already
  -- been queued; cursor restore is cosmetic.
  hs.mouse.absolutePosition(saved_mouse)

  if not applescript_ok then
    return string.format(
      "L6 FAIL: AppleScript ⌃-rightArrow failed: %s", tostring(applescript_err))
  end

  return string.format(
    "L6 DISRUPT OK: ⌃-rightArrow sent via AppleScript with cursor at " ..
    "(%.0f,%.0f) on trigger pos %d; chain in_progress=true at dispatch",
    plan.trigger_cx, plan.trigger_cy, plan.trigger_pos)
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

  -- CRITICAL: capture lastVerifierResult BEFORE restore.
  local status = s:status()
  local lvr = status.lastVerifierResult

  -- Diagnostic captures
  local trigger_screen = hs.screen.find(plan.trigger_uuid)
  local trigger_active_now = trigger_screen and hs.spaces.activeSpaceOnScreen(trigger_screen)

  -- Restore pollInterval + pollTimeout BEFORE dispatching the
  -- restore gotoSpace. The restore chain captures pollInterval at
  -- chain-start time; if we restored AFTER dispatching, the restore
  -- chain would run with the bumped 3 s pollInterval, taking 3-9 s
  -- to settle and causing the next scenario's probe to SKIP for
  -- "chain still in flight". Restoring first means the restore
  -- chain uses fast (default) polling.
  if type(plan.saved_pollInterval) == "number" then
    s.pollInterval = plan.saved_pollInterval
  end
  if type(plan.saved_pollTimeout) == "number" then
    s.pollTimeout = plan.saved_pollTimeout
  end

  -- Restore trigger to its original Space. Best-effort.
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
      "did the arm fire? [trigger_active_now=%s, restore: %s]",
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
      "L6 FAIL: expected trigger wrong-space mismatch, none found. " ..
      "Saw %d mismatch(es): %s; trigger_active_at_assert=%s, " ..
      "expected_after_keystroke=%s [restore: %s]",
      #(lvr.mismatches or {}),
      #kinds > 0 and table.concat(kinds, ", ") or "(none)",
      tostring(trigger_active_now),
      tostring(plan.second_dest_sid),
      tostring(restore_ok))
  end

  if found.expectedIdx ~= plan.first_dest_idx then
    return string.format(
      "L6 FAIL: trigger mismatch expectedIdx=%s, wanted first_dest_idx=%d [restore: %s]",
      tostring(found.expectedIdx), plan.first_dest_idx, tostring(restore_ok))
  end
  if found.actualIdx ~= plan.second_dest_idx then
    return string.format(
      "L6 FAIL: trigger mismatch actualIdx=%s, wanted second_dest_idx=%d " ..
      "(did the keystroke land on the right monitor?) [restore: %s]",
      tostring(found.actualIdx), plan.second_dest_idx, tostring(restore_ok))
  end

  return string.format(
    "L6 PASS: scenario 5 — keystroke-driven re-swipe flagged trigger drift " ..
    "(expectedIdx=%d, actualIdx=%d) [restore: %s]",
    found.expectedIdx, found.actualIdx, tostring(restore_ok))
end

return M
