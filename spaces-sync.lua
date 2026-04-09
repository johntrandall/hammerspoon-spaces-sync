-- spaces-sync: Synchronized macOS Spaces across monitors
--
-- When enabled, switching Spaces on one monitor in a sync group
-- automatically switches all other monitors in that group to the
-- matching Space index.
--
-- Monitors are identified by position number (reading order:
-- left-to-right, top-to-bottom). Define sync groups as sets of
-- position numbers.
--
-- Usage:
--   local spacesSync = require("spaces-sync")
--   spacesSync.init({
--     syncGroups = { {1, 2} },   -- monitors 1 and 2 sync together
--   })
--
-- See README.md for full configuration options.

local M = {}

-- Preload extensions to avoid lazy-load latency during sync
require("hs.screen")
require("hs.spaces")
require("hs.application")
require("hs.timer")

-- ============================================================================
-- VERSION REQUIREMENTS
-- ============================================================================

local TESTED_OS = "15.5"
local MIN_OS_MAJOR = 15
local TESTED_HS = "1.1.1"

local function getOSVersion()
  local raw = hs.host.operatingSystemVersion()
  return {
    major = raw.major,
    minor = raw.minor,
    patch = raw.patch,
    str = raw.major .. "." .. raw.minor .. "." .. raw.patch,
  }
end

local function getHSVersion()
  return hs.processInfo.version or "unknown"
end

-- Compare "1.1.1" style version strings. Returns -1, 0, or 1.
local function compareVersions(a, b)
  local function parts(v)
    local t = {}
    for n in tostring(v):gmatch("(%d+)") do t[#t+1] = tonumber(n) end
    return t
  end
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb) do
    local va, vb = pa[i] or 0, pb[i] or 0
    if va < vb then return -1 end
    if va > vb then return 1 end
  end
  return 0
end

-- ============================================================================
-- DEFAULTS (overridden by .spaces-sync-config.lua or init() argument)
-- ============================================================================

local DEFAULTS = {
  -- Sync groups: each is a list of monitor position numbers.
  -- Positions assigned in reading order (left-to-right, top-to-bottom).
  -- Monitors not in any group are independent.
  --
  -- Examples:
  --   { {1, 2} }               -- two monitors sync together
  --   { {1, 2}, {3, 4} }       -- two independent pairs
  --   { {1, 2, 3} }            -- three monitors sync together
  syncGroups = {
    { 1, 2 },
  },

  -- Hotkey to toggle sync on/off. Set to false to disable.
  -- Format: { modifiers, key }
  hotkey = { {"ctrl", "alt", "cmd"}, "Y" },

  -- Delay between each gotoSpace call (seconds).
  -- macOS drops rapid back-to-back space switches.
  switchDelay = 0.3,

  -- Debounce after all switches complete (seconds).
  -- Prevents watcher from reacting to our own gotoSpace calls.
  debounceSeconds = 0.8,

  -- Verbose debug logging (watcher state dumps, per-call details).
  -- Normal mode still logs syncs, warnings, and errors.
  debug = false,
}

-- ============================================================================
-- INTERNALS
-- ============================================================================

local config = {}
local state = {
  enabled = false,
  lastActiveSpaces = {},
  syncInProgress = false,
  spaceWatcher = nil,
  debounceTimer = nil,
  hotkey = nil,
  osBlocked = false,
}

local positionToUUID = {}
local uuidToPosition = {}
local totalScreens = 0

local function mergeConfig(userConfig)
  config = {}
  for k, v in pairs(DEFAULTS) do
    config[k] = v
  end
  if userConfig then
    for k, v in pairs(userConfig) do
      config[k] = v
    end
  end
end

-- ============================================================================
-- LOGGING
-- ============================================================================

-- Always printed (syncs, warnings, errors, lifecycle)
local function info(msg)
  print("[SpacesSync] " .. msg)
end

-- Only printed when debug = true (watcher dumps, per-call details)
local function dbg(msg)
  if config.debug then
    print("[SpacesSync] " .. msg)
  end
end

-- ============================================================================
-- POSITION MAP
-- ============================================================================

local function rebuildPositionMap()
  local screens = hs.screen.allScreens()
  local sorted = {}
  for _, s in ipairs(screens) do
    local f = s:frame()
    table.insert(sorted, { uuid = s:getUUID(), x = f.x, y = f.y })
  end
  table.sort(sorted, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)

  positionToUUID = {}
  uuidToPosition = {}
  totalScreens = #sorted
  for i, entry in ipairs(sorted) do
    positionToUUID[i] = entry.uuid
    uuidToPosition[entry.uuid] = i
  end
