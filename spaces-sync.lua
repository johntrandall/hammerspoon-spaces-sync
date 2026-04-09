-- Synchronized Spaces Module
-- Keeps matched monitors in sync — switching spaces on one syncs the others
--
-- Usage: Toggle with Ctrl+Alt+Cmd+Y
--
-- When enabled, switching spaces on any synced monitor will
-- automatically switch all other synced monitors to the matching space index.
-- Independent monitors and excluded monitors are never affected.

local M = {}

-- Preload extensions to avoid lazy-load latency during sync
require("hs.screen")
require("hs.spaces")
require("hs.application")
require("hs.timer")

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

M.config = {
  -- Monitor names to synchronize (partial match, case-insensitive)
  -- Any monitor whose name contains one of these strings will be synced
  syncedMonitorPatterns = { "LG" },

  -- Monitor names to keep independent (partial match, case-insensitive)
  -- Any monitor whose name contains one of these strings will NOT be synced
  independentMonitorPatterns = { "Geminos" },

  -- Number of leftmost synced monitors to exclude (0 = sync all matched)
  -- e.g., 1 = exclude the leftmost LG, sync the right three
  excludeLeftmost = 1,

  -- Debounce delay to prevent sync loops (seconds)
  debounceSeconds = 0.8,

  -- Enable debug logging
  debug = true
}

-- ============================================================================
-- STATE
-- ============================================================================

M.state = {
  enabled = false,  -- Start disabled, user can enable with hotkey
  lastActiveSpaces = {},
  syncInProgress = false,
  spaceWatcher = nil,
  debounceTimer = nil
}

-- ============================================================================
-- LOGGING
-- ============================================================================

local function log(msg)
  if M.config.debug then
    print("[SpacesSync] " .. msg)
  end
end

-- ============================================================================
-- CORE FUNCTIONS
-- ============================================================================

-- Check if a screen name matches any pattern in a list
local function nameMatchesPatterns(screenName, patterns)
  if not screenName then return false end
  local lowerName = screenName:lower()
  for _, pattern in ipairs(patterns) do
    if lowerName:find(pattern:lower()) then
      return true
    end
  end
  return false
end

-- Check if a display UUID belongs to a synced monitor
local function isSyncedDisplay(uuid)
  local screen = hs.screen.find(uuid)
  if not screen then return false end
  local name = screen:name()

  -- First check if it's explicitly independent
  if nameMatchesPatterns(name, M.config.independentMonitorPatterns) then
    return false
  end

  -- Then check if it matches synced patterns
  return nameMatchesPatterns(name, M.config.syncedMonitorPatterns)
end

