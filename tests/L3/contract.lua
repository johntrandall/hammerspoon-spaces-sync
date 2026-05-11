-- L3 — Public API contract test
--
-- Per dev-docs/test-strategy.md § Active Levels L3 + § L3 Contract Spec.
--
-- Asserts:
--   * Public methods exist with type "function":
--     :start, :stop, :status, :isEnabled, :toggle, :bindHotkeys,
--     :showNames, :renameCurrentSpace
--   * obj.version is a string
--   * obj.syncGroups is a table
--   * obj.pollTimeout / obj.pollInterval are numbers
--   * obj.switchDelay / obj.debounceSeconds are present (deprecated
--     but kept; a v3 release that removes them is intentional and
--     gets flagged by this test failing)
--   * :status() returns the spec'd 12-key shape with correct types
--   * lastVerifierResult, when present, has the documented inner
--     shape — including the conditional expectedIdx/actualIdx fields
--     that ONLY exist on kind == "wrong-space" entries
--
-- ASSUMES the Spoon is already :start()-ed. SKIPs with an actionable
-- message if not (the test does NOT call :start() itself; see strategy
-- doc Active Levels L3 row).
--
-- Does NOT verify chaining (return self) — would require calling
-- stateful methods on the live Spoon, which is L6 territory.
--
-- Single-display hosts produce degenerate values (e.g.
-- positionMap = {[1] = uuid}); shape/type checks still pass.
--
-- The function `M.run()` returns "L3 PASS" or "L3 FAIL: ..." or
-- "L3 SKIP: ...". The L3 runner (tests/L3/run.sh) invokes it via
-- `hs -c` and propagates exit code.

local M = {}

-- The 15 keys we expect from :status(), with the type or types each
-- can be. lastVerifierResult is "table or nil" per the strategy doc.
-- configPath is "string or nil" — nil before :init has run, set
-- otherwise.
local STATUS_SHAPE = {
  enabled              = { "boolean" },
  osBlocked            = { "boolean" },
  syncInProgress       = { "boolean" },
  chainGeneration      = { "number" },
  activeChainTimers    = { "number" },
  totalScreens         = { "number" },
  positionMap          = { "table" },
  syncGroups           = { "table" },
  lastActiveSpaces     = { "table" },
  lastVerifierResult   = { "table", "nil" },
  pollTimeout          = { "number" },
  pollInterval         = { "number" },
  -- Settings-layer additions (v0.4):
  syncMode             = { "string" },
  pendingConfigStashed = { "boolean" },
  configPath           = { "string", "nil" },
}

local PUBLIC_METHODS = {
  "start", "stop", "status", "isEnabled", "toggle",
  "bindHotkeys", "showNames", "renameCurrentSpace",
  -- v0.4 additions:
  "syncNow", "openSettings",
}

local function in_list(t, v)
  for _, x in ipairs(t) do
    if x == v then return true end
  end
  return false
end

local function assert_type(label, value, allowed_types)
  local got = type(value)
  if not in_list(allowed_types, got) then
    return string.format("%s: expected type %s, got %s",
                         label, table.concat(allowed_types, " or "), got)
  end
end

