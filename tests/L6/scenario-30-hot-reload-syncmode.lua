-- L6 — Scenario 30: hot-reload via JSON edit
--
-- Verifies the convergent-apply flow from
-- dev-docs/diagrams/config-change-flow.mermaid §Path B (Hand-edit).
--
-- Writes a modified SpacesSync.json directly via io.open (bypassing
-- config.save so the SHA ring doesn't classify it as an echo), waits
-- for hs.pathwatcher to fire, then asserts the live spoon's :status()
-- reflects the change. Restores the original file before exit.
--
-- This is the only L6 scenario that does NOT dispatch hs.spaces.gotoSpace
-- — there's no Mission Control disruption. But it still requires the
-- live Spoon, hs.pathwatcher, and FSEvents settling, so L6 is the right
-- tier.
--
-- The mutation we make is flipping syncMode (automatic ↔ manual), which
-- is benign — it only gates whether the watcher is armed, doesn't move
-- any Spaces.

local M = {}

local PLAN_KEY = "_SpacesSyncL6_Scenario30_Plan"

local function readAll(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local s = f:read("*all")
  f:close()
  return s
end

local function writeAll(path, bytes)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(bytes)
  f:close()
  return true
end

function M.probe()
  if not spoon or not spoon.SpacesSync then
    return "L6 SKIP: spoon.SpacesSync not loaded"
  end
  local s = spoon.SpacesSync
  if not s:isEnabled() then
    return "L6 SKIP: spoon.SpacesSync not :start()-ed"
  end

  local status = s:status()
  local path = status.configPath
  if not path then
    return "L6 SKIP: settings layer not initialized (configPath is nil)"
  end

  local original, err = readAll(path)
  if not original then
    return "L6 SKIP: cannot read " .. path .. ": " .. tostring(err)
  end

  local ok, parsed = pcall(hs.json.decode, original)
  if not ok or type(parsed) ~= "table" then
    return "L6 SKIP: " .. path .. " is not valid JSON; refusing to mutate"
  end

  local originalMode = parsed.syncMode or "automatic"
  local newMode = (originalMode == "automatic") and "manual" or "automatic"

  -- Build the modified payload and pre-encode (we'll write in arm).
  parsed.syncMode = newMode
  local newBytes = hs.json.encode(parsed, true)

  _G[PLAN_KEY] = {
    path = path,
    originalBytes = original,
    originalMode = originalMode,
    newBytes = newBytes,
    newMode = newMode,
  }

  return string.format(
    "L6 PROBE READY: will flip syncMode %s -> %s via direct write to %s",
    originalMode, newMode, path)
end

function M.arm()
  local plan = _G[PLAN_KEY]
  if not plan then return "L6 FAIL: arm called without probe" end

  local ok, err = writeAll(plan.path, plan.newBytes)
  if not ok then
    return "L6 FAIL: write failed: " .. tostring(err)
  end
  return "L6 ARM OK: wrote new syncMode=" .. plan.newMode
end

function M.assert_()
  local plan = _G[PLAN_KEY]
  if not plan then return "L6 FAIL: assert called without probe" end

  -- Read current status — did the pathwatcher pick up the change and
  -- did applyConfig propagate the new syncMode?
  local status = spoon.SpacesSync:status()
  local observedMode = status.syncMode

  -- Restore the original bytes BEFORE returning so the user's pre-test
  -- JSON survives. Then re-apply the original syncMode in-memory via a
  -- :stop():start() cycle — needed because the restored bytes may be in
  -- the config-module SHA ring (if migration ran on the most recent
  -- :start), in which case the pathwatcher would treat the restore as
  -- a self-write echo and skip applyConfig.
  local restored, err = writeAll(plan.path, plan.originalBytes)
  spoon.SpacesSync:stop()
  spoon.SpacesSync:start()
  _G[PLAN_KEY] = nil

  if observedMode ~= plan.newMode then
    return string.format(
      "L6 FAIL: pathwatcher did not propagate change " ..
      "(expected syncMode=%s, observed syncMode=%s) [restored: %s]",
      plan.newMode, tostring(observedMode), tostring(restored))
  end

  return string.format(
    "L6 PASS: scenario 30 — pathwatcher delivered syncMode %s " ..
    "[file restored: %s, err: %s]",
    plan.newMode, tostring(restored), tostring(err))
end

return M
