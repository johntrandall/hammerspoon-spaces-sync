-- L6 — Scenario 24: Misconfigured syncGroups (out-of-range positions)
--
-- Automates dev-docs/manual-test-checklist.md Group E scenario 24.
--
-- WHAT THIS PROVES
--   * When `obj.syncGroups` references a position that is NOT currently
--     connected (e.g. position 5 on a 4-display rig), :start() logs a
--     warning of the form "position N (not connected)" via the
--     positionMap/connected-position summary block in init.lua's
--     :start() validation.
--   * The Spoon continues running (no crash); chains dispatched in a
--     misconfigured group would simply have no targets because
--     getTargetsFor() filters by positionToUUID — but this scenario
--     does NOT dispatch a chain. It is purely a config-validation
--     observation test.
--
-- WHY THIS MATTERS
--   Users routinely tweak syncGroups (e.g. unplugging a monitor, or
--   editing init.lua before all monitors are connected). The Spoon
--   must visibly warn about out-of-range positions rather than
--   silently dropping them, so users can self-diagnose "why isn't
--   sync working?" by inspecting the Hammerspoon console.
--
-- ORCHESTRATION SHAPE
--   This scenario uses `M.required_syncGroups = {{1, 5}}` declaratively;
--   the L6 dispatcher (tests/L6/run.sh) snapshots the live syncGroups,
--   applies the test config, and calls :stop():start() BEFORE probe
--   runs. That :start() is what emits the warning we're looking for.
--
--   * probe() — sanity-check display count + record screen_count.
--   * arm()   — no-op. Validation already exercised by dispatcher.
--   * assert_() — read hs.console.getConsole() and search for
--                  "position 5 (not connected)" substring. PASS or FAIL.
--
-- WHY THE CONSOLE READ HAPPENS IN assert_(), NOT probe()
--   `hs.logger.i(...)` writes through hs.console asynchronously — the
--   string is queued at log time but the console buffer only reflects
--   it after the runloop pumps. Between apply_test_config's
--   `s:stop(); s:start()` and the next `hs -c` invocation (probe),
--   there's only ~one runloop tick: insufficient for the message to
--   surface in hs.console.getConsole(). By assert_(), the dispatcher
--   has slept SLEEP_BETWEEN (8s+) since arm, which is more than
--   enough time for the logger queue to drain.
--
-- NOTE: arm() is still required by the dispatcher's phase machine;
-- the dispatcher always invokes probe -> arm -> sleep -> assert_.
-- A no-op arm just returns "L6 ARM OK".

local M = {}

local PLAN_KEY = "_SpacesSyncL6_Scenario24_Plan"

-- Declarative config: dispatcher will snapshot obj.syncGroups,
-- set it to this value, and call :stop():start() before probe.
-- Position 5 is intentionally out of range on John's 4-display rig
-- (and almost any plausible rig) to provoke the validation warning.
M.required_syncGroups = { { 1, 5 } }

-- ---------------------------------------------------------------------------
-- Phase: probe
-- ---------------------------------------------------------------------------

function M.probe()
  if not spoon or not spoon.SpacesSync then
    return "L6 SKIP: spoon.SpacesSync not loaded"
  end
  local s = spoon.SpacesSync
  if not s:isEnabled() then
    return "L6 SKIP: spoon.SpacesSync not :start()-ed (apply_test_config should have started it)"
  end

  -- Sanity check: this test only makes sense if position 5 is genuinely
  -- not connected. On a hypothetical 5+ display rig the validation
  -- wouldn't fire and the test would be meaningless — SKIP.
  local screen_count = #(hs.screen.allScreens() or {})
  if screen_count >= 5 then
    return string.format(
      "L6 SKIP: %d displays connected — position 5 is in range, "
      .. "test only meaningful on rigs with <5 displays",
      screen_count)
  end

  -- Verify the test config actually applied. If apply_test_config
  -- didn't run or didn't take, abort — assert_'s console check would
  -- be looking for a warning the user's live config could never emit.
  local sg = s.syncGroups
  local has_pos5 = false
  if type(sg) == "table" then
    for _, group in ipairs(sg) do
      if type(group) == "table" then
        for _, pos in ipairs(group) do
          if pos == 5 then has_pos5 = true end
        end
      end
    end
  end
  if not has_pos5 then
    return string.format(
      "L6 FAIL: syncGroups did not include position 5 at probe time " ..
      "(apply_test_config bug?); current syncGroups=%s",
      tostring(hs.inspect and hs.inspect(sg) or sg))
  end

  _G[PLAN_KEY] = { screen_count = screen_count }

  return string.format(
    "L6 PROBE READY: %d displays, syncGroups contains position 5 (out of range)",
    screen_count)
end

-- ---------------------------------------------------------------------------
-- Phase: arm — no-op (validation already exercised by apply_test_config)
-- ---------------------------------------------------------------------------

function M.arm()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: arm called without prior probe"
  end
  return "L6 ARM OK: no-op (validation log already emitted by apply_test_config; assert_ reads console)"
end

-- ---------------------------------------------------------------------------
-- Phase: assert_ — read console tail (logger has had >=SLEEP_BETWEEN to flush)
-- ---------------------------------------------------------------------------

function M.assert_()
  local plan = _G[PLAN_KEY]
  if not plan then
    return "L6 FAIL: assert called without prior probe"
  end
  local screen_count = plan.screen_count
  _G[PLAN_KEY] = nil

  -- Read the Hammerspoon console. By the time this phase runs the
  -- dispatcher has slept SLEEP_BETWEEN (>= 8s) since apply_test_config's
  -- :start(). That's far longer than hs.logger's async flush latency.
  local console = hs.console.getConsole()
  local console_str
  if type(console) == "string" then
    console_str = console
  elseif type(console) == "userdata" and console.getString then
    console_str = console:getString()
  else
    console_str = tostring(console or "")
  end

  -- The validation log line format from init.lua:1689,1692 is e.g.:
  --   "Group 1: position 1 (LG SDQHD (1) [position 1/4]), position 5 (not connected)"
  -- Forgiving pattern: tolerate minor whitespace variation.
  local warning_match = console_str:match("position%s+5%s*%(not%s+connected%)")
  if not warning_match then
    -- Diagnostic: tail of console for context. Cap length so the
    -- failure line stays manageable in run.sh output.
    local tail = console_str
    if #tail > 800 then
      tail = "..." .. tail:sub(-800)
    end
    tail = tail:gsub("\n", " \\n ")
    return string.format(
      "L6 FAIL: scenario 24 — expected 'position 5 (not connected)' " ..
      "validation warning in console, not found after SLEEP_BETWEEN. " ..
      "Console tail: %s",
      tail)
  end

  return string.format(
    "L6 PASS: scenario 24 — misconfigured syncGroups {{1,5}} on %d-display "
    .. "rig produced the expected 'position 5 (not connected)' validation warning",
    screen_count)
end

return M
