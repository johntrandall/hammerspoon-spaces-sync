-- L6 — Scenario 16: forced per-target timeout via low pollTimeout
--
-- Automates dev-docs/manual-test-checklist.md Group D scenario 16.
--
-- WHAT THIS PROVES
--   The end-of-chain verifier's per-target wrong-space mismatch path
--   (verifyEndState diffing actual vs expectedEndState) fires when the
--   chain's pollTimeout elapses before Mission Control lands the
--   dispatched target. This is the verifier's "drift detected" code
--   path on the timeout branch of the per-target poll loop.
--
--   With pollTimeout=0.01s and pollInterval=0.005s, the chain bails
--   per-target at ~10 ms. Mission Control needs ~500 ms to actually
--   move a Space, so the target hasn't landed when chainEnd runs and
--   verifyEndState records a wrong-space mismatch for the target
--   (expectedIdx=dest_idx, actualIdx=target_start_idx, since the
--   chain's observed-value write put the baseline at the stuck state).
--
-- WHY THIS IS HARD TO AUTOMATE (field-report 2026-05-10, § "Scenario 16
-- — deferred"):
--   After the first chain times out at T+10 ms, Mission Control
--   eventually lands the target at T+~500 ms. That late landing fires
--   the spaces watcher; since syncInProgress=false (the timed-out chain
--   already ended), the watcher would start a SECOND chain with the
--   target's uuid as the new trigger. The second chain finds everything
--   clean (current == expected) → chainEnd → verifyEndState records a
--   CLEAN lvr, overwriting the wrong-space mismatch from the first chain.
--
--   The viable approach (this scenario): call :stop() during the disrupt
--   phase, after the first chain has timed out but BEFORE the late
--   watcher fire starts a second chain. :stop() sets state.enabled=false,
--   so when the late watcher does fire, its first-line guard returns
--   early without starting a chain. lvr stays frozen at the first-chain
--   wrong-space result.
--
-- ORCHESTRATION SHAPE (5 phases, uses M.disrupt branch in tests/L6/run.sh)
--   1. probe()    — find trigger/target pair, capture target_start_idx
--                   for the post-mortem assertion, declare required_*
--                   timing knobs.
--   2. arm()      — dispatch gotoSpace on the trigger. Watcher fires
--                   shortly after; chain starts; per-target pollTimeout
--                   elapses at ~10 ms; chainEnd runs verifier; lvr
--                   populated with target wrong-space mismatch.
--                   Mission Control still settling target — no landing yet.
--   3. mid-sleep  — MID_SLEEP=1.0 s (dispatcher default). First chain
--                   is COMPLETE within ~50 ms of arm. If the late
--                   target landing happens during this window AND fires
--                   the watcher BEFORE disrupt runs, the second chain
--                   will overwrite lvr — see pitfall below.
--   4. disrupt()  — call spoon.SpacesSync:stop(). Sets state.enabled=false.
--                   ANY watcher fire after this point hits the enabled?
--                   guard and returns without starting a chain.
--   5. sleep      — SLEEP_BETWEEN (scenario-sized to pollTimeout=0.01,
--                   so 8 s minimum). The late target landing (if it
--                   hasn't fired yet) fires during this window; the
--                   watcher returns early; lvr untouched.
--   6. assert_()  — read lvr (still first-chain result with target
--                   wrong-space), verify expectedIdx/actualIdx, then
--                   :start() to restore the Spoon. The L6 dispatcher's
--                   restore_test_config then does its own :stop():start()
--                   when reverting pollTimeout/pollInterval — that's a
--                   double restart, harmless.
--
-- PITFALL — second-chain race:
--   If Mission Control lands the target during MID_SLEEP and the
--   watcher fires for it BEFORE disrupt runs, syncInProgress=false
--   means the watcher starts a second chain. That chain completes
--   in ~10 ms and overwrites lvr with a clean result. The assert
--   then reads a CLEAN lvr and fails with "no wrong-space mismatch
--   found".
--
--   The field report (§ "Scenario 16 — deferred") notes Mission
--   Control's landing window is on the order of 500 ms, so MID_SLEEP
--   needs to be SHORTER than the landing window — which contradicts
--   the dispatcher's MID_SLEEP=1.0 s. If this scenario fails with
--   "verifier showed 0 mismatches", that's the race firing.
--
-- PITFALL — :stop() inside disrupt vs dispatcher's restore_test_config:
--   The L6 dispatcher's apply_test_config calls :stop():start() before
--   probe to apply M.required_*. restore_test_config calls :stop():start()
--   after assert. Our assert() calls :start() (we've already :stop()-ed
--   in disrupt). Sequence is fine: disrupt :stop()s, assert :start()s,
--   dispatcher then :stop():start()s to revert config. Three :start()s
--   per scenario, no double-:stop() crash.

local M = {}

local PLAN_KEY = "_SpacesSyncL6_Scenario16_Plan"

-- Force chain to time out per-target. With pollTimeout=0.01 and
-- pollInterval=0.005, the per-target poll loop runs once, doesn't see
-- the target landed (Mission Control needs ~500 ms), exits via the
-- timeout branch, records observed-value-baseline write, continues to
-- next target. chainEnd runs verifier; verifier sees actual ≠ expected
-- for each target → wrong-space mismatch entry per target.
--
-- The watchdog uses bound = max(8.0, 3*pollTimeout+2.0) = 8 s, so it
-- won't fire during our test. cancelChainTimers at chainEnd drains it.
M.required_pollTimeout  = 0.01
M.required_pollInterval = 0.005

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

  -- Wait briefly for any inter-test residual chain to settle. Borrowed
  -- from scenario-05; protects against prior scenario's restore chain
  -- still being in flight at our probe time.
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

  -- Same trigger/target discovery as scenario-01: both displays need 2+
  -- Spaces, pick first viable destination idx ≠ current.
  local trigger_screen, trigger_pos
  local target_screen,  target_pos
  local trigger_start_idx, dest_idx, target_start_idx
  local trigger_start_sid, dest_sid, target_start_sid

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
                local xcur = hs.spaces.activeSpaceOnScreen(xscr)
                local tcur_idx = index_of(tsps, tcur)
                local xcur_idx = index_of(xsps, xcur)
                if tcur_idx and xcur_idx then
                  local candidate_idx
                  for cand = 1, math.min(#tsps, #xsps) do
                    if cand ~= tcur_idx then
                      candidate_idx = cand
                      break
                    end
                  end
                  -- We also need the target's CURRENT idx to be DIFFERENT
                  -- from dest_idx — otherwise the chain would skip-dispatch
                  -- target (current == expected), no actual gotoSpace would
                  -- fire on target, and the verifier would see a clean
                  -- result. The wrong-space mismatch ONLY arises when the
                  -- chain ACTUALLY dispatches a gotoSpace that times out.
                  if candidate_idx and xcur_idx ~= candidate_idx then
                    trigger_screen    = tscr
                    trigger_pos       = tp
                    target_screen     = xscr
                    target_pos        = xp
                    trigger_start_idx = tcur_idx
                    dest_idx          = candidate_idx
                    target_start_idx  = xcur_idx
                    trigger_start_sid = tcur
                    dest_sid          = tsps[candidate_idx]
                    target_start_sid  = xcur
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
           "with target's current idx ≠ trigger's destination idx)"
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
    target_start_sid   = target_start_sid,
    target_start_idx   = target_start_idx,
    pre_verifier_ts    = (status.lastVerifierResult and status.lastVerifierResult.timestamp) or 0,
  }

  return string.format(
    "L6 PROBE READY: trigger pos %d (idx %d -> %d), target pos %d (idx %d, will mismatch), " ..
    "pollTimeout=%g, pollInterval=%g",
    trigger_pos, trigger_start_idx, dest_idx, target_pos, target_start_idx,
    M.required_pollTimeout, M.required_pollInterval)
end

-- ---------------------------------------------------------------------------
-- Phase: arm — fire the trigger gotoSpace
-- ---------------------------------------------------------------------------

function M.arm()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: arm called without prior probe"
  end
  hs.spaces.gotoSpace(plan.dest_sid)
  return "L6 ARM OK: dispatched gotoSpace(" .. tostring(plan.dest_sid) ..
         "), expecting chain to time out per-target at ~" ..
         tostring(M.required_pollTimeout * 1000) .. " ms"
end

-- ---------------------------------------------------------------------------
-- Phase: disrupt — :stop() to prevent the late-landing second chain
-- ---------------------------------------------------------------------------
--
-- Called after MID_SLEEP=1.0 s. By this time the first chain has long
-- completed (timed out at ~10 ms, chainEnd ran, lvr populated). Mission
-- Control may or may not have landed the target yet (~500 ms window).
--
-- IF the watcher has NOT yet fired for the late landing: :stop() sets
-- state.enabled=false; the eventual watcher fire returns early via the
-- enabled? guard; lvr stays at first-chain result. PASS.
--
-- IF the watcher HAS already fired for the late landing during MID_SLEEP:
-- a second chain already ran (in ~10 ms with our timing) and overwrote
-- lvr with a clean result. :stop() can't undo that. assert sees clean
-- lvr → FAIL with "expected wrong-space mismatch, none found". This is
-- the documented race (field report § "Scenario 16 — deferred").

function M.disrupt()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: disrupt called without prior probe"
  end
  if not spoon or not spoon.SpacesSync then
    return "L6 FAIL: spoon.SpacesSync vanished"
  end
  local s = spoon.SpacesSync

  -- Snapshot lvr BEFORE :stop() — this is the value we'll assert against.
  -- :stop() doesn't touch state.lastVerifierResult, but capturing it
  -- here in the plan removes any doubt and gives the assert phase a
  -- diagnostic anchor if the post-stop lvr changes unexpectedly.
  local pre_stop_status = s:status()
  plan.lvr_at_disrupt = pre_stop_status.lastVerifierResult and {
    timestamp  = pre_stop_status.lastVerifierResult.timestamp,
    mismatches = pre_stop_status.lastVerifierResult.mismatches,
  }
  plan.in_progress_at_disrupt = pre_stop_status.syncInProgress

  -- The disruption itself.
  s:stop()

  -- Confirm :stop() worked.
  local post = s:status()
  plan.post_stop_enabled  = post.enabled
  plan.post_stop_in_progress = post.syncInProgress

  return string.format(
    "L6 DISRUPT OK: pre-stop {inProgress=%s, lvr_ts=%s, lvr_mismatches=%d} " ..
    "post-stop {enabled=%s, inProgress=%s}",
    tostring(plan.in_progress_at_disrupt),
    tostring(plan.lvr_at_disrupt and plan.lvr_at_disrupt.timestamp),
    plan.lvr_at_disrupt and #(plan.lvr_at_disrupt.mismatches or {}) or -1,
    tostring(plan.post_stop_enabled), tostring(plan.post_stop_in_progress))
end

-- ---------------------------------------------------------------------------
-- Phase: assert_ — read frozen lvr, restart Spoon, restore trigger
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

  -- CRITICAL: capture lvr BEFORE :start() — :start() clears
  -- state.lastVerifierResult = nil. We also already captured it in
  -- disrupt; assert reads it again to verify it didn't change during
  -- SLEEP_BETWEEN (which would indicate :stop() failed to suppress
  -- the late-landing second chain).
  local status = s:status()
  local lvr = status.lastVerifierResult

  -- Diagnostic: capture current target idx for the assert-time report
  -- (the target may have FINALLY landed by now, ~SLEEP_BETWEEN seconds
  -- after arm).
  local target_screen = hs.screen.find(plan.target_uuid)
  local target_active_now = target_screen and hs.spaces.activeSpaceOnScreen(target_screen)
  local target_idx_now
  if target_screen and target_active_now then
    local tsps = hs.spaces.spacesForScreen(target_screen) or {}
    target_idx_now = index_of(tsps, target_active_now)
  end

  -- ALWAYS restart the Spoon — we :stop()-ed it in disrupt. Use pcall
  -- so a restart failure doesn't mask the test result. (The L6
  -- dispatcher's restore_test_config does another :stop():start() to
  -- revert pollTimeout/pollInterval; that's fine, idempotent.)
  local restart_ok, restart_err = pcall(function() s:start() end)

  -- Best-effort restore: the trigger landed (or partially landed) at
  -- the destination Space when arm fired. Move it back to its original
  -- Space so the user / next scenario starts clean. Fire-and-forget.
  local restore_ok = false
  if restart_ok and plan.trigger_start_sid then
    restore_ok = pcall(function() hs.spaces.gotoSpace(plan.trigger_start_sid) end)
  end

  _G[PLAN_KEY] = nil

  -- ---- assertions ----

  -- 1. :stop() worked — disrupt observed enabled=false.
  if plan.post_stop_enabled ~= false then
    return string.format(
      "L6 FAIL: post-stop enabled=%s, expected false [restart: %s/%s, restore: %s]",
      tostring(plan.post_stop_enabled),
      tostring(restart_ok), tostring(restart_err), tostring(restore_ok))
  end

  -- 2. lvr exists AND is newer than pre-test (the first chain DID run
  --    and the verifier DID record a result).
  if not lvr then
    return string.format(
      "L6 FAIL: no lastVerifierResult at assert time — did the first chain run? " ..
      "[lvr_at_disrupt_ts=%s, restart: %s/%s, restore: %s]",
      tostring(plan.lvr_at_disrupt and plan.lvr_at_disrupt.timestamp),
      tostring(restart_ok), tostring(restart_err), tostring(restore_ok))
  end
  if lvr.timestamp <= plan.pre_verifier_ts then
    return string.format(
      "L6 FAIL: no NEW verifier result observed (pre_ts=%s, post_ts=%s) — " ..
      "did the watcher fire for the trigger? [restart: %s/%s, restore: %s]",
      tostring(plan.pre_verifier_ts), tostring(lvr.timestamp),
      tostring(restart_ok), tostring(restart_err), tostring(restore_ok))
  end

  -- 3. lvr did NOT change between disrupt and assert. If it did, the
  --    second chain ran despite our :stop() (or fired BEFORE :stop())
  --    and overwrote the first-chain result. This is the documented
  --    race.
  if plan.lvr_at_disrupt and lvr.timestamp ~= plan.lvr_at_disrupt.timestamp then
    return string.format(
      "L6 FAIL: lvr changed between disrupt and assert (disrupt_ts=%s, assert_ts=%s) — " ..
      "the late-landing second chain ran despite :stop(); timing race? " ..
      "[target_idx_now=%s, restart: %s/%s, restore: %s]",
      tostring(plan.lvr_at_disrupt.timestamp), tostring(lvr.timestamp),
      tostring(target_idx_now), tostring(restart_ok), tostring(restart_err),
      tostring(restore_ok))
  end

  -- 4. Hard contract: target has a wrong-space mismatch.
  local found
  for _, m in ipairs(lvr.mismatches or {}) do
    if m.uuid == plan.target_uuid and m.kind == "wrong-space" then
      found = m
      break
    end
  end

  if not found then
    -- Dump observed mismatches for diagnosis.
    local kinds = {}
    for _, m in ipairs(lvr.mismatches or {}) do
      table.insert(kinds, (m.uuid or "?") .. "/" .. (m.kind or "?") ..
        (m.expectedIdx and ("(e=" .. tostring(m.expectedIdx) ..
                            ",a=" .. tostring(m.actualIdx) .. ")") or ""))
    end
    return string.format(
      "L6 FAIL: expected target wrong-space mismatch, none found. " ..
      "lvr has %d mismatch(es): %s; target_idx_now=%s, " ..
      "expected dest_idx=%d, target_start_idx=%d [restart: %s/%s, restore: %s]",
      #(lvr.mismatches or {}),
      #kinds > 0 and table.concat(kinds, ", ") or "(none)",
      tostring(target_idx_now), plan.dest_idx, plan.target_start_idx,
      tostring(restart_ok), tostring(restart_err), tostring(restore_ok))
  end

  -- 5. expectedIdx == dest_idx (where chain dispatched target).
  if found.expectedIdx ~= plan.dest_idx then
    return string.format(
      "L6 FAIL: target mismatch expectedIdx=%s, wanted dest_idx=%d " ..
      "[restart: %s/%s, restore: %s]",
      tostring(found.expectedIdx), plan.dest_idx,
      tostring(restart_ok), tostring(restart_err), tostring(restore_ok))
  end

  -- 6. actualIdx ≠ dest_idx (target did NOT land within pollTimeout).
  --    Specifically, on the timeout branch the chain wrote
  --    state.lastActiveSpaces[targetUUID] = active or current — which
  --    at chain-end time is still target_start_sid (Mission Control
  --    hadn't landed yet). verifyEndState's actual is taken via
  --    hs.spaces.activeSpaces() at chainEnd time, which should also
  --    be target_start_sid. So actualIdx should equal target_start_idx.
  if found.actualIdx == plan.dest_idx then
    return string.format(
      "L6 FAIL: target mismatch actualIdx=%s == dest_idx=%d — " ..
      "this contradicts the wrong-space kind (chain saw target landed); " ..
      "verifier kind/idx invariant broken [restart: %s/%s, restore: %s]",
      tostring(found.actualIdx), plan.dest_idx,
      tostring(restart_ok), tostring(restart_err), tostring(restore_ok))
  end
  -- The actual should specifically be target_start_idx (target hadn't
  -- moved when chainEnd ran). Tolerate a soft mismatch — if Mission
  -- Control was mid-move when chainEnd ran, actualIdx could be some
  -- transient value. The HARD assertion is actualIdx ≠ dest_idx (above).
  local soft_warn = ""
  if found.actualIdx ~= plan.target_start_idx then
    -- Soft warn — don't fail. Could happen if Mission Control was mid-
    -- transition when verifyEndState ran (unlikely at 10 ms, but possible).
    soft_warn = string.format(
      " [WARN: actualIdx=%s, expected target_start_idx=%d — Mission Control " ..
      "mid-transition at verify time?]",
      tostring(found.actualIdx), plan.target_start_idx)
  end

  if not restart_ok then
    return string.format(
      "L6 FAIL: assertions passed but :start() restart failed: %s",
      tostring(restart_err))
  end

  return string.format(
    "L6 PASS: scenario 16 — forced timeout produced target wrong-space " ..
    "(expectedIdx=%d, actualIdx=%s) [target_start_idx=%d, dest_idx=%d, " ..
    "lvr_frozen_by_stop=true, restart: ok, restore: %s]%s",
    found.expectedIdx, tostring(found.actualIdx),
    plan.target_start_idx, plan.dest_idx, tostring(restore_ok), soft_warn)
end

return M
