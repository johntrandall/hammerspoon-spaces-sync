-- Synchronized Spaces Module
-- Keeps monitors in sync groups — switching spaces on one syncs the others
--
-- Usage: Toggle with Ctrl+Alt+Cmd+Y
--
-- Monitors are identified by position number (sorted left-to-right, then
-- top-to-bottom). Define sync groups as sets of position numbers. When a
-- monitor in a group switches spaces, all other monitors in that group
-- follow to the matching space index.

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
  -- Sync groups: each group is a list of monitor position numbers.
  -- Positions are assigned left-to-right, then top-to-bottom (reading order).
  -- Monitors not in any group are independent.
  --
  -- Examples:
  --   { {2, 3, 4} }             -- right three monitors sync together
  --   { {1, 2}, {3, 4} }        -- two independent pairs
  --   { {1, 2, 3, 4} }          -- all four sync together
  syncGroups = {
    { 2, 3, 4 },  -- right three LG monitors
  },

  -- Delay between each gotoSpace call (seconds)
  -- macOS drops rapid back-to-back space switches
  switchDelay = 0.3,

  -- Debounce delay after all switches complete (seconds)
  -- Prevents watcher from reacting to our own gotoSpace calls
  debounceSeconds = 0.8,

  -- Enable debug logging
  debug = true
}

-- ============================================================================
-- STATE
-- ============================================================================

M.state = {
  enabled = false,
  lastActiveSpaces = {},
  syncInProgress = false,
  spaceWatcher = nil,
  debounceTimer = nil
}

-- ============================================================================
-- POSITION MAP
-- ============================================================================
-- Maps position numbers to screen UUIDs. Rebuilt on init and screen changes.
-- Position 1 = leftmost (or topmost if same x). Reading order: x then y.

M._positionToUUID = {}   -- posIndex -> uuid
M._uuidToPosition = {}   -- uuid -> posIndex
M._totalScreens = 0

local function rebuildPositionMap()
  local screens = hs.screen.allScreens()
  local sorted = {}
  for _, s in ipairs(screens) do
    local f = s:frame()
    table.insert(sorted, { uuid = s:getUUID(), x = f.x, y = f.y, name = s:name() })
  end
  -- Sort by x first, then y as tiebreaker (reading order)
  table.sort(sorted, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)

  M._positionToUUID = {}
  M._uuidToPosition = {}
  M._totalScreens = #sorted
  for i, entry in ipairs(sorted) do
    M._positionToUUID[i] = entry.uuid
    M._uuidToPosition[entry.uuid] = i
  end
end

-- ============================================================================
-- LOGGING
-- ============================================================================

local function log(msg)
  if M.config.debug then
    print("[SpacesSync] " .. msg)
  end
end

-- Display label for logging: "LG SDQHD (1) [pos 2/4, x=2048, y=25]"
local function getDisplayName(uuid)
  local screen = hs.screen.find(uuid)
  local name = screen and screen:name() or uuid:sub(1, 8)
  local pos = M._uuidToPosition[uuid]
  if pos and screen then
    local f = screen:frame()
    return name .. " [pos " .. pos .. "/" .. M._totalScreens .. ", x=" .. f.x .. ", y=" .. f.y .. "]"
  end
  return name
end

-- ============================================================================
-- SYNC GROUP LOOKUP
-- ============================================================================

-- Find which sync group a UUID belongs to (returns list of partner UUIDs, or nil)
local function getSyncGroupFor(uuid)
  local pos = M._uuidToPosition[uuid]
  if not pos then return nil end

  for _, group in ipairs(M.config.syncGroups) do
    local inGroup = false
    for _, gpos in ipairs(group) do
      if gpos == pos then inGroup = true; break end
    end
    if inGroup then
      -- Return UUIDs of all OTHER members in this group
      local partners = {}
      for _, gpos in ipairs(group) do
        if gpos ~= pos then
          local partnerUUID = M._positionToUUID[gpos]
          if partnerUUID then
            table.insert(partners, partnerUUID)
          else
            log("WARNING: sync group references position " .. gpos .. " but only " .. M._totalScreens .. " screens detected")
          end
        end
      end
      return partners
    end
  end
  return nil  -- not in any group
end

-- ============================================================================
-- SPACE HELPERS
-- ============================================================================

local function getSpaceIndex(displayUUID, spaceID)
  local screen = hs.screen.find(displayUUID)
  if not screen then return nil end
  local spaces = hs.spaces.spacesForScreen(screen)
  if not spaces then return nil end
  for i, sid in ipairs(spaces) do
    if sid == spaceID then return i end
  end
  return nil
end

local function getSpaceAtIndex(displayUUID, index)
  local screen = hs.screen.find(displayUUID)
  if not screen then return nil end
  local spaces = hs.spaces.spacesForScreen(screen)
  if not spaces then return nil end
  return spaces[index]
end

local function getSpaceCount(displayUUID)
  local screen = hs.screen.find(displayUUID)
  if not screen then return 0 end
  local spaces = hs.spaces.spacesForScreen(screen)
  return spaces and #spaces or 0
end

-- ============================================================================
-- SYNC ENGINE
-- ============================================================================

