-- Synchronized Spaces Module
-- Keeps matched monitors in sync — switching spaces on one syncs the others
--
-- Usage: Toggle with Ctrl+Alt+Cmd+Y
--
-- When enabled, switching spaces on any synced monitor will
-- automatically switch all other synced monitors to the matching space index.
-- Independent monitors and excluded monitors are never affected.

local M = {}

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

-- Get display name for logging
local function getDisplayName(uuid)
  local screen = hs.screen.find(uuid)
  return screen and screen:name() or uuid:sub(1,8)
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

-- Sync one display to match the space index of another (caller manages syncInProgress)
local function syncDisplayToTarget(sourceDisplayUUID, sourceSpaceID, targetDisplayUUID)
  -- Find the index of the source space
  local sourceIndex = getSpaceIndex(sourceDisplayUUID, sourceSpaceID)
  if not sourceIndex then
    log("Could not find source space index")
    return
  end

  -- Get the space at that index on the target display
  local targetSpaceID = getSpaceAtIndex(targetDisplayUUID, sourceIndex)
  if not targetSpaceID then
    log("Target display has no space at index " .. sourceIndex)
    return
  end

  -- Check if already on target space (avoid unnecessary switch)
  local targetScreen = hs.screen.find(targetDisplayUUID)
  if not targetScreen then
    log("Could not find target screen")
    return
  end

  local currentTargetSpace = hs.spaces.activeSpaceOnScreen(targetScreen)
  if currentTargetSpace == targetSpaceID then
    log("Target display already showing correct space")
    return
  end

  log("Syncing " .. getDisplayName(targetDisplayUUID) .. " to space index " .. sourceIndex)

  local success, err = pcall(function()
    hs.spaces.gotoSpace(targetSpaceID)
  end)

  if not success then
    log("ERROR syncing: " .. tostring(err))
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
    if M.state.syncInProgress then return end

    -- Get current state
    local currentSpaces = hs.spaces.activeSpaces() or {}

    -- Find which display changed
    for displayUUID, currentSpaceID in pairs(currentSpaces) do
      local lastSpaceID = M.state.lastActiveSpaces[displayUUID]

      -- Check if this display changed
      if lastSpaceID and lastSpaceID ~= currentSpaceID then
        log("Display " .. getDisplayName(displayUUID) .. " changed space")

        -- Only sync if change is on one of the synced displays (filtered list)
        local syncedUUIDs = getSyncedDisplayUUIDs()
        local isInSyncGroup = false
        for _, uuid in ipairs(syncedUUIDs) do
          if uuid == displayUUID then isInSyncGroup = true; break end
        end

        if isInSyncGroup then
          log("This is a synced display, syncing partners...")

          -- Block re-entrant sync while we switch all partners
          M.state.syncInProgress = true

          -- Sync all other synced displays to match this one
          for _, otherUUID in ipairs(syncedUUIDs) do
            if otherUUID ~= displayUUID then
              syncDisplayToTarget(displayUUID, currentSpaceID, otherUUID)
            end
          end

          -- Release sync flag after debounce period
          if M.state.debounceTimer then
            M.state.debounceTimer:stop()
          end
          M.state.debounceTimer = hs.timer.doAfter(M.config.debounceSeconds, function()
            M.state.syncInProgress = false
            log("Sync debounce released")
          end)
        else
          log("This is an independent display, no sync needed")
        end
      end
    end

    -- Update state for next iteration
    M.state.lastActiveSpaces = currentSpaces
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