end

local function getDisplayLabel(uuid)
  local screen = hs.screen.find(uuid)
  local name = screen and screen:name() or uuid:sub(1, 8)
  local pos = uuidToPosition[uuid]
  if pos then
    return name .. " [pos " .. pos .. "/" .. totalScreens .. "]"
  end
  return name
end

-- ============================================================================
-- SYNC GROUP LOOKUP
-- ============================================================================

-- Given a triggering monitor's UUID, return the UUIDs of its targets in the same sync group.
local function getTargetsFor(triggerUUID)
  local pos = uuidToPosition[triggerUUID]
  if not pos then return nil end

  for _, group in ipairs(config.syncGroups) do
    local inGroup = false
    for _, gpos in ipairs(group) do
      if gpos == pos then inGroup = true; break end
    end
    if inGroup then
      local targets = {}
      for _, gpos in ipairs(group) do
        if gpos ~= pos then
          local targetUUID = positionToUUID[gpos]
          if targetUUID then
            table.insert(targets, targetUUID)
          else
            info("WARNING: group references pos " .. gpos .. " but only " .. totalScreens .. " screens connected")
          end
        end
      end
      return targets
    end
  end
  return nil
end

-- ============================================================================
-- SPACE HELPERS
-- ============================================================================

local function getSpaceIndex(uuid, spaceID)
  local screen = hs.screen.find(uuid)
  if not screen then return nil end
  local spaces = hs.spaces.spacesForScreen(screen)
  if not spaces then return nil end
  for i, sid in ipairs(spaces) do
    if sid == spaceID then return i end
  end
  return nil
end

local function getSpaceAtIndex(uuid, index)
  local screen = hs.screen.find(uuid)
  if not screen then return nil end
  local spaces = hs.spaces.spacesForScreen(screen)
  if not spaces then return nil end
  return spaces[index]
end

local function getSpaceCount(uuid)
  local screen = hs.screen.find(uuid)
  if not screen then return 0 end
  local spaces = hs.spaces.spacesForScreen(screen)
  return spaces and #spaces or 0
end

-- ============================================================================
-- SYNC ENGINE
-- ============================================================================

-- Switch a target monitor to match the triggering monitor's space index.
local function syncTarget(triggerUUID, triggerSpaceID, targetUUID)
  local label = getDisplayLabel(targetUUID)
  local targetCount = getSpaceCount(targetUUID)

  local triggerIndex = getSpaceIndex(triggerUUID, triggerSpaceID)
  if not triggerIndex then
    dbg("  " .. label .. ": SKIP (triggering monitor's space index not found)")
    return
  end

  if triggerIndex > targetCount then
    info("  " .. label .. " (" .. targetCount .. " spaces): SKIP (no space at index " .. triggerIndex .. ")")
    return
  end

  local targetSpaceID = getSpaceAtIndex(targetUUID, triggerIndex)
  if not targetSpaceID then
    dbg("  " .. label .. ": SKIP (getSpaceAtIndex returned nil)")
    return
  end

  local targetScreen = hs.screen.find(targetUUID)
  if not targetScreen then
    dbg("  " .. label .. ": SKIP (screen not found)")
    return
  end

  local currentSpace = hs.spaces.activeSpaceOnScreen(targetScreen)
  local currentIdx = getSpaceIndex(targetUUID, currentSpace) or "?"
  if currentSpace == targetSpaceID then
    dbg("  " .. label .. ": already at index " .. triggerIndex)
    return
  end

  info("  " .. label .. ": index " .. tostring(currentIdx) .. " -> " .. triggerIndex)

  local ok, err = pcall(function()
    hs.spaces.gotoSpace(targetSpaceID)
  end)

  if ok then
    dbg("  " .. label .. ": dispatched")
  else
    info("  " .. label .. ": ERROR — " .. tostring(err))
  end
end

-- ============================================================================
-- WATCHER
-- ============================================================================

