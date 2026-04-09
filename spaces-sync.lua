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
-- DEFAULTS
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

  -- Log to Hammerspoon console.
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
}

-- Position map: rebuilt on init
local positionToUUID = {}   -- posIndex -> uuid
local uuidToPosition = {}   -- uuid -> posIndex
local totalScreens = 0

-- Merge user overrides onto defaults
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

local function log(msg)
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

-- Display label for logging: "LG SDQHD (1) [pos 2/4]"
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

local function getPartnersFor(uuid)
  local pos = uuidToPosition[uuid]
  if not pos then return nil end

  for _, group in ipairs(config.syncGroups) do
    local inGroup = false
    for _, gpos in ipairs(group) do
      if gpos == pos then inGroup = true; break end
    end
    if inGroup then
      local partners = {}
      for _, gpos in ipairs(group) do
        if gpos ~= pos then
          local partnerUUID = positionToUUID[gpos]
          if partnerUUID then
            table.insert(partners, partnerUUID)
          else
            log("WARNING: group references pos " .. gpos .. " but only " .. totalScreens .. " screens connected")
          end
        end
      end
      return partners
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

local function syncDisplayToTarget(sourceUUID, sourceSpaceID, targetUUID)
  local label = getDisplayLabel(targetUUID)
  local targetCount = getSpaceCount(targetUUID)

  local sourceIndex = getSpaceIndex(sourceUUID, sourceSpaceID)
  if not sourceIndex then
    log("  " .. label .. ": SKIP (source space index not found)")
    return
  end

  if sourceIndex > targetCount then
    log("  " .. label .. " (" .. targetCount .. " spaces): SKIP (no space at index " .. sourceIndex .. ")")
    return
  end

  local targetSpaceID = getSpaceAtIndex(targetUUID, sourceIndex)
  if not targetSpaceID then
    log("  " .. label .. ": SKIP (getSpaceAtIndex returned nil)")
    return
  end

  local targetScreen = hs.screen.find(targetUUID)
  if not targetScreen then
    log("  " .. label .. ": SKIP (screen not found)")
    return
  end

  local currentSpace = hs.spaces.activeSpaceOnScreen(targetScreen)
  local currentIdx = getSpaceIndex(targetUUID, currentSpace) or "?"
  if currentSpace == targetSpaceID then
    log("  " .. label .. ": already at index " .. sourceIndex)
    return
  end

  log("  " .. label .. ": index " .. tostring(currentIdx) .. " -> " .. sourceIndex)

  local ok, err = pcall(function()
    hs.spaces.gotoSpace(targetSpaceID)
  end)

  if ok then
    log("  " .. label .. ": dispatched")
  else
    log("  " .. label .. ": ERROR — " .. tostring(err))
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
      log("WATCHER: ignored (sync in progress)")
      return
    end

    local currentSpaces = hs.spaces.activeSpaces() or {}

    if config.debug then
      local parts = {}
      for uuid, spaceID in pairs(currentSpaces) do
        local idx = getSpaceIndex(uuid, spaceID) or "?"
        table.insert(parts, getDisplayLabel(uuid) .. "=idx" .. tostring(idx))
      end
      log("WATCHER: " .. table.concat(parts, ", "))
    end

    -- Find which display changed
    local changedUUID, changedSpaceID, newIndex

    for uuid, spaceID in pairs(currentSpaces) do
      local lastSpaceID = state.lastActiveSpaces[uuid]
      if lastSpaceID and lastSpaceID ~= spaceID then
        local oi = getSpaceIndex(uuid, lastSpaceID) or "?"
        local ni = getSpaceIndex(uuid, spaceID) or "?"
        log("CHANGED: " .. getDisplayLabel(uuid) .. " index " .. tostring(oi) .. " -> " .. tostring(ni))

        if not changedUUID then
          changedUUID = uuid
          changedSpaceID = spaceID
          newIndex = ni
        else
          log("  (multiple changed; syncing first only)")
        end
      end
    end

    if not changedUUID then
      state.lastActiveSpaces = currentSpaces
      return
    end

    -- Find sync partners
    local partners = getPartnersFor(changedUUID)
    if not partners or #partners == 0 then
      log("SKIP: " .. getDisplayLabel(changedUUID) .. " not in any sync group")
      state.lastActiveSpaces = currentSpaces
      return
    end

    local names = {}
    for _, uuid in ipairs(partners) do
      table.insert(names, getDisplayLabel(uuid))
    end
    log("SYNC: index " .. tostring(newIndex) .. " -> " .. table.concat(names, ", "))

    -- Block re-entrant sync
    state.syncInProgress = true

    -- Chain switches with delay
    local function syncNext(i)
      if i > #partners then
        state.lastActiveSpaces = hs.spaces.activeSpaces() or {}

        if config.debug then
          local parts = {}
          for uuid, spaceID in pairs(state.lastActiveSpaces) do
            local idx = getSpaceIndex(uuid, spaceID) or "?"
            table.insert(parts, getDisplayLabel(uuid) .. "=idx" .. tostring(idx))
          end
          log("DONE: " .. table.concat(parts, ", "))
        end

        if state.debounceTimer then state.debounceTimer:stop() end
        state.debounceTimer = hs.timer.doAfter(config.debounceSeconds, function()
          state.syncInProgress = false
          state.lastActiveSpaces = hs.spaces.activeSpaces() or {}
          log("Watcher re-enabled")
        end)
        return
      end

      syncDisplayToTarget(changedUUID, changedSpaceID, partners[i])
      hs.timer.doAfter(config.switchDelay, function()
        syncNext(i + 1)
      end)
    end

    syncNext(1)
  end)

  state.spaceWatcher:start()
  log("Watcher started")
end

local function stopWatcher()
  if state.spaceWatcher then
    state.spaceWatcher:stop()
    state.spaceWatcher = nil
    log("Watcher stopped")
  end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- Enable space syncing.
function M.enable()
  state.enabled = true
  state.syncInProgress = false
  state.lastActiveSpaces = hs.spaces.activeSpaces() or {}
  setupWatcher()
  hs.alert.show("Space Sync: ON")
  log("Enabled")
end

--- Disable space syncing.
function M.disable()
  state.enabled = false
  stopWatcher()
  hs.alert.show("Space Sync: OFF")
  log("Disabled")
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
-- Returns the table it exports, or nil if missing/empty/errored.
local function loadConfigFile()
  -- Resolve the directory of this source file
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  -- Follow symlink if needed
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

  log("Initializing")
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
  log("Screens (" .. totalScreens .. ", reading order):")
  for pos = 1, totalScreens do
    local uuid = positionToUUID[pos]
    if uuid then
      local screen = hs.screen.find(uuid)
      local f = screen:frame()
      log("  pos " .. pos .. ": " .. screen:name() .. " (x=" .. f.x .. ", y=" .. f.y .. ")")
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
    log("Group " .. gi .. ": " .. table.concat(members, ", "))
  end

  -- Log independent monitors
  for pos = 1, totalScreens do
    local uuid = positionToUUID[pos]
    if uuid and not getPartnersFor(uuid) then
      log("Independent: pos " .. pos .. " (" .. hs.screen.find(uuid):name() .. ")")
    end
  end

  log("Ready" .. (config.hotkey and (". Toggle: " .. table.concat(config.hotkey[1], "+") .. "+" .. config.hotkey[2]) or ""))
end

-- Clean up on reload
stopWatcher()
if state.debounceTimer then
  state.debounceTimer:stop()
  state.debounceTimer = nil
end

return M
