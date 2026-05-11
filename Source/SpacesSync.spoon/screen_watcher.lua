--- === SpacesSync.screen_watcher ===
---
--- Tracks display connect/disconnect events for the settings layer.
---
--- On disconnect, writes a sparse `_lastSeen` entry into
--- SpacesSync.json capturing the display's last-known name, UUID, the
--- ISO date of the disconnect, and the group letter (if any) that the
--- position was assigned to at the moment it disconnected.
---
--- On reconnect, drops the matching `_lastSeen` entry so stale rows
--- vanish from the settings pane once the display rejoins.
---
--- Note: this is a SECOND screen watcher from the engine's perspective.
--- The engine has its own `hs.screen.watcher` (init.lua's
--- `setupScreenWatcher`) that rebuilds the position map. The watchers
--- don't interfere — both fire on the same OS event but do orthogonal
--- work. Splitting them keeps the engine's chain-bail logic isolated
--- from the settings-layer persistence.

local M = {}

-- Filled in by init.lua at load time.
M.config = nil       -- config.lua module
M.logger = { d = function() end, i = function() end,
             w = function() end, e = function() end }

local watcher = nil

-- Track screens we've seen across watcher fires so we can diff. The
-- engine's position map can't be reused for this because it's already
-- been rebuilt by the time our callback runs — we need the pre-change
-- snapshot.
--
-- Layout: previousScreens[uuid] = { name = ..., position = ..., wasIn = ... }
-- where wasIn is the group letter from obj.syncGroups at last-snapshot
-- time, or nil if independent.
local previousScreens = {}

local function snapshotScreen(screen, position, getGroupForPosition)
  return {
    name = screen:name() or "",
    position = position,
    wasIn = getGroupForPosition and getGroupForPosition(position) or nil,
  }
end

-- Rebuild previousScreens from the current world. Called once at start
-- and on connect events.
local function takeSnapshot(getGroupForPosition)
  previousScreens = {}
  local screens = hs.screen.allScreens()

  -- Build a position map identical to the engine's logic so we agree on
  -- which display is "position N" at snapshot time.
  local sorted = {}
  for _, s in ipairs(screens) do
    local f = s:frame()
    table.insert(sorted, { screen = s, uuid = s:getUUID(), x = f.x, y = f.y })
  end
  table.sort(sorted, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)

  for i, entry in ipairs(sorted) do
    previousScreens[entry.uuid] = snapshotScreen(entry.screen, i, getGroupForPosition)
  end
end

-- Public: configure module dependencies and start watching.
--
-- getGroupForPosition(position) → letter | nil
-- Provided by init.lua; reads obj.syncGroups and the position map to
-- look up which letter (A..J) the given position is assigned to. Maps
-- the engine's "positional sync group" model back to "letter" via the
-- groupOf-style mapping the settings layer thinks in.
function M.start(deps)
  if watcher then return end
  if not deps or type(deps.config) ~= "table" then
    error("screen_watcher.start: deps.config (config.lua module) is required")
  end
  M.config = deps.config
  M.logger = deps.logger or M.logger
  local getGroupForPosition = deps.getGroupForPosition

  -- Seed the previous-screens snapshot with the current world. Without
  -- this, the first watcher fire after start would treat every currently
  -- attached display as a "newly connected" disconnect-then-reconnect.
  takeSnapshot(getGroupForPosition)

  watcher = hs.screen.watcher.new(function()
    -- Diff previous snapshot against current. Note: we read the new
    -- world AFTER macOS settles (the engine's screen watcher also
    -- coalesces via its 250 ms debounce; here we just react and let
    -- macOS hand us idempotent fires).
    local currentScreens = {}
    for _, s in ipairs(hs.screen.allScreens()) do
      currentScreens[s:getUUID()] = s
    end

    -- Disconnects: in previousScreens but not in currentScreens.
    for uuid, prev in pairs(previousScreens) do
      if not currentScreens[uuid] then
        local info = {
          name = prev.name,
          uuid = uuid,
          date = os.date("%Y-%m-%d"),
          wasIn = prev.wasIn,  -- may be nil for independent displays
        }
        M.logger.i(string.format(
          "screen_watcher: position %d (%s) disconnected; writing _lastSeen (wasIn=%s)",
          prev.position, info.name, tostring(prev.wasIn)))
        if M.config and M.config.writeLastSeen then
          M.config.writeLastSeen(prev.position, info)
        end
      end
    end

    -- Reconnects: in currentScreens but not previousScreens. Use
    -- the new world's position map to identify which position the
    -- reconnected display now occupies, and drop the _lastSeen entry
    -- at THAT position (the position is what the user sees in the
    -- settings pane, not the UUID).
    local newPositionMap = {}
    do
      local sorted = {}
      for _, s in ipairs(hs.screen.allScreens()) do
        local f = s:frame()
        table.insert(sorted, { uuid = s:getUUID(), x = f.x, y = f.y })
      end
      table.sort(sorted, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
      end)
      for i, e in ipairs(sorted) do newPositionMap[e.uuid] = i end
    end

    for uuid in pairs(currentScreens) do
      if not previousScreens[uuid] then
        local pos = newPositionMap[uuid]
        if pos then
          M.logger.i(string.format(
            "screen_watcher: new display at position %d (uuid %s); clearing _lastSeen",
            pos, uuid:sub(1, 8)))
          if M.config and M.config.clearLastSeen then
            M.config.clearLastSeen(pos)
          end
        end
      end
    end

    -- Refresh snapshot for the next fire.
    takeSnapshot(getGroupForPosition)
  end)
  watcher:start()
  M.logger.d("screen_watcher: started")
end

function M.stop()
  if watcher then
    watcher:stop()
    watcher = nil
    M.logger.d("screen_watcher: stopped")
  end
  previousScreens = {}
end

return M