-- Sync one display to match the space index of another (caller manages syncInProgress)
local function syncDisplayToTarget(sourceDisplayUUID, sourceSpaceID, targetDisplayUUID)
  local targetName = getDisplayName(targetDisplayUUID)
  local targetSpaceCount = getSpaceCount(targetDisplayUUID)
  local sourceSpaceCount = getSpaceCount(sourceDisplayUUID)

  local sourceIndex = getSpaceIndex(sourceDisplayUUID, sourceSpaceID)
  if not sourceIndex then
    log("  " .. targetName .. " (" .. targetSpaceCount .. " spaces): SKIP — could not find source space index")
    return
  end

  if sourceIndex > targetSpaceCount then
    log("  " .. targetName .. " (" .. targetSpaceCount .. " spaces): SKIP — no space at index " .. sourceIndex .. " (source has " .. sourceSpaceCount .. " spaces)")
    return
  end

  local targetSpaceID = getSpaceAtIndex(targetDisplayUUID, sourceIndex)
  if not targetSpaceID then
    log("  " .. targetName .. " (" .. targetSpaceCount .. " spaces): SKIP — getSpaceAtIndex returned nil for index " .. sourceIndex)
    return
  end

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

  log("  " .. targetName .. " (" .. targetSpaceCount .. " spaces): switching index " .. tostring(currentIdx) .. " -> " .. sourceIndex .. " (spaceID=" .. targetSpaceID .. ")")

  local success, err = pcall(function()
    hs.spaces.gotoSpace(targetSpaceID)
  end)

  if not success then
    log("  " .. targetName .. ": ERROR — " .. tostring(err))
    return
  end

  -- Note: gotoSpace is async; immediate verification is unreliable.
  -- The post-sync snapshot (after all partners) is the real check.
  log("  " .. targetName .. ": gotoSpace dispatched")
end

-- ============================================================================
-- WATCHER
-- ============================================================================

local function setupWatcher()
  if M.state.spaceWatcher then
    M.state.spaceWatcher:stop()
  end

  M.state.lastActiveSpaces = hs.spaces.activeSpaces() or {}

  M.state.spaceWatcher = hs.spaces.watcher.new(function()
    if not M.state.enabled then return end
    if M.state.syncInProgress then
      log("WATCHER fired but syncInProgress=true, ignoring")
      return
    end

    local currentSpaces = hs.spaces.activeSpaces() or {}

    -- Log current state
    local stateLog = {}
    for uuid, spaceID in pairs(currentSpaces) do
      local idx = getSpaceIndex(uuid, spaceID) or "?"
      table.insert(stateLog, getDisplayName(uuid) .. "=idx" .. tostring(idx))
    end
    log("WATCHER fired. Current spaces: " .. table.concat(stateLog, ", "))

    -- Find which display changed
    local changedUUID = nil
    local changedSpaceID = nil
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

    -- Find sync partners for the changed display
    local partners = getSyncGroupFor(changedUUID)
    if not partners or #partners == 0 then
      log("SKIP: " .. getDisplayName(changedUUID) .. " is not in any sync group")
      M.state.lastActiveSpaces = currentSpaces
      return
    end

    -- Log what we're about to do
    local partnerNames = {}
    for _, uuid in ipairs(partners) do
      table.insert(partnerNames, getDisplayName(uuid))
    end
    log("SYNCING: " .. getDisplayName(changedUUID) .. " changed to index " .. tostring(newIndex) .. ". Partners: " .. table.concat(partnerNames, ", "))
    log("Disabling watcher while we sync...")

    -- Block re-entrant sync
    M.state.syncInProgress = true

    -- Chain gotoSpace calls with delay between each
    local function syncPartner(index)
      if index > #partners then
        -- All partners done
        M.state.lastActiveSpaces = hs.spaces.activeSpaces() or {}

        local postLog = {}
        for uuid, spaceID in pairs(M.state.lastActiveSpaces) do
          local idx = getSpaceIndex(uuid, spaceID) or "?"
          table.insert(postLog, getDisplayName(uuid) .. "=idx" .. tostring(idx))
        end
        log("ALL PARTNERS DONE. Post-sync spaces: " .. table.concat(postLog, ", "))

        -- Release after debounce
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

      local partnerUUID = partners[index]
      log("Syncing partner " .. index .. "/" .. #partners .. "...")
      syncDisplayToTarget(changedUUID, changedSpaceID, partnerUUID)

      hs.timer.doAfter(M.config.switchDelay, function()
        syncPartner(index + 1)
      end)
    end

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

  rebuildPositionMap()

  -- Bind hotkey
  hs.hotkey.bind({"ctrl", "alt", "cmd"}, "Y", function()
    M.toggle()
  end)

  -- Log position map
  log("Position map (" .. M._totalScreens .. " screens, reading order):")
  for pos = 1, M._totalScreens do
    local uuid = M._positionToUUID[pos]
    if uuid then
      log("  pos " .. pos .. ": " .. getDisplayName(uuid))
    end
  end

  -- Log sync groups
  for gi, group in ipairs(M.config.syncGroups) do
    local members = {}
    for _, pos in ipairs(group) do
      local uuid = M._positionToUUID[pos]
      if uuid then
        table.insert(members, "pos " .. pos .. " (" .. (hs.screen.find(uuid):name()) .. ")")
      else
        table.insert(members, "pos " .. pos .. " (NOT CONNECTED)")
      end
    end
    log("Sync group " .. gi .. ": " .. table.concat(members, ", "))
  end

  -- Log ungrouped monitors
  for pos = 1, M._totalScreens do
    local uuid = M._positionToUUID[pos]
    if uuid and not getSyncGroupFor(uuid) then
      log("Independent: pos " .. pos .. " (" .. (hs.screen.find(uuid):name()) .. ")")
    end
  end

  log("Ready. Toggle with Ctrl+Alt+Cmd+Y")
end

-- Cleanup on reload
M.cleanup()

return M