local function setupWatcher()
  if state.spaceWatcher then
    state.spaceWatcher:stop()
  end

  state.lastActiveSpaces = hs.spaces.activeSpaces() or {}

  state.spaceWatcher = hs.spaces.watcher.new(function()
    if not state.enabled then return end
    if state.syncInProgress then
      dbg("WATCHER: ignored (sync in progress)")
      return
    end

    local currentSpaces = hs.spaces.activeSpaces() or {}

    if config.debug then
      local parts = {}
      for uuid, spaceID in pairs(currentSpaces) do
        local idx = getSpaceIndex(uuid, spaceID) or "?"
        table.insert(parts, getDisplayLabel(uuid) .. "=idx" .. tostring(idx))
      end
      dbg("WATCHER: " .. table.concat(parts, ", "))
    end

    -- Find which display changed
    local changedUUID, changedSpaceID, newIndex

    for uuid, spaceID in pairs(currentSpaces) do
      local lastSpaceID = state.lastActiveSpaces[uuid]
      if lastSpaceID and lastSpaceID ~= spaceID then
        local oi = getSpaceIndex(uuid, lastSpaceID) or "?"
        local ni = getSpaceIndex(uuid, spaceID) or "?"
        dbg("CHANGED: " .. getDisplayLabel(uuid) .. " index " .. tostring(oi) .. " -> " .. tostring(ni))

        if not changedUUID then
          changedUUID = uuid
          changedSpaceID = spaceID
          newIndex = ni
        else
          dbg("  (multiple changed; syncing first only)")
        end
      end
    end

    if not changedUUID then
      state.lastActiveSpaces = currentSpaces
      return
    end

    -- Find targets for the triggering monitor
    local targets = getTargetsFor(changedUUID)
    if not targets or #targets == 0 then
      dbg("SKIP: " .. getDisplayLabel(changedUUID) .. " not in any sync group")
      state.lastActiveSpaces = currentSpaces
      return
    end

    local targetNames = {}
    for _, uuid in ipairs(targets) do
      table.insert(targetNames, getDisplayLabel(uuid))
    end
    info("SYNC: " .. getDisplayLabel(changedUUID) .. " (trigger) -> index " .. tostring(newIndex) .. " | targets: " .. table.concat(targetNames, ", "))

    state.syncInProgress = true

    local function syncNext(i)
      if i > #targets then
        state.lastActiveSpaces = hs.spaces.activeSpaces() or {}

        if config.debug then
          local parts = {}
          for uuid, spaceID in pairs(state.lastActiveSpaces) do
            local idx = getSpaceIndex(uuid, spaceID) or "?"
            table.insert(parts, getDisplayLabel(uuid) .. "=idx" .. tostring(idx))
          end
          dbg("DONE: " .. table.concat(parts, ", "))
        end

        if state.debounceTimer then state.debounceTimer:stop() end
        state.debounceTimer = hs.timer.doAfter(config.debounceSeconds, function()
          state.syncInProgress = false
          state.lastActiveSpaces = hs.spaces.activeSpaces() or {}
          dbg("Watcher re-enabled")
        end)
        return
      end

      syncTarget(changedUUID, changedSpaceID, targets[i])
      hs.timer.doAfter(config.switchDelay, function()
        syncNext(i + 1)
      end)
    end

    syncNext(1)
  end)

  state.spaceWatcher:start()
  dbg("Watcher started")
end

local function stopWatcher()
  if state.spaceWatcher then
    state.spaceWatcher:stop()
    state.spaceWatcher = nil
    dbg("Watcher stopped")
  end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- Enable space syncing.
function M.enable()
  if state.osBlocked then
    info("ERROR: macOS " .. MIN_OS_MAJOR .. "+ required. Space sync will not activate.")
    hs.alert.show("Space Sync: blocked (macOS " .. MIN_OS_MAJOR .. "+ required)")
    return
  end

  state.enabled = true
  state.syncInProgress = false
  state.lastActiveSpaces = hs.spaces.activeSpaces() or {}
  setupWatcher()
  hs.alert.show("Space Sync: ON")
  info("Enabled")
end

--- Disable space syncing.
function M.disable()
  state.enabled = false
  stopWatcher()
  hs.alert.show("Space Sync: OFF")
  info("Disabled")
end

--- Toggle space syncing on/off.
function M.toggle()
  if state.enabled then
    M.disable()
  else
    M.enable()
  end
end

--- Check if space syncing is enabled.
function M.isEnabled()
  return state.enabled
end