-- Build a sorted position map: uuid -> { posIndex, total, x }
-- Cached per reload; call rebuildPositionMap() if screens change
M._positionMap = {}
local function rebuildPositionMap()
  local screens = hs.screen.allScreens()
  local sorted = {}
  for _, s in ipairs(screens) do
    table.insert(sorted, { uuid = s:getUUID(), x = s:frame().x })
  end
  table.sort(sorted, function(a, b) return a.x < b.x end)
  M._positionMap = {}
  for i, entry in ipairs(sorted) do
    M._positionMap[entry.uuid] = { posIndex = i, total = #sorted, x = entry.x }
  end
end

-- Get display name for logging: "LG SDQHD (1) [pos 2/4, x=2048]"
local function getDisplayName(uuid)
  local screen = hs.screen.find(uuid)
  local name = screen and screen:name() or uuid:sub(1,8)
  local pos = M._positionMap[uuid]
  if pos then
    return name .. " [pos " .. pos.posIndex .. "/" .. pos.total .. ", x=" .. pos.x .. "]"
  end
  return name
end

-- Get all currently synced display UUIDs (respects excludeLeftmost)
local function getSyncedDisplayUUIDs()
  -- Collect all pattern-matched screens with their x-position
  local candidates = {}
  for _, screen in ipairs(hs.screen.allScreens()) do
    local uuid = screen:getUUID()
    if isSyncedDisplay(uuid) then
      local f = screen:frame()
      table.insert(candidates, { uuid = uuid, x = f.x })
    end
  end

  -- Sort by x-position (left to right)
  table.sort(candidates, function(a, b) return a.x < b.x end)

  -- Exclude the leftmost N
  local skip = M.config.excludeLeftmost or 0
  local uuids = {}
  for i, entry in ipairs(candidates) do
    if i > skip then
      table.insert(uuids, entry.uuid)
    else
      log("Excluding leftmost: " .. getDisplayName(entry.uuid) .. " (x=" .. entry.x .. ")")
    end
  end
  return uuids
end

-- Get the index of a space on a display
local function getSpaceIndex(displayUUID, spaceID)
  local screen = hs.screen.find(displayUUID)
  if not screen then return nil end

  local spaces = hs.spaces.spacesForScreen(screen)
  if not spaces then return nil end

  for i, sid in ipairs(spaces) do
    if sid == spaceID then
      return i
    end
  end
  return nil
end

-- Get space ID at a specific index on a display
local function getSpaceAtIndex(displayUUID, index)
  local screen = hs.screen.find(displayUUID)
  if not screen then return nil end

  local spaces = hs.spaces.spacesForScreen(screen)
  if not spaces then return nil end
  return spaces[index]
end

-- Count spaces on a display
local function getSpaceCount(displayUUID)
  local screen = hs.screen.find(displayUUID)
  if not screen then return 0 end
  local spaces = hs.spaces.spacesForScreen(screen)
  return spaces and #spaces or 0
end

-- Sync one display to match the space index of another (caller manages syncInProgress)
local function syncDisplayToTarget(sourceDisplayUUID, sourceSpaceID, targetDisplayUUID)
  local targetName = getDisplayName(targetDisplayUUID)
  local targetSpaceCount = getSpaceCount(targetDisplayUUID)
  local sourceSpaceCount = getSpaceCount(sourceDisplayUUID)

  -- Find the index of the source space
  local sourceIndex = getSpaceIndex(sourceDisplayUUID, sourceSpaceID)
  if not sourceIndex then
    log("  " .. targetName .. " (" .. targetSpaceCount .. " spaces): SKIP — could not find source space index")
    return
  end

  -- Check if target has enough spaces
  if sourceIndex > targetSpaceCount then
    log("  " .. targetName .. " (" .. targetSpaceCount .. " spaces): SKIP — no space at index " .. sourceIndex .. " (source has " .. sourceSpaceCount .. " spaces)")
    return
  end

  -- Get the space at that index on the target display
  local targetSpaceID = getSpaceAtIndex(targetDisplayUUID, sourceIndex)
  if not targetSpaceID then
    log("  " .. targetName .. " (" .. targetSpaceCount .. " spaces): SKIP — getSpaceAtIndex returned nil for index " .. sourceIndex)
    return
  end

  -- Check if already on target space (avoid unnecessary switch)
  local targetScreen = hs.screen.find(targetDisplayUUID)
  if not targetScreen then
    log("  " .. targetName .. ": SKIP — screen not found")
    return
  end

  local currentTargetSpace = hs.spaces.activeSpaceOnScreen(targetScreen)
  local currentIdx = getSpaceIndex(targetDisplayUUID, currentTargetSpace) or "?"
  if currentTargetSpace == targetSpaceID then
    log("  " .. targetName .. " (" .. targetSpaceCount .. " spaces): already at index " .. sourceIndex .. ", no switch needed")
    return
  end

  log("  " .. targetName .. " (" .. targetSpaceCount .. " spaces): switching from index " .. tostring(currentIdx) .. " -> " .. sourceIndex .. " (spaceID=" .. targetSpaceID .. ")")

  local success, err = pcall(function()
    hs.spaces.gotoSpace(targetSpaceID)
  end)

  if not success then
    log("  " .. targetName .. ": ERROR — " .. tostring(err))
    return
  end

  -- Verify the switch actually happened
  local postSwitchSpace = hs.spaces.activeSpaceOnScreen(targetScreen)
  local postSwitchIdx = getSpaceIndex(targetDisplayUUID, postSwitchSpace) or "?"
  if postSwitchSpace == targetSpaceID then
    log("  " .. targetName .. ": VERIFIED at index " .. sourceIndex)
  else
    log("  " .. targetName .. ": FAILED — gotoSpace returned OK but still at index " .. tostring(postSwitchIdx) .. " (expected " .. sourceIndex .. ")")
  end
end

-- ============================================================================
-- WATCHER
-- ============================================================================

local function setupWatcher()
  if M.state.spaceWatcher then
    M.state.spaceWatcher:stop()
  end

  -- Get initial state
  M.state.lastActiveSpaces = hs.spaces.activeSpaces() or {}

  -- Create new watcher
  M.state.spaceWatcher = hs.spaces.watcher.new(function()
    if not M.state.enabled then return end
    if M.state.syncInProgress then
      log("WATCHER fired but syncInProgress=true, ignoring")
      return
    end

    -- Get current state
    local currentSpaces = hs.spaces.activeSpaces() or {}

    -- Log all current space indices for context
    local stateLog = {}
    for uuid, spaceID in pairs(currentSpaces) do
      local idx = getSpaceIndex(uuid, spaceID) or "?"
      table.insert(stateLog, getDisplayName(uuid) .. "=idx" .. tostring(idx))
    end
    log("WATCHER fired. Current spaces: " .. table.concat(stateLog, ", "))

    -- Find which display changed
    local changedUUID = nil
    local changedSpaceID = nil
    local oldIndex = nil
    local newIndex = nil

    for displayUUID, currentSpaceID in pairs(currentSpaces) do
      local lastSpaceID = M.state.lastActiveSpaces[displayUUID]
      if lastSpaceID and lastSpaceID ~= currentSpaceID then
        local oi = getSpaceIndex(displayUUID, lastSpaceID) or "?"
        local ni = getSpaceIndex(displayUUID, currentSpaceID) or "?"
        log("CHANGED: " .. getDisplayName(displayUUID) .. " space index " .. tostring(oi) .. " -> " .. tostring(ni))

        if not changedUUID then
          changedUUID = displayUUID
          changedSpaceID = currentSpaceID
          oldIndex = oi
          newIndex = ni
        else
          log("  (multiple displays changed simultaneously, only syncing first)")
        end
      end
    end

    if not changedUUID then
      log("WATCHER: no display change detected, updating state and returning")
      M.state.lastActiveSpaces = currentSpaces
      return
    end

    -- Only sync if change is on one of the synced displays (filtered list)
    local syncedUUIDs = getSyncedDisplayUUIDs()
    local isInSyncGroup = false
    for _, uuid in ipairs(syncedUUIDs) do
      if uuid == changedUUID then isInSyncGroup = true; break end
    end

    if not isInSyncGroup then
      log("SKIP: " .. getDisplayName(changedUUID) .. " is not in sync group (excluded or independent)")
      M.state.lastActiveSpaces = currentSpaces
      return
    end

    -- Determine partners to sync
    local partners = {}
    for _, otherUUID in ipairs(syncedUUIDs) do
      if otherUUID ~= changedUUID then
        table.insert(partners, getDisplayName(otherUUID))
      end
    end
    log("SYNCING: " .. getDisplayName(changedUUID) .. " changed to index " .. tostring(newIndex) .. ". Syncing partners: " .. table.concat(partners, ", "))
    log("Disabling watcher while we sync to other spaces...")

    -- Block re-entrant sync while we switch all partners
    M.state.syncInProgress = true

    -- Build list of partners to sync
    local partnersToSync = {}
    for _, otherUUID in ipairs(syncedUUIDs) do
      if otherUUID ~= changedUUID then
        table.insert(partnersToSync, otherUUID)
      end
    end

    -- Chain gotoSpace calls with delay between each
    -- (rapid back-to-back calls get dropped by macOS)
    local switchDelay = 0.3  -- seconds between each gotoSpace
    local function syncPartner(index)
      if index > #partnersToSync then
        -- All partners done — snapshot and release
        M.state.lastActiveSpaces = hs.spaces.activeSpaces() or {}

        local postLog = {}
        for uuid, spaceID in pairs(M.state.lastActiveSpaces) do
          local idx = getSpaceIndex(uuid, spaceID) or "?"
          table.insert(postLog, getDisplayName(uuid) .. "=idx" .. tostring(idx))
        end
        log("ALL PARTNERS DONE. Post-sync spaces: " .. table.concat(postLog, ", "))

        -- Release sync flag after debounce period
        if M.state.debounceTimer then
          M.state.debounceTimer:stop()
        end
        M.state.debounceTimer = hs.timer.doAfter(M.config.debounceSeconds, function()
          M.state.syncInProgress = false
          M.state.lastActiveSpaces = hs.spaces.activeSpaces() or {}
          log("Debounce released, watcher re-enabled")
        end)
        return
      end

      local otherUUID = partnersToSync[index]
      log("Syncing partner " .. index .. "/" .. #partnersToSync .. "...")
      syncDisplayToTarget(changedUUID, changedSpaceID, otherUUID)

      -- Wait before switching next partner
      hs.timer.doAfter(switchDelay, function()
        syncPartner(index + 1)
      end)
    end

    -- Start the chain
    syncPartner(1)
  end)

  M.state.spaceWatcher:start()
  log("Watcher started")
end

local function stopWatcher()
  if M.state.spaceWatcher then
    M.state.spaceWatcher:stop()
    M.state.spaceWatcher = nil
    log("Watcher stopped")
  end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

function M.enable()
  M.state.enabled = true
  M.state.syncInProgress = false
  M.state.lastActiveSpaces = hs.spaces.activeSpaces() or {}
  setupWatcher()
  hs.alert.show("Space Sync: ON")
  log("Enabled")
end

function M.disable()
  M.state.enabled = false
  stopWatcher()
  hs.alert.show("Space Sync: OFF")
  log("Disabled")
end

function M.toggle()
  if M.state.enabled then
    M.disable()
  else
    M.enable()
  end
end

function M.isEnabled()
  return M.state.enabled
end

-- ============================================================================
-- CLEANUP
-- ============================================================================

function M.cleanup()
  stopWatcher()
  if M.state.debounceTimer then
    M.state.debounceTimer:stop()
    M.state.debounceTimer = nil
  end
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

function M.init()
  log("Initializing")

  -- Build position map for display labels
  rebuildPositionMap()

  -- Bind hotkey to toggle (Ctrl+Alt+Cmd+Y)
  hs.hotkey.bind({"ctrl", "alt", "cmd"}, "Y", function()
    M.toggle()
  end)

  -- Log detected monitors
  log("Ready. Toggle sync with Ctrl+Alt+Cmd+Y")
  log("Sync patterns: " .. table.concat(M.config.syncedMonitorPatterns, ", "))
  log("Independent patterns: " .. table.concat(M.config.independentMonitorPatterns, ", "))

  -- Show which monitors are in the sync group
  local syncGroupUUIDs = getSyncedDisplayUUIDs()
  local syncGroupSet = {}
  for _, uuid in ipairs(syncGroupUUIDs) do syncGroupSet[uuid] = true end

  log("Exclude leftmost: " .. (M.config.excludeLeftmost or 0))
  for _, screen in ipairs(hs.screen.allScreens()) do
    local uuid = screen:getUUID()
    local name = screen:name()
    local f = screen:frame()
    local label
    if syncGroupSet[uuid] then
      label = "SYNCED"
    elseif isSyncedDisplay(uuid) then
      label = "EXCLUDED (leftmost)"
    else
      label = "INDEPENDENT"
    end
    log("  " .. name .. " (x=" .. f.x .. ") -> " .. label)
  end
end

-- Cleanup on reload
M.cleanup()

return M