function M.run()
  -- Hammerspoon must have loaded the Spoon.
  if not spoon or not spoon.SpacesSync then
    return "L3 SKIP: spoon.SpacesSync not loaded; ensure init.lua does hs.loadSpoon('SpacesSync')"
  end
  local s = spoon.SpacesSync

  -- Spoon must be :start()-ed. Test does NOT call :start() itself.
  if not s.isEnabled or not s:isEnabled() then
    return "L3 SKIP: spoon.SpacesSync not :start()-ed; run spoon.SpacesSync:start() before invoking L3"
  end

  -- Metadata.
  if type(s.version) ~= "string" then
    return "L3 FAIL: obj.version is not a string (got " .. type(s.version) .. ")"
  end

  if type(s.syncGroups) ~= "table" then
    return "L3 FAIL: obj.syncGroups is not a table (got " .. type(s.syncGroups) .. ")"
  end

  if type(s.pollTimeout) ~= "number" then
    return "L3 FAIL: obj.pollTimeout is not a number (got " .. type(s.pollTimeout) .. ")"
  end
  if type(s.pollInterval) ~= "number" then
    return "L3 FAIL: obj.pollInterval is not a number (got " .. type(s.pollInterval) .. ")"
  end

  -- Deprecated but expected to remain.
  if s.switchDelay == nil then
    return "L3 FAIL: obj.switchDelay missing (deprecated knob removal is intentional? bump test)"
  end
  if s.debounceSeconds == nil then
    return "L3 FAIL: obj.debounceSeconds missing (deprecated knob removal is intentional? bump test)"
  end

  -- Public methods present with type function.
  for _, name in ipairs(PUBLIC_METHODS) do
    if type(s[name]) ~= "function" then
      return string.format("L3 FAIL: method :%s missing or not a function (got %s)",
                           name, type(s[name]))
    end
  end

  -- :status() shape.
  local ok, status = pcall(function() return s:status() end)
  if not ok then
    return "L3 FAIL: :status() raised: " .. tostring(status)
  end
  if type(status) ~= "table" then
    return "L3 FAIL: :status() did not return a table (got " .. type(status) .. ")"
  end

  -- Every required key present with correct type.
  for key, allowed in pairs(STATUS_SHAPE) do
    local err = assert_type(":status()." .. key, status[key], allowed)
    if err then return "L3 FAIL: " .. err end
  end

  -- Conditional shape: lastVerifierResult.mismatches[i].
  local lvr = status.lastVerifierResult
  if lvr ~= nil then
    if type(lvr.timestamp) ~= "number" then
      return "L3 FAIL: lastVerifierResult.timestamp not a number (got " ..
             type(lvr.timestamp) .. ")"
    end
    if type(lvr.mismatches) ~= "table" then
      return "L3 FAIL: lastVerifierResult.mismatches not a table (got " ..
             type(lvr.mismatches) .. ")"
    end
    for i, m in ipairs(lvr.mismatches) do
      local pfx = string.format("lastVerifierResult.mismatches[%d]", i)
      if type(m.uuid) ~= "string" then
        return "L3 FAIL: " .. pfx .. ".uuid not a string"
      end
      if type(m.kind) ~= "string" then
        return "L3 FAIL: " .. pfx .. ".kind not a string"
      end
      -- Per strategy doc: expectedIdx/actualIdx ONLY for "wrong-space".
      if m.kind == "wrong-space" then
        if m.expectedIdx == nil then
          return "L3 FAIL: " .. pfx .. " (kind=wrong-space) missing expectedIdx"
        end
        if m.actualIdx == nil then
          return "L3 FAIL: " .. pfx .. " (kind=wrong-space) missing actualIdx"
        end
      elseif m.kind == "vanished" or m.kind == "appeared" then
        -- expectedIdx/actualIdx absent for these kinds is correct.
        -- We do NOT assert they're nil — implementation might add
        -- diagnostic fields later; just don't require them.
      else
        return string.format(
          "L3 FAIL: %s.kind = %q is not one of {wrong-space, vanished, appeared}",
          pfx, m.kind)
      end
    end
  end

  -- positionMap should map position numbers (1..N) to UUID strings.
  for k, v in pairs(status.positionMap) do
    if type(k) ~= "number" then
      return "L3 FAIL: positionMap key not a number: " .. tostring(k)
    end
    if type(v) ~= "string" then
      return "L3 FAIL: positionMap[" .. k .. "] value not a string: " .. tostring(v)
    end
  end

  -- lastActiveSpaces should map UUID strings to space ID numbers.
  for k, v in pairs(status.lastActiveSpaces) do
    if type(k) ~= "string" then
      return "L3 FAIL: lastActiveSpaces key not a string: " .. tostring(k)
    end
    if type(v) ~= "number" then
      return "L3 FAIL: lastActiveSpaces[" .. tostring(k) .. "] value not a number: " .. tostring(v)
    end
  end

  -- pollTimeout/pollInterval positive.
  if status.pollTimeout <= 0 then
    return "L3 FAIL: pollTimeout must be > 0 (got " .. status.pollTimeout .. ")"
  end
  if status.pollInterval <= 0 then
    return "L3 FAIL: pollInterval must be > 0 (got " .. status.pollInterval .. ")"
  end

  -- chainGeneration / activeChainTimers / totalScreens non-negative.
  if status.chainGeneration < 0 then
    return "L3 FAIL: chainGeneration < 0"
  end
  if status.activeChainTimers < 0 then
    return "L3 FAIL: activeChainTimers < 0"
  end
  if status.totalScreens < 1 then
    return "L3 FAIL: totalScreens < 1 (must have ≥ 1 display)"
  end

  -- syncMode is one of the two valid values.
  if status.syncMode ~= "automatic" and status.syncMode ~= "manual" then
    return "L3 FAIL: syncMode = " .. tostring(status.syncMode) ..
           " is not 'automatic' or 'manual'"
  end

  return string.format(
    "L3 PASS: contract OK (version=%s, screens=%d, pollTimeout=%g, lastVerifier=%s)",
    s.version, status.totalScreens, status.pollTimeout,
    lvr and "set" or "nil")
end

return M