-- Load .spaces-sync-config.lua from the same directory as this module.
local function loadConfigFile()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  local handle = io.popen("readlink '" .. src:gsub("'", "'\\''") .. "' 2>/dev/null")
  local resolved = handle:read("*a"):gsub("%s+$", "")
  handle:close()
  if resolved == "" then resolved = src end
  local dir = resolved:match("(.*/)")
  if not dir then return nil end

  local path = dir .. ".spaces-sync-config.lua"
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  if not content or content:match("^%s*$") then return nil end

  local fn, err = load(content, path)
  if not fn then
    print("[SpacesSync] WARNING: config file error: " .. tostring(err))
    return nil
  end
  local ok, result = pcall(fn)
  if not ok then
    print("[SpacesSync] WARNING: config file runtime error: " .. tostring(result))
    return nil
  end
  if type(result) ~= "table" then return nil end
  return result
end

--- Initialize the module.
-- @param userConfig (optional) table of config overrides.
--   If omitted, loads .spaces-sync-config.lua from the module directory.
--   If that file is missing or empty, uses built-in defaults.
function M.init(userConfig)
  if not userConfig then
    userConfig = loadConfigFile()
  end
  mergeConfig(userConfig)

  info("Initializing (spaces-sync)")

  -- Check macOS version
  local os = getOSVersion()
  if os.major < MIN_OS_MAJOR then
    info("ERROR: macOS " .. MIN_OS_MAJOR .. "+ required (you have " .. os.str .. "). Space sync will not activate.")
    state.osBlocked = true
  elseif os.str ~= TESTED_OS then
    info("WARNING: tested on macOS " .. TESTED_OS .. ", you have " .. os.str .. ". hs.spaces uses private APIs — behavior may differ.")
    state.osBlocked = false
  else
    state.osBlocked = false
  end

  -- Check Hammerspoon version
  local hsVer = getHSVersion()
  if compareVersions(hsVer, TESTED_HS) ~= 0 then
    info("WARNING: tested on Hammerspoon " .. TESTED_HS .. ", you have " .. hsVer .. ". Untested — behavior may differ.")
  end

  -- Check macOS Mission Control settings
  local separateSpaces = hs.execute("defaults read com.apple.spaces spans-displays 2>/dev/null"):gsub("%s+", "")
  if separateSpaces == "1" then
    info("ERROR: 'Displays have separate Spaces' is OFF. All monitors share one Space — nothing to sync. Enable it in System Settings > Desktop & Dock > Mission Control (requires logout).")
    state.osBlocked = true
  end

  local mruSpaces = hs.execute("defaults read com.apple.dock mru-spaces 2>/dev/null"):gsub("%s+", "")
  if mruSpaces == "1" then
    info("WARNING: 'Automatically rearrange Spaces based on most recent use' is ON. This reorders Space indices and will break sync. Disable it in System Settings > Desktop & Dock > Mission Control.")
  end

  rebuildPositionMap()

  -- Bind hotkey if configured
  if state.hotkey then
    state.hotkey:delete()
    state.hotkey = nil
  end
  if config.hotkey then
    state.hotkey = hs.hotkey.bind(config.hotkey[1], config.hotkey[2], function()
      M.toggle()
    end)
  end

  -- Log position map
  info("Screens (" .. totalScreens .. ", reading order):")
  for pos = 1, totalScreens do
    local uuid = positionToUUID[pos]
    if uuid then
      local screen = hs.screen.find(uuid)
      local f = screen:frame()
      info("  pos " .. pos .. ": " .. screen:name() .. " (x=" .. f.x .. ", y=" .. f.y .. ")")
    end
  end

  -- Log sync groups
  for gi, group in ipairs(config.syncGroups) do
    local members = {}
    for _, pos in ipairs(group) do
      local uuid = positionToUUID[pos]
      if uuid then
        table.insert(members, "pos " .. pos .. " (" .. hs.screen.find(uuid):name() .. ")")
      else
        table.insert(members, "pos " .. pos .. " (not connected)")
      end
    end
    info("Group " .. gi .. ": " .. table.concat(members, ", "))
  end

  -- Log independent monitors
  for pos = 1, totalScreens do
    local uuid = positionToUUID[pos]
    if uuid and not getTargetsFor(uuid) then
      info("Independent: pos " .. pos .. " (" .. hs.screen.find(uuid):name() .. ")")
    end
  end

  local hotkeyLabel = ""
  if config.hotkey then
    hotkeyLabel = ". Toggle: " .. table.concat(config.hotkey[1], "+") .. "+" .. config.hotkey[2]
  end
  info("Ready" .. hotkeyLabel .. (config.debug and " (debug mode)" or ""))
end

-- Clean up on reload
stopWatcher()
if state.debounceTimer then
  state.debounceTimer:stop()
  state.debounceTimer = nil
end

return M
