--- === SpacesSync ===
---
--- Synchronize macOS Spaces across displays.
---
--- When you switch Spaces on one display, all other displays in the same
--- sync group follow to the matching Space index.
---
--- Displays are identified by position number (reading order:
--- left-to-right, top-to-bottom). Define sync groups as sets of position
--- numbers.
---
--- **Requirements:**
---  * macOS Sequoia 15.0+ (uses private `hs.spaces` APIs)
---  * Two or more displays with multiple Spaces configured
---  * "Displays have separate Spaces" must be ON (System Settings > Desktop & Dock > Mission Control)
---  * "Automatically rearrange Spaces based on most recent use" should be OFF
---
--- Download: [https://github.com/Hammerspoon/Spoons/raw/master/Spoons/SpacesSync.spoon.zip](https://github.com/Hammerspoon/Spoons/raw/master/Spoons/SpacesSync.spoon.zip)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "SpacesSync"
obj.version = "0.2"
obj.author = "John Randall <john@johnrandall.com>"
obj.homepage = "https://github.com/johntrandall/hammerspoon-spaces-sync"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- SpacesSync.logger
--- Variable
--- Logger object used within the Spoon. Set the log level to control verbosity.
---
--- Default log level: `info`. Set to `debug` for verbose watcher state dumps
--- and per-target dispatch details. Set to `warning` to suppress routine sync
--- messages.
---
--- Example:
--- ```lua
--- spoon.SpacesSync.logger.setLogLevel('debug')
--- ```
obj.logger = hs.logger.new('SpacesSync', 'info')

-- ============================================================================
-- VERSION REQUIREMENTS
-- ============================================================================

local TESTED_OS = { major = 15, minor = 5, patch = 0 }
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

local function compareVersions(a, b)
  local function parts(v)
    local t = {}
    for n in tostring(v):gmatch("(%d+)") do t[#t + 1] = tonumber(n) end
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
-- CONFIGURABLE VARIABLES
-- ============================================================================

--- SpacesSync.syncGroups
--- Variable
--- List of sync groups. Each group is a list of display position numbers.
--- Positions are assigned in reading order (left-to-right, top-to-bottom).
--- Displays not in any group are independent.
---
--- Default value: `{ {1, 2} }`
---
--- Examples:
---  * `{ {1, 2} }` — displays 1 and 2 sync together
---  * `{ {1, 2}, {3, 4} }` — two independent pairs
---  * `{ {1, 2, 3} }` — three displays sync together
obj.syncGroups = { { 1, 2 } }

--- SpacesSync.pollTimeout
--- Variable
--- Maximum seconds to wait for a single `hs.spaces.gotoSpace()` to verify
--- on the target display before continuing to the next target. v3 replaces
--- the v0.2 fixed `switchDelay` with poll-based verification: after each
--- dispatch, `hs.spaces.activeSpaceOnScreen()` is polled until it reports
--- the expected Space ID, or this timeout elapses.
---
--- Calibrated empirically (see `dev-docs/findings/F-010-polling-model-a-vs-b.md`):
--- mean Mission Control flip latency on macOS 15.7.5 is ~753 ms; the largest
--- observed flip was ~898 ms. 2.0 s gives ≈ 2.5x headroom for slow-settle
--- conditions. On timeout, a WARN log is emitted per affected target and
--- the chain continues — the end-of-chain verifier catches the drift.
---
--- Default value: `2.0`
obj.pollTimeout = 2.0

--- SpacesSync.pollInterval
--- Variable
--- Polling cadence for verifying each `hs.spaces.gotoSpace()` dispatch.
--- The runloop will quantize sub-10 ms intervals; in practice this is
--- effectively the lower bound on per-tick work. 30 ms adds at most one
--- tick of post-flip latency to a successful verify.
---
--- Default value: `0.030`
obj.pollInterval = 0.030

--- SpacesSync.switchDelay
--- Variable
--- **Deprecated in v3** — superseded by `pollTimeout` (poll-based verify
--- replaces fixed wait between dispatches). The value is parsed but
--- ignored; a deprecation warning is logged at `:start()`. Will be
--- removed in a future release.
---
--- Default value: `0.3`
obj.switchDelay = 0.3

--- SpacesSync.debounceSeconds
--- Variable
--- **Deprecated in v3** — superseded by per-target observed-value writes
--- that absorb echoes by keeping `lastActiveSpaces` matched to macOS
--- truth. The value is parsed but ignored; a deprecation warning is
--- logged at `:start()`. Will be removed in a future release.
---
--- Default value: `0.8`
obj.debounceSeconds = 0.8

--- SpacesSync.spaceNames
--- Variable
--- Nested table of Space names, keyed by name group then by Space index:
---
--- ```lua
--- {
---   ["1"]     = { [1] = "Notes", [2] = "Music" },              -- independent display 1
---   ["2,3,4"] = { [1] = "Code",  [2] = "Email", [3] = "Browser" }, -- sync group {2,3,4}
--- }
--- ```
---
--- A display's **name group** is the sync group containing its position
--- (sorted, comma-joined — e.g. `"2,3,4"`), or an implicit group-of-one
--- (just its position, e.g. `"1"`) for independent displays. Names live
--- inside the group so independent displays and different sync groups
--- don't share a flat global namespace.
---
--- **This table is populated from `hs.settings` at runtime. Do not assign
--- names here in your config** — they will be overwritten by persisted
--- values. Use `:renameCurrentSpace()` (bound to the `renameSpace`
--- hotkey) to set or clear names; those changes persist across
--- Hammerspoon reloads.
---
--- Unnamed indices render as dim italic "Space N" in the popup.
---
--- Default value: `{}` (filled in from `hs.settings` on first use)
obj.spaceNames = {}

--- SpacesSync.popupDuration
--- Variable
--- How long (in seconds) the Space-names popup remains visible after a
--- Space switch or explicit `:showNames()` call.
---
--- Default value: `2`
obj.popupDuration = 2

--- SpacesSync.statusDuration
--- Variable
--- How long (in seconds) the status HUD ("SpacesSync: ON" / "SpacesSync:
--- OFF") stays on screen when starting, stopping, or toggling the Spoon.
---
--- Default value: `3`
obj.statusDuration = 3

--- SpacesSync.defaultHotkeys
--- Variable
--- Default hotkey mapping. Use with `:bindHotkeys()` for a quick setup:
---
--- ```lua
--- spoon.SpacesSync:bindHotkeys(spoon.SpacesSync.defaultHotkeys)
--- ```
---
--- Default value:
--- ```lua
--- {
---   toggle      = {{"ctrl", "alt", "cmd"}, "Y"},
---   showNames   = {{"ctrl", "alt", "cmd"}, "N"},
---   renameSpace = {{"ctrl", "alt", "cmd"}, "R"},
--- }
--- ```
obj.defaultHotkeys = {
  toggle      = { {"ctrl", "alt", "cmd"}, "Y" },
  showNames   = { {"ctrl", "alt", "cmd"}, "N" },
  renameSpace = { {"ctrl", "alt", "cmd"}, "R" },
}

-- ============================================================================
-- INTERNALS
-- ============================================================================

local state = {
  enabled = false,
  lastActiveSpaces = {},
  syncInProgress = false,
  spaceWatcher = nil,

  -- v3 chain machinery (items 0a, 1, 7)
  chainGeneration = 0,    -- bumped at chain start, BAIL_CHAIN, watchdog fire, :stop()
  chainTimers = {},       -- list of all chain-owned hs.timer handles
  watchdogTimer = nil,    -- safety timer (also lives in chainTimers)

  osBlocked = false,
  lastVerifierResult = nil,  -- { timestamp, mismatches } for :status() (item 10)
}

local positionToUUID = {}
local uuidToPosition = {}
local totalScreens = 0

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
    return name .. " [position " .. pos .. "/" .. totalScreens .. "]"
  end
  return name
end

-- ============================================================================
-- SYNC GROUP LOOKUP
-- ============================================================================

local function getTargetsFor(triggerUUID)
  local pos = uuidToPosition[triggerUUID]
  if not pos then return nil end

  for _, group in ipairs(obj.syncGroups) do
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
            obj.logger.w("Group references position " .. gpos .. " but only " .. totalScreens .. " displays connected")
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
-- SPACE NAMES
-- ============================================================================
--
-- Names are scoped to a "name group" so that independent displays and
-- different sync groups don't share a flat global namespace. The name group
-- for a display is:
--   * The sync group containing the display's position (if any), or
--   * An implicit group-of-one for independent displays.
--
-- The group key is the sorted comma-joined positions of the group, e.g.
-- "2,3,4" for a sync group of displays 2, 3, 4; "1" for an independent
-- display at position 1. This matches the positional identity the user
-- writes in `syncGroups`.
--
-- Persistence layout (keys are stringified for hs.settings / plist round-trip):
--
--   {
--     ["1"]     = { ["1"] = "Notes", ["2"] = "Music" },
--     ["2,3,4"] = { ["1"] = "Code",  ["2"] = "Email", ["3"] = "Browser" },
--   }

local SETTINGS_KEY = "SpacesSync.spaceNames"
local namesLoaded = false

-- Canonical group key for the display at `uuid`. Returns nil if the UUID
-- isn't in the current position map (e.g. map not built yet).
local function getGroupKey(uuid)
  local pos = uuidToPosition[uuid]
  if not pos then return nil end

  if type(obj.syncGroups) == "table" then
    for _, group in ipairs(obj.syncGroups) do
      if type(group) == "table" then
        for _, gpos in ipairs(group) do
          if gpos == pos then
            -- Sort a copy of the group's positions and join with commas.
            local sorted = {}
            for _, p in ipairs(group) do
              if type(p) == "number" then
                sorted[#sorted + 1] = p
              end
            end
            table.sort(sorted)
            local parts = {}
            for _, p in ipairs(sorted) do
              parts[#parts + 1] = tostring(p)
            end
            return table.concat(parts, ",")
          end
        end
      end
    end
  end

  -- Not in any sync group — implicit group-of-one.
  return tostring(pos)
end

-- True if the stored value looks like the old pre-group-key flat schema
-- (top-level values are strings instead of nested tables).
local function isLegacyFlatSchema(stored)
  for _, v in pairs(stored) do
    if type(v) == "string" then return true end
  end
  return false
end

local function loadSpaceNames()
  local stored = hs.settings.get(SETTINGS_KEY)
  if type(stored) ~= "table" then return {} end

  -- Legacy flat schema (index → name): discard. Renames are cheap; not
  -- worth writing a migration that would require knowing which group each
  -- old index belonged to, which we can't know post-hoc.
  if next(stored) and isLegacyFlatSchema(stored) then
    obj.logger.w("Discarding legacy flat spaceNames schema (pre-group-key). Re-rename via ⌃⌥⌘R.")
    hs.settings.set(SETTINGS_KEY, nil)
    return {}
  end

  -- Nested schema: group key → { index (string) → name (string) }.
  -- Normalize the inner keys from strings back to numbers.
  local normalized = {}
  for groupKey, innerTable in pairs(stored) do
    if type(groupKey) == "string" and type(innerTable) == "table" then
      local inner = {}
      for k, v in pairs(innerTable) do
        local n = tonumber(k)
        if n and type(v) == "string" and v ~= "" then
          inner[n] = v
        end
      end
      if next(inner) then
        normalized[groupKey] = inner
      end
    end
  end
  return normalized
end

local function saveSpaceNames()
  local toStore = {}
  for groupKey, inner in pairs(obj.spaceNames) do
    if type(groupKey) == "string" and type(inner) == "table" then
      local innerStore = {}
      for k, v in pairs(inner) do
        if type(v) == "string" and v ~= "" then
          innerStore[tostring(k)] = v
        end
      end
      if next(innerStore) then
        toStore[groupKey] = innerStore
      end
    end
  end
  hs.settings.set(SETTINGS_KEY, toStore)
end

-- Populate obj.spaceNames from hs.settings on first use. Anything the user
-- put in obj.spaceNames via their config is discarded — persistence is the
-- single source of truth for names. Idempotent.
local function ensureNamesLoaded()
  if namesLoaded then return end
  for k in pairs(obj.spaceNames) do
    obj.spaceNames[k] = nil
  end
  local persisted = loadSpaceNames()
  for k, v in pairs(persisted) do
    obj.spaceNames[k] = v
  end
  namesLoaded = true
end

-- Look up the name for the given display's Nth Space. Returns (name,
-- isUnnamed). If the display has no name stored for that index, returns
-- "Space N" with isUnnamed = true.
local function nameForIndex(uuid, index)
  ensureNamesLoaded()
  local groupKey = getGroupKey(uuid)
  if groupKey then
    local group = obj.spaceNames[groupKey]
    if group then
      local name = group[index]
      if name and name ~= "" then
        return name, false
      end
    end
  end
  return "Space " .. tostring(index), true
end

-- ============================================================================
-- POPUP
-- ============================================================================

-- Mockup 4: small context rows above/below + large highlighted current row.
-- All rows show their index. Rendered with hs.canvas on the trigger display.
--
-- Two display modes share this canvas:
--   * Passive popup — `showPopup()`. Timer-dismissed. Used by the watcher
--     after sync, by rename success, by independent-display switches.
--   * Interactive picker — `startPicker()`. Eventtap captures arrow keys to
--     move the selection, Return to switch, Escape to dismiss. Rebuilds the
--     canvas on each keypress via `buildPopupCanvas`.
--
-- `popupState` is shared so a picker launch cleanly supersedes any visible
-- passive popup, and a new passive popup (e.g. from watcher-driven sync)
-- cleanly supersedes an in-progress picker.

local popupState = {
  canvas = nil,
  timer = nil,
  -- Picker state — nil/false when not in interactive mode.
  isPicker = false,
  eventtap = nil,
  pickerTriggerUUID = nil,
  pickerSelectedIndex = nil,
  pickerSpaceCount = nil,
}

-- Forward declarations for mutual reference between the passive-popup and
-- picker layers.
local hidePopup, showPopup, buildPopupCanvas, pickerDismiss

local POPUP_MARGIN_TOP = 80
local POPUP_PAD_X = 24
local POPUP_PAD_Y = 12
local POPUP_ROW_HEIGHT = 26
local POPUP_BIG_HEIGHT = 60
local POPUP_CORNER_RADIUS = 14
local POPUP_MIN_WIDTH = 260
local POPUP_IDX_COL_WIDTH = 36

local SMALL_FONT_SIZE = 14
local SMALL_FONT = "Helvetica"
local BIG_FONT_SIZE = 26
local BIG_FONT = "Helvetica-Bold"

local COLOR_PANEL_FILL   = { red = 30/255, green = 30/255, blue = 32/255, alpha = 0.92 }
local COLOR_PANEL_STROKE = { white = 1, alpha = 0.10 }
local COLOR_SMALL_IDX    = { white = 1, alpha = 0.42 }
local COLOR_SMALL_NAME   = { white = 1, alpha = 0.58 }
local COLOR_UNNAMED      = { white = 1, alpha = 0.32 }
local COLOR_BIG_IDX      = { red = 10/255, green = 132/255, blue = 1, alpha = 1 }  -- macOS system blue
local COLOR_BIG_NAME     = { white = 1, alpha = 1 }

local function measureTextWidth(text, font, size)
  local styled = hs.styledtext.new(text, {
    font = { name = font, size = size },
    color = { white = 1, alpha = 1 },
  })
  local s = hs.drawing.getTextDrawingSize(styled)
  return (s and s.w) or (#text * size * 0.6)
end

-- Clears the canvas and cancels the auto-dismiss timer.
-- Does NOT touch picker state — see `pickerDismiss()` for full picker teardown.
hidePopup = function()
  if popupState.timer then
    popupState.timer:stop()
    popupState.timer = nil
  end
  if popupState.canvas then
    popupState.canvas:delete()
    popupState.canvas = nil
  end
end

-- Build and show the canvas for the given display, highlighting
-- `highlightedIndex` (pass nil for no highlight). Does NOT set a dismissal
-- timer and does NOT touch picker state — pure rendering.
-- Used directly by the picker to rebuild on each arrow press; wrapped by
-- `showPopup()` for the passive, timer-dismissed case.
buildPopupCanvas = function(triggerUUID, highlightedIndex)
  -- Clear any existing canvas without touching the timer or picker state.
  if popupState.canvas then
    popupState.canvas:delete()
    popupState.canvas = nil
  end

  local screen = hs.screen.find(triggerUUID)
  if not screen then return end

  local spaceCount = getSpaceCount(triggerUUID)
  if spaceCount < 1 then return end

  ensureNamesLoaded()

  -- Build row list — only indices that currently exist on the trigger display.
  local rows = {}
  local maxNameWidth = 0
  for i = 1, spaceCount do
    local name, isUnnamed = nameForIndex(triggerUUID, i)
    local isCurrent = (highlightedIndex ~= nil and i == highlightedIndex)
    local font = isCurrent and BIG_FONT or SMALL_FONT
    local size = isCurrent and BIG_FONT_SIZE or SMALL_FONT_SIZE
    local w = measureTextWidth(name, font, size)
    if w > maxNameWidth then maxNameWidth = w end
    rows[#rows + 1] = {
      index = i,
      name = name,
      unnamed = isUnnamed,
      current = isCurrent,
    }
  end

  local panelWidth = math.max(
    POPUP_MIN_WIDTH,
    math.ceil(maxNameWidth + POPUP_PAD_X * 2 + POPUP_IDX_COL_WIDTH + 8)
  )

  local panelHeight = POPUP_PAD_Y * 2
  for _, row in ipairs(rows) do
    panelHeight = panelHeight + (row.current and POPUP_BIG_HEIGHT or POPUP_ROW_HEIGHT)
  end

  local sf = screen:frame()
  local x = math.floor(sf.x + (sf.w - panelWidth) / 2)
  local y = math.floor(sf.y + POPUP_MARGIN_TOP)

  local c = hs.canvas.new({ x = x, y = y, w = panelWidth, h = panelHeight })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })

  -- Rounded panel background
  c:appendElements({
    type = "rectangle",
    action = "fill",
    fillColor = COLOR_PANEL_FILL,
    roundedRectRadii = { xRadius = POPUP_CORNER_RADIUS, yRadius = POPUP_CORNER_RADIUS },
    frame = { x = 0, y = 0, w = panelWidth, h = panelHeight },
  })
  c:appendElements({
    type = "rectangle",
    action = "stroke",
    strokeColor = COLOR_PANEL_STROKE,
    strokeWidth = 1,
    roundedRectRadii = { xRadius = POPUP_CORNER_RADIUS, yRadius = POPUP_CORNER_RADIUS },
    frame = { x = 0, y = 0, w = panelWidth, h = panelHeight },
  })

  -- Row content
  local cursorY = POPUP_PAD_Y
  for _, row in ipairs(rows) do
    local rowHeight = row.current and POPUP_BIG_HEIGHT or POPUP_ROW_HEIGHT
    local fontSize = row.current and BIG_FONT_SIZE or SMALL_FONT_SIZE
    local fontName = row.current and BIG_FONT or SMALL_FONT

    local idxColor = row.current and COLOR_BIG_IDX or COLOR_SMALL_IDX
    local nameColor
    if row.current then
      nameColor = COLOR_BIG_NAME
    elseif row.unnamed then
      nameColor = COLOR_UNNAMED
    else
      nameColor = COLOR_SMALL_NAME
    end

    -- Vertically center the text within the row.
    local textY = cursorY + (rowHeight - fontSize) / 2 - 2

    c:appendElements({
      type = "text",
      text = hs.styledtext.new(tostring(row.index), {
        font = { name = fontName, size = fontSize },
        color = idxColor,
        paragraphStyle = { alignment = "right" },
      }),
      frame = {
        x = POPUP_PAD_X,
        y = textY,
        w = POPUP_IDX_COL_WIDTH - 8,
        h = fontSize + 6,
      },
    })

    c:appendElements({
      type = "text",
      text = hs.styledtext.new(row.name, {
        font = { name = fontName, size = fontSize },
        color = nameColor,
      }),
      frame = {
        x = POPUP_PAD_X + POPUP_IDX_COL_WIDTH,
        y = textY,
        w = panelWidth - POPUP_PAD_X * 2 - POPUP_IDX_COL_WIDTH,
        h = fontSize + 6,
      },
    })

    cursorY = cursorY + rowHeight
  end

  c:show()
  popupState.canvas = c
end

-- Passive popup: shows the popup for `obj.popupDuration` seconds, then
-- auto-dismisses. Dismisses any in-progress picker first. Used by the
-- watcher after sync, by `renameCurrentSpace`, and by independent-display
-- switches.
showPopup = function(triggerUUID, highlightedIndex)
  if popupState.isPicker then
    pickerDismiss()
  end
  if popupState.timer then
    popupState.timer:stop()
    popupState.timer = nil
  end
  buildPopupCanvas(triggerUUID, highlightedIndex)
  popupState.timer = hs.timer.doAfter(obj.popupDuration, hidePopup)
end

-- Single-line status HUD ("SpacesSync: ON" / "SpacesSync: OFF") shown on
-- start/stop/toggle. Matches the popup's visual language (dark rounded
-- panel, HUD window level, center-top of main screen) but renders a single
-- centered bold line. Reuses popupState so that a status HUD cleanly
-- supersedes any visible popup or picker.
--
-- Callers inside `:start()` must defer with `hs.timer.doAfter(0, ...)` — see
-- `dev-docs/hammerspoon-and-spaces-quirks.md` for the init-time canvas race.
local STATUS_PAD_X = 32
local STATUS_PAD_Y = 18
local STATUS_FONT_SIZE = 22
local STATUS_FONT = "Helvetica-Bold"

local function showStatusHUD(text)
  -- Clean up anything currently on screen: an in-progress picker, a passive
  -- popup, or an earlier status HUD. pickerDismiss() is idempotent and
  -- also calls hidePopup() internally, so it covers all three cases.
  pickerDismiss()

  local screen = hs.screen.mainScreen()
  if not screen then return end

  local textWidth = measureTextWidth(text, STATUS_FONT, STATUS_FONT_SIZE)
  local panelWidth = math.max(
    POPUP_MIN_WIDTH,
    math.ceil(textWidth + STATUS_PAD_X * 2)
  )
  local panelHeight = math.ceil(STATUS_FONT_SIZE + STATUS_PAD_Y * 2)

  local sf = screen:frame()
  local x = math.floor(sf.x + (sf.w - panelWidth) / 2)
  local y = math.floor(sf.y + POPUP_MARGIN_TOP)

  local c = hs.canvas.new({ x = x, y = y, w = panelWidth, h = panelHeight })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })

  c:appendElements({
    type = "rectangle",
    action = "fill",
    fillColor = COLOR_PANEL_FILL,
    roundedRectRadii = { xRadius = POPUP_CORNER_RADIUS, yRadius = POPUP_CORNER_RADIUS },
    frame = { x = 0, y = 0, w = panelWidth, h = panelHeight },
  })
  c:appendElements({
    type = "rectangle",
    action = "stroke",
    strokeColor = COLOR_PANEL_STROKE,
    strokeWidth = 1,
    roundedRectRadii = { xRadius = POPUP_CORNER_RADIUS, yRadius = POPUP_CORNER_RADIUS },
    frame = { x = 0, y = 0, w = panelWidth, h = panelHeight },
  })

  c:appendElements({
    type = "text",
    text = hs.styledtext.new(text, {
      font = { name = STATUS_FONT, size = STATUS_FONT_SIZE },
      color = COLOR_BIG_NAME,
      paragraphStyle = { alignment = "center" },
    }),
    frame = {
      x = STATUS_PAD_X,
      y = STATUS_PAD_Y - 2,
      w = panelWidth - STATUS_PAD_X * 2,
      h = STATUS_FONT_SIZE + 6,
    },
  })

  c:show()
  popupState.canvas = c
  popupState.timer = hs.timer.doAfter(obj.statusDuration, hidePopup)
end

-- ============================================================================
-- PICKER
-- ============================================================================

-- Interactive picker state machine built on top of the popup canvas.
-- User invokes via `:showNames()` (⌃⌥⌘N). While visible:
--   * Up / Down      — move selection (wraps)
--   * Return / Enter — switch to selected Space
--   * Escape         — dismiss without switching
--   * Any other key  — passes through to the focused app
-- Auto-dismisses after `PICKER_INACTIVITY_SECONDS` of no keypresses.
--
-- The post-switch passive popup remains non-interactive — pressing arrows
-- there does nothing. Only `:showNames()` enters the picker. This keeps the
-- passive notification out of the user's keyboard path.

local PICKER_INACTIVITY_SECONDS = 5

-- macOS virtual key codes (see hs.keycodes.map)
local KEY_UP           = 126
local KEY_DOWN         = 125
local KEY_RETURN       = 36
local KEY_NUMPAD_ENTER = 76
local KEY_ESCAPE       = 53

local function stopPickerEventtap()
  if popupState.eventtap then
    popupState.eventtap:stop()
    popupState.eventtap = nil
  end
end

-- Reset the auto-dismiss inactivity timer. Called on every keypress.
local function pickerResetTimer()
  if popupState.timer then
    popupState.timer:stop()
  end
  popupState.timer = hs.timer.doAfter(PICKER_INACTIVITY_SECONDS, function()
    pickerDismiss()
  end)
end

-- Full picker teardown: stop eventtap, clear state, hide canvas + timer.
-- Idempotent — safe to call when the picker isn't active.
pickerDismiss = function()
  stopPickerEventtap()
  popupState.isPicker = false
  popupState.pickerTriggerUUID = nil
  popupState.pickerSelectedIndex = nil
  popupState.pickerSpaceCount = nil
  hidePopup()
end

-- Execute the user's selection: tear down the picker, then dispatch
-- gotoSpace. Done in this order so the watcher's post-sync passive popup
-- replaces (rather than fights with) the picker's canvas.
local function pickerExecuteSwitch()
  local uuid     = popupState.pickerTriggerUUID
  local selIndex = popupState.pickerSelectedIndex

  stopPickerEventtap()
  popupState.isPicker = false
  popupState.pickerTriggerUUID = nil
  popupState.pickerSelectedIndex = nil
  popupState.pickerSpaceCount = nil
  hidePopup()

  if not uuid or not selIndex then return end

  local targetSpaceID = getSpaceAtIndex(uuid, selIndex)
  if not targetSpaceID then
    obj.logger.w("picker: no Space at index " .. tostring(selIndex))
    return
  end

  obj.logger.i("picker: switching to index " .. tostring(selIndex))
  local ok, err = pcall(function() hs.spaces.gotoSpace(targetSpaceID) end)
  if not ok then
    obj.logger.e("picker: gotoSpace error — " .. tostring(err))
  end
  -- The hs.spaces.watcher will fire from the switch and, if the display is
  -- in a sync group, sync siblings and show a passive post-switch popup.
end

local function pickerNavigate(delta)
  if not popupState.isPicker then return end
  local count = popupState.pickerSpaceCount or 0
  if count < 1 then return end

  local new = (popupState.pickerSelectedIndex or 1) + delta
  if new < 1 then new = count end
  if new > count then new = 1 end
  popupState.pickerSelectedIndex = new

  -- TODO(flicker): full canvas rebuild on each keypress. If this feels
  -- laggy or visually jarring during rapid navigation, switch to in-place
  -- element mutation (canvas[i].text, canvas[i].frame) and a uniform
  -- row-height design. See TODO.md "picker canvas flicker" item.
  buildPopupCanvas(popupState.pickerTriggerUUID, new)
  pickerResetTimer()
end

-- Open the interactive picker on the given display, starting with
-- `startingIndex` selected (typically the display's current Space).
local function startPicker(triggerUUID, startingIndex)
  -- Defensive: if a previous picker never got torn down, clean it up.
  if popupState.isPicker then pickerDismiss() end

  local screen = hs.screen.find(triggerUUID)
  if not screen then
    obj.logger.w("picker: no display for UUID " .. tostring(triggerUUID))
    return
  end

  local count = getSpaceCount(triggerUUID)
  if count < 1 then
    obj.logger.w("picker: no Spaces on display")
    return
  end

  popupState.isPicker            = true
  popupState.pickerTriggerUUID   = triggerUUID
  popupState.pickerSelectedIndex = startingIndex or 1
  popupState.pickerSpaceCount    = count

  buildPopupCanvas(triggerUUID, popupState.pickerSelectedIndex)
  pickerResetTimer()

  -- Event tap: intercept arrow keys and Return/Escape while picker is up,
  -- pass everything else through so the user can keep typing in their app.
  popupState.eventtap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    if not popupState.isPicker then return false end
    local keyCode = event:getKeyCode()

    if keyCode == KEY_UP then
      pickerNavigate(-1)
      return true
    elseif keyCode == KEY_DOWN then
      pickerNavigate(1)
      return true
    elseif keyCode == KEY_RETURN or keyCode == KEY_NUMPAD_ENTER then
      pickerExecuteSwitch()
      return true
    elseif keyCode == KEY_ESCAPE then
      pickerDismiss()
      return true
    end
    return false  -- passthrough
  end)
  popupState.eventtap:start()
end

-- Expose startPicker to the public API closure below.
local function openPicker(triggerUUID, startingIndex)
  startPicker(triggerUUID, startingIndex)
end

-- ============================================================================
-- SYNC ENGINE
-- ============================================================================
--
-- v3 verify-based chain. The chain runs from runSyncChain(), which:
--   * Bumps state.chainGeneration and captures `myGen` so any closure that
--     was queued before BAIL_CHAIN/:stop()/watchdog can detect "I was
--     bailed" on its next tick (item 0a).
--   * Computes expectedEndState — a per-display UUID -> Space ID map of
--     what the world should look like at chain end (item 0). This single
--     map drives both per-target dispatch and end-of-chain verification.
--   * Iterates targets via syncNext, doing skip-or-dispatch -> poll-verify
--     -> observed-value write per target (items 1, 2). No inter-dispatch
--     wait — F-010 confirmed Model B (160/160 dispatches at gap=0).
--   * On finish: POPUP, end-of-chain VERIFY, then CLEAR (items 5, 5b).
--
-- chainTimers is a single list of every timer the chain owns (poll
-- timers + watchdog). One cancellation site (cancelChainTimers) drains
-- them all at chain end / BAIL_CHAIN / :stop() / watchdog fire.

local function registerChainTimer(timer)
  if timer then
    table.insert(state.chainTimers, timer)
  end
end

local function cancelChainTimers()
  for _, t in ipairs(state.chainTimers) do
    pcall(function() t:stop() end)
  end
  state.chainTimers = {}
  state.watchdogTimer = nil
end

-- ============================================================================
-- WATCHDOG (item 7)
-- ============================================================================
--
-- Fires if state.syncInProgress stays true longer than the bound — covers
-- unhandled errors anywhere in the chain. Registered in chainTimers and
-- captures state.chainGeneration so it no-ops if a new chain has started
-- since this watchdog was scheduled.
--
-- Bound: numTargets × pollTimeout + safety_margin. Worst case for a
-- 4-display group (3 targets) at pollTimeout=2s is 6s; bound = 8s = 6 + 2.
-- The bound deliberately does NOT include the popup display window — the
-- popup is fire-and-forget; the watchdog is only protecting the chain.

local function startWatchdog(myGen)
  -- Cancel any previous watchdog (defensive — it should already be in
  -- chainTimers and drained by now).
  if state.watchdogTimer then
    pcall(function() state.watchdogTimer:stop() end)
    state.watchdogTimer = nil
  end
  -- Scale to pollTimeout in case the user lowered it for testing.
  local bound = math.max(8.0, 3 * obj.pollTimeout + 2.0)
  local timer = hs.timer.doAfter(bound, function()
    state.watchdogTimer = nil
    -- Generation guard: a new chain has already started; let its watchdog
    -- handle that one.
    if myGen ~= state.chainGeneration then return end
    if not state.syncInProgress then return end

    obj.logger.e("Sync watchdog fired — flag was stuck after " ..
                 string.format("%.1f", bound) .. "s; chain abandoned")

    -- Action sequence (mirrors BAIL_CHAIN / :stop ordering):
    -- 1. Bump chainGeneration so any closure still queued bails on next tick.
    state.chainGeneration = state.chainGeneration + 1
    -- 2. Stop any remaining chainTimers (defensive — should already be drained).
    cancelChainTimers()
    -- 3. Refresh state.lastActiveSpaces so the next watcher fire diffs against truth.
    state.lastActiveSpaces = hs.spaces.activeSpaces() or {}
    -- 4. Set state.syncInProgress = false LAST.
    state.syncInProgress = false
  end)
  state.watchdogTimer = timer
  registerChainTimer(timer)
end

-- ============================================================================
-- END-OF-CHAIN VERIFIER (item 5b)
-- ============================================================================
--
-- Diff actual vs expectedEndState at chain end. Logs ERROR per mismatch
-- and refreshes state.lastActiveSpaces from actual so the next watcher
-- fire diffs against truth (the invariant "lastActiveSpaces matches
-- macOS" is restored even after a partial chain). Records a one-shot
-- summary into state.lastVerifierResult for :status() (item 10).
--
-- Scope: runs ONLY on the sync-group path (per council scope reduction).
-- NO_CHANGE confirmed nothing changed; INDEPENDENT didn't dispatch
-- anything; reconfig (Stage 4) already rebuilds baseline from scratch.

local function verifyEndState(expectedEndState)
  local actual = hs.spaces.activeSpaces() or {}
  local mismatches = {}

  for uuid, expectedSpaceID in pairs(expectedEndState) do
    local actualSpaceID = actual[uuid]
    if actualSpaceID == nil then
      table.insert(mismatches, { uuid = uuid, kind = "vanished" })
    elseif actualSpaceID ~= expectedSpaceID then
      table.insert(mismatches, {
        uuid = uuid, kind = "wrong-space",
        expectedIdx = getSpaceIndex(uuid, expectedSpaceID) or "?",
        actualIdx   = getSpaceIndex(uuid, actualSpaceID) or "?",
      })
    end
  end

  for uuid, _ in pairs(actual) do
    if expectedEndState[uuid] == nil then
      table.insert(mismatches, { uuid = uuid, kind = "appeared" })
    end
  end

  if #mismatches > 0 then
    obj.logger.e("State-check failed (sync-group path):")
    for _, m in ipairs(mismatches) do
      if m.kind == "wrong-space" then
        obj.logger.e("  " .. getDisplayLabel(m.uuid) ..
          ": expected idx " .. tostring(m.expectedIdx) ..
          ", got idx " .. tostring(m.actualIdx))
      else
        obj.logger.e("  " .. getDisplayLabel(m.uuid) .. ": " .. m.kind)
      end
    end
    -- Restore invariant: next watcher fire diffs against truth.
    state.lastActiveSpaces = actual
  end

  state.lastVerifierResult = {
    timestamp  = os.time(),
    mismatches = mismatches,
  }

  return #mismatches == 0
end

-- ============================================================================
-- SYNC CHAIN (items 0, 0a, 1, 2, 5, 5b)
-- ============================================================================

local function runSyncChain(changedUUID, changedSpaceID, newIndex, targets, currentSpaces)
  -- Resolve trigger index. If we can't determine it, we can't compute
  -- expectedEndState for the targets — log and bail without LOCK.
  local triggerIndex = getSpaceIndex(changedUUID, changedSpaceID)
  if not triggerIndex then
    obj.logger.w("SYNC: trigger space index not found; skipping chain")
    state.lastActiveSpaces = currentSpaces
    return
  end

  -- ----- LOCK + chainGeneration bump (items 0a) -----
  state.syncInProgress = true
  state.chainGeneration = state.chainGeneration + 1
  local myGen = state.chainGeneration

  -- ----- Bulk baseline write -----
  -- Capture the post-trigger view of the world. Per-target observed-value
  -- writes (item 2) overlay target keys after each poll. The trigger and
  -- independents are captured here so the next non-sync-group watcher fire
  -- diffs cleanly. (Without this, lastActiveSpaces[trigger] would stay at
  -- the pre-swipe value and produce a phantom "trigger changed" diff on
  -- the next event.)
  state.lastActiveSpaces = currentSpaces

  -- ----- COMPUTE_EXPECTED (item 0) -----
  local expectedEndState = {}
  for uuid, spaceID in pairs(currentSpaces) do
    expectedEndState[uuid] = spaceID
  end
  for _, targetUUID in ipairs(targets) do
    local targetSpaceID = getSpaceAtIndex(targetUUID, triggerIndex)
    if targetSpaceID then
      expectedEndState[targetUUID] = targetSpaceID
    end
    -- if nil: target has no Space at this index — leave entry alone.
    -- step 0 in syncNext will see current == expected and skip.
  end

  if obj.logger.level >= 4 then -- debug
    local parts = {}
    for uuid, spaceID in pairs(expectedEndState) do
      local idx = getSpaceIndex(uuid, spaceID) or "?"
      table.insert(parts, getDisplayLabel(uuid) .. "=idx" .. tostring(idx))
    end
    obj.logger.d("EXPECTED: " .. table.concat(parts, ", "))
  end

  -- Targets summary log
  local targetNames = {}
  for _, targetUUID in ipairs(targets) do
    table.insert(targetNames, getDisplayLabel(targetUUID))
  end
  obj.logger.i("SYNC: " .. getDisplayLabel(changedUUID) .. " (trigger) -> index " ..
               tostring(newIndex) .. " | targets: " .. table.concat(targetNames, ", "))

  startWatchdog(myGen)

  -- chainEnd runs POPUP -> VERIFY -> CLEAR. Single tail per the P2
  -- single-exit refactor — every non-bailed path lands here.
  local function chainEnd()
    if type(newIndex) == "number" then
      showPopup(changedUUID, newIndex)
    end

    if obj.logger.level >= 4 then -- debug
      local parts = {}
      for uuid, spaceID in pairs(state.lastActiveSpaces) do
        local idx = getSpaceIndex(uuid, spaceID) or "?"
        table.insert(parts, getDisplayLabel(uuid) .. "=idx" .. tostring(idx))
      end
      obj.logger.d("DONE: " .. table.concat(parts, ", "))
    end

    -- VERIFY before CLEAR — keeps the gate closed during verifier read
    -- so a new spaces-watcher fire can't interleave with verify state.
    verifyEndState(expectedEndState)

    -- CLEAR (item 5: no debounce padding)
    cancelChainTimers()  -- drains watchdog
    state.syncInProgress = false
    obj.logger.d("Chain complete; watcher re-armed")
  end

  -- syncNext iterates one target at a time. Each per-target iteration is
  -- step 0 (skip-or-dispatch) -> step 1 (dispatch) -> step 2 (poll) ->
  -- step 3 (branch on outcome) -> step 4 (observed-value write) ->
  -- step 5 (continue). On the success branch the same chainEnd is
  -- reached as on the timeout branch.
  local i = 0
  local function syncNext()
    -- Top-of-tick guard (items 0a, 6): bail if disabled or stale generation.
    if not state.enabled or myGen ~= state.chainGeneration then
      obj.logger.d("syncNext: bailing — disabled or stale generation")
      return
    end

    i = i + 1
    if i > #targets then
      chainEnd()
      return
    end

    local targetUUID = targets[i]
    local label = getDisplayLabel(targetUUID)
    local targetScreen = hs.screen.find(targetUUID)
    if not targetScreen then
      obj.logger.d("  " .. label .. ": SKIP (display not found)")
      syncNext()
      return
    end

    local expectedSpaceID = expectedEndState[targetUUID]
    local current = hs.spaces.activeSpaceOnScreen(targetScreen)

    -- Step 0: skip-or-dispatch decision
    if current == expectedSpaceID then
      -- Either target is already at trigger index (no-op sync) OR target
      -- has no Space at trigger index (item 0 left expectedEndState[uuid]
      -- at snapshot value, which equals current). The two cases are
      -- distinguished by checking whether triggerIndex is in range.
      local targetCount = getSpaceCount(targetUUID)
      if triggerIndex > targetCount then
        obj.logger.i("  " .. label .. " (" .. targetCount .. " spaces): " ..
                     "SKIP (no space at index " .. triggerIndex .. ")")
      else
        obj.logger.d("  " .. label .. ": already at index " ..
                     tostring(triggerIndex))
      end
      -- No dispatch, no observed-value write needed (baseline is already
      -- correct from the bulk write at LOCK).
      syncNext()
      return
    end

    -- Step 1: dispatch
    local currentIdx = getSpaceIndex(targetUUID, current) or "?"
    obj.logger.i("  " .. label .. ": index " .. tostring(currentIdx) ..
                 " -> " .. tostring(triggerIndex))
    local ok, err = pcall(function()
      hs.spaces.gotoSpace(expectedSpaceID)
    end)
    if not ok then
      obj.logger.e("  " .. label .. ": ERROR — " .. tostring(err))
      -- Fall through to poll — the poll will time out if gotoSpace really
      -- failed, but if the API errored partially we still want to wait
      -- and capture the observed value (whatever it ends up being).
    else
      obj.logger.d("  " .. label .. ": dispatched")
    end

    -- Step 2: poll. Tick every obj.pollInterval; each tick re-checks
    -- guards (item 0a). Stop when activeSpaceOnScreen matches expected
    -- OR pollTimeout elapses (then step 3 = timeout).
    local pollDeadlineNs = hs.timer.absoluteTime() + (obj.pollTimeout * 1e9)

    local function pollTick()
      -- Guards on every tick.
      if not state.enabled or myGen ~= state.chainGeneration then
        obj.logger.d("pollTick: bailing — disabled or stale generation")
        return
      end

      local active = hs.spaces.activeSpaceOnScreen(targetScreen)
      if active == expectedSpaceID then
        -- Step 3: success.
        -- Step 4: observed-value write (item 2).
        state.lastActiveSpaces[targetUUID] = active
        obj.logger.d("  " .. label .. ": verified")
        -- Step 5: continue. No inter-dispatch wait (F-010 Model B).
        syncNext()
        return
      end

      if hs.timer.absoluteTime() > pollDeadlineNs then
        -- Step 3: timeout. macOS dropped the dispatch or settle was
        -- unexpectedly slow. Log at WARN; continue chain (the verifier
        -- will surface the resulting drift).
        obj.logger.w("  " .. label .. ": gotoSpace did not land within " ..
                     string.format("%.2f", obj.pollTimeout) .. "s pollTimeout")
        -- Step 4: observed-value write (item 2). On timeout, observed
        -- captures macOS's actual stuck state — the baseline reflects
        -- reality, not optimism (per F-010 §6.2).
        state.lastActiveSpaces[targetUUID] = active or current
        -- Step 5: continue.
        syncNext()
        return
      end

      -- Tick again. Track the timer so :stop / BAIL_CHAIN / watchdog
      -- can drain it.
      local nextTimer = hs.timer.doAfter(obj.pollInterval, pollTick)
      registerChainTimer(nextTimer)
    end

    pollTick()
  end

  syncNext()
end

-- ============================================================================
-- WATCHER
-- ============================================================================

-- Helper: scan the currentSpaces vs lastActiveSpaces diff and return the
-- first changed display (UUID, new SpaceID, new index). Returns nil if
-- no display has changed since the last snapshot. Multi-changed-display
-- handling is OOS for v3 (filed in OmniFocus); when more than one display
-- changed in the same fire, only the first found becomes the trigger.
local function findChange(currentSpaces, lastActiveSpaces)
  local changedUUID, changedSpaceID, newIndex
  for uuid, spaceID in pairs(currentSpaces) do
    local lastSpaceID = lastActiveSpaces[uuid]
    if lastSpaceID and lastSpaceID ~= spaceID then
      local oi = getSpaceIndex(uuid, lastSpaceID) or "?"
      local ni = getSpaceIndex(uuid, spaceID) or "?"
      obj.logger.d("CHANGED: " .. getDisplayLabel(uuid) .. " index " ..
                   tostring(oi) .. " -> " .. tostring(ni))
      if not changedUUID then
        changedUUID = uuid
        changedSpaceID = spaceID
        newIndex = ni
      else
        obj.logger.d("  (multiple changed; syncing first only)")
      end
    end
  end
  return changedUUID, changedSpaceID, newIndex
end

-- v3 single-exit refactor (item P2). Three early-exit paths plus one
-- delegating path:
--   * GUARDS — disabled or mid-chain → return
--   * NO_CHANGE — diff finds nothing changed → refresh baseline, return
--   * INDEPENDENT — trigger has no sync-group → popup + refresh, return
--   * SYNC-GROUP — runSyncChain owns the rest (LOCK, COMPUTE_EXPECTED,
--     poll-verify loop, POPUP, end-of-chain VERIFY, CLEAR)
-- VERIFY_END_STATE only runs on the SYNC-GROUP path; the other paths
-- don't dispatch anything so there is nothing to verify.
local function setupWatcher()
  if state.spaceWatcher then
    state.spaceWatcher:stop()
  end

  state.lastActiveSpaces = hs.spaces.activeSpaces() or {}

  state.spaceWatcher = hs.spaces.watcher.new(function()
    -- ----- Guard layer -----
    if not state.enabled then return end
    if state.syncInProgress then
      obj.logger.d("WATCHER: ignored (sync in progress)")
      return
    end

    local currentSpaces = hs.spaces.activeSpaces() or {}

    if obj.logger.level >= 4 then -- debug
      local parts = {}
      for uuid, spaceID in pairs(currentSpaces) do
        local idx = getSpaceIndex(uuid, spaceID) or "?"
        table.insert(parts, getDisplayLabel(uuid) .. "=idx" .. tostring(idx))
      end
      obj.logger.d("WATCHER: " .. table.concat(parts, ", "))
    end

    -- ----- Diff layer -----
    local changedUUID, changedSpaceID, newIndex =
      findChange(currentSpaces, state.lastActiveSpaces)

    if not changedUUID then
      -- NO_CHANGE path: defensive snapshot refresh, exit.
      state.lastActiveSpaces = currentSpaces
      return
    end

    local targets = getTargetsFor(changedUUID)
    if not targets or #targets == 0 then
      -- INDEPENDENT path: not a sync trigger, just show the user a
      -- name popup so they can see where they landed.
      obj.logger.d("SKIP: " .. getDisplayLabel(changedUUID) ..
                   " not in any sync group")
      if type(newIndex) == "number" then
        showPopup(changedUUID, newIndex)
      end
      state.lastActiveSpaces = currentSpaces
      return
    end

    -- ----- SYNC-GROUP path -----
    runSyncChain(changedUUID, changedSpaceID, newIndex, targets, currentSpaces)
  end)

  state.spaceWatcher:start()
  obj.logger.d("Watcher started")
end

local function stopWatcher()
  if state.spaceWatcher then
    state.spaceWatcher:stop()
    state.spaceWatcher = nil
    obj.logger.d("Watcher stopped")
  end
end

-- ============================================================================
-- ENVIRONMENT CHECKS
-- ============================================================================

local function checkEnvironment()
  state.osBlocked = false

  -- Check macOS version
  local osVer = getOSVersion()
  if osVer.major < MIN_OS_MAJOR then
    obj.logger.e("macOS " .. MIN_OS_MAJOR .. "+ required (you have " .. osVer.str .. "). Space sync will not activate.")
    state.osBlocked = true
  else
    local testedStr = TESTED_OS.major .. "." .. TESTED_OS.minor .. "." .. TESTED_OS.patch
    if osVer.major ~= TESTED_OS.major or osVer.minor ~= TESTED_OS.minor or osVer.patch ~= TESTED_OS.patch then
      obj.logger.w("Tested on macOS " .. testedStr .. ", you have " .. osVer.str .. ". hs.spaces uses private APIs — behavior may differ.")
    end
  end

  -- Check Hammerspoon version
  local hsVer = getHSVersion()
  if compareVersions(hsVer, TESTED_HS) < 0 then
    obj.logger.w("Tested on Hammerspoon " .. TESTED_HS .. ", you have " .. hsVer .. ". Older versions may behave differently.")
  end

  -- Check macOS Mission Control settings
  local separateSpaces = hs.execute("defaults read com.apple.spaces spans-displays 2>/dev/null"):gsub("%s+", "")
  if separateSpaces == "1" then
    obj.logger.e("'Displays have separate Spaces' is OFF. All displays share one Space — nothing to sync. Enable it in System Settings > Desktop & Dock > Mission Control (requires logout).")
    state.osBlocked = true
  end

  local mruSpaces = hs.execute("defaults read com.apple.dock mru-spaces 2>/dev/null"):gsub("%s+", "")
  if mruSpaces == "1" then
    obj.logger.w("'Automatically rearrange Spaces based on most recent use' is ON. This reorders Space indices and will break sync. Disable it in System Settings > Desktop & Dock > Mission Control.")
  end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- SpacesSync:init()
--- Method
--- Initializes the SpacesSync spoon. Called automatically by `hs.loadSpoon()`.
--- Does not start syncing — call `:start()` to begin.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SpacesSync object
function obj:init()
  return self
end

--- SpacesSync:start()
--- Method
--- Starts Space syncing.
--- Checks macOS version and Mission Control settings, builds the display
--- position map, and enables the Space watcher.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SpacesSync object
function obj:start()
  -- Clean up any in-flight state from a previous start()
  if state.enabled then
    self:stop()
  end

  -- Preload extensions to avoid lazy-load latency during sync.
  -- require() alone returns Hammerspoon's lazy proxy without loading the
  -- Objective-C bridge. Touching one function on each module forces the
  -- actual load so it doesn't happen mid-sync.
  require("hs.screen");      local _ = hs.screen.allScreens
  require("hs.spaces");      _ = hs.spaces.activeSpaces
  -- hs.application is loaded as a transitive dependency of hs.spaces.gotoSpace()
  require("hs.application"); _ = hs.application.frontmostApplication
  require("hs.timer");       _ = hs.timer.secondsSinceEpoch
  require("hs.canvas");      _ = hs.canvas.new
  require("hs.styledtext");  _ = hs.styledtext.new
  require("hs.settings");    _ = hs.settings.get
  require("hs.dialog");      _ = hs.dialog.textPrompt
  require("hs.mouse");       _ = hs.mouse.getCurrentScreen
  require("hs.eventtap");    _ = hs.eventtap.new

  ensureNamesLoaded()

  obj.logger.i("Starting (SpacesSync " .. obj.version .. ")")

  -- Validate configuration
  if type(obj.syncGroups) ~= "table" then
    obj.logger.e("syncGroups must be a table, got " .. type(obj.syncGroups))
    return self
  end
  for gi, group in ipairs(obj.syncGroups) do
    if type(group) ~= "table" then
      obj.logger.e("syncGroups[" .. gi .. "] must be a table, got " .. type(group))
      return self
    end
    if #group < 2 then
      obj.logger.w("syncGroups[" .. gi .. "] has " .. #group .. " member(s) — need at least 2 to sync")
    end
    -- Check for overlapping groups
    for _, pos in ipairs(group) do
      if type(pos) ~= "number" or pos < 1 or pos ~= math.floor(pos) then
        obj.logger.e("syncGroups[" .. gi .. "] contains invalid position: " .. tostring(pos) .. " (must be a positive integer)")
        return self
      end
    end
  end
  -- Detect overlapping groups (same position in multiple groups)
  local positionSeen = {}
  for gi, group in ipairs(obj.syncGroups) do
    for _, pos in ipairs(group) do
      if positionSeen[pos] then
        obj.logger.w("Position " .. pos .. " appears in group " .. positionSeen[pos] .. " and group " .. gi .. " — only the first group will be used for triggers from this display")
      else
        positionSeen[pos] = gi
      end
    end
  end
  -- v3 timing knobs (item 1)
  if type(obj.pollTimeout) ~= "number" or obj.pollTimeout <= 0 then
    obj.logger.e("pollTimeout must be a positive number, got " .. tostring(obj.pollTimeout))
    return self
  end
  if obj.pollTimeout < 1.0 then
    obj.logger.w("pollTimeout=" .. obj.pollTimeout ..
                 "s — F-010 measured worst-case flip ~0.9s on a quiet system; " ..
                 "values below 1s risk false timeouts under load (2.0s recommended)")
  end
  if type(obj.pollInterval) ~= "number" or obj.pollInterval <= 0 then
    obj.logger.e("pollInterval must be a positive number, got " .. tostring(obj.pollInterval))
    return self
  end

  -- Deprecated knobs (items 1, 2 in code-changes-pending). Parsed for
  -- type-safety but ignored at runtime. Will be removed in a future release.
  if obj.switchDelay ~= 0.3 then
    obj.logger.w("switchDelay is deprecated in v3 (replaced by pollTimeout) and " ..
                 "ignored at runtime; the value " .. tostring(obj.switchDelay) ..
                 " has no effect.")
  end
  if obj.debounceSeconds ~= 0.8 then
    obj.logger.w("debounceSeconds is deprecated in v3 (replaced by per-target " ..
                 "observed-value writes) and ignored at runtime; the value " ..
                 tostring(obj.debounceSeconds) .. " has no effect.")
  end

  checkEnvironment()

  -- Item 4: hard block on missing Accessibility. hs.spaces.gotoSpace and
  -- hs.eventtap (the picker) both require Accessibility permission. Without
  -- it gotoSpace silently no-ops and there is no in-band signal of the
  -- failure — better to fail loudly here than to look broken at runtime.
  if not hs.accessibilityState(true) then
    obj.logger.e("Accessibility permission required. Grant it in " ..
                 "System Settings > Privacy & Security > Accessibility, " ..
                 "then restart Hammerspoon.")
    hs.alert.show("SpacesSync: Accessibility permission required")
    state.osBlocked = true
    return self
  end

  if state.osBlocked then
    obj.logger.e("Environment checks failed. Space sync will not activate.")
    hs.alert.show("SpacesSync: blocked (see console)")
    return self
  end

  rebuildPositionMap()

  -- Log position map
  obj.logger.i("Screens (" .. totalScreens .. ", reading order):")
  for pos = 1, totalScreens do
    local uuid = positionToUUID[pos]
    if uuid then
      obj.logger.i("  position " .. pos .. ": " .. getDisplayLabel(uuid))
    end
  end

  -- Log sync groups
  for gi, group in ipairs(obj.syncGroups) do
    local members = {}
    for _, pos in ipairs(group) do
      local uuid = positionToUUID[pos]
      if uuid then
        table.insert(members, "position " .. pos .. " (" .. getDisplayLabel(uuid) .. ")")
      else
        table.insert(members, "position " .. pos .. " (not connected)")
      end
    end
    obj.logger.i("Group " .. gi .. ": " .. table.concat(members, ", "))
  end

  -- Log independent displays
  for pos = 1, totalScreens do
    local uuid = positionToUUID[pos]
    if uuid and not getTargetsFor(uuid) then
      obj.logger.i("Independent: position " .. pos .. " (" .. getDisplayLabel(uuid) .. ")")
    end
  end

  state.enabled = true
  state.syncInProgress = false
  -- v3 chain state — re-init from scratch on every :start. Reload survival
  -- is identical to v0.2: an in-flight chain at reload time is abandoned
  -- (Lua state destroyed); macOS-side dispatched gotoSpace calls complete
  -- on their own; new setupWatcher re-snapshots from the post-reload world.
  state.chainGeneration = 0
  state.chainTimers = {}
  state.watchdogTimer = nil
  state.lastVerifierResult = nil
  -- state.lastActiveSpaces is initialized inside setupWatcher() (item 8 fix:
  -- removing a redundant assignment here closes a race where a user swipe
  -- between the two writes was silently absorbed).
  setupWatcher()
  -- Defer the status HUD to the next runloop tick. When :start() is called
  -- from init.lua (e.g. after hs.reload()), Hammerspoon has not yet finished
  -- applicationDidFinishLaunching — canvases created synchronously at this
  -- point are silently dropped. hs.timer.doAfter(0) yields to the next
  -- runloop iteration, which is the canonical Hammerspoon idiom for
  -- "let the window server settle". See dev-docs/hammerspoon-and-spaces-quirks.md.
  hs.timer.doAfter(0, function() showStatusHUD("SpacesSync: ON") end)
  obj.logger.i("Enabled")

  return self
end

--- SpacesSync:stop()
--- Method
--- Stops Space syncing and cleans up watchers and timers.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SpacesSync object
function obj:stop()
  -- Items 6 + 0a: ordering matters. Bump chainGeneration FIRST so any
  -- closure already queued by hs.timer bails on its next tick. Then stop
  -- chain timers and refresh the baseline BEFORE setting state.enabled =
  -- false, so any spaces-watcher fire arriving mid-restore is still
  -- suppressed by the existing enabled? guard.

  -- 1. Bump chainGeneration. Stale closures (poll ticks, watchdog) bail.
  state.chainGeneration = state.chainGeneration + 1

  -- 2. Stop chain-owned timers (single drain — chainTimers includes both
  --    poll timers and the watchdog).
  cancelChainTimers()

  -- 3. Refresh baseline so the next :start (or any in-flight watcher fire)
  --    diffs against truth, not whatever stale view the chain left behind.
  state.lastActiveSpaces = hs.spaces.activeSpaces() or {}

  -- 4. Clear in-progress flag.
  state.syncInProgress = false

  -- 5. Stop the spaces watcher (no more new fires after this).
  stopWatcher()

  -- 6. Disable LAST.
  state.enabled = false

  -- showStatusHUD() internally calls pickerDismiss() which is idempotent
  -- and also clears any canvas/timer. Safe to call without first hiding
  -- any prior popup or picker.
  showStatusHUD("SpacesSync: OFF")
  obj.logger.i("Disabled")
  return self
end

--- SpacesSync:toggle()
--- Method
--- Toggles Space syncing on or off.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SpacesSync object
function obj:toggle()
  if state.enabled then
    self:stop()
  else
    self:start()
  end
  return self
end

--- SpacesSync:isEnabled()
--- Method
--- Returns whether Space syncing is currently active.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A boolean
function obj:isEnabled()
  return state.enabled
end

--- SpacesSync:showNames()
--- Method
--- Opens the interactive Space picker on the display under the mouse cursor
--- (or the main display as fallback). The picker lists every Space on that
--- display with its name and lets you navigate:
---
---  * **↑ / ↓**         — move the selection (wraps)
---  * **Return / Enter** — switch to the selected Space
---  * **Escape**        — dismiss without switching
---  * Any other key     — passes through to the focused app
---
--- Auto-dismisses after 5 seconds of no keypresses. The post-switch popup
--- shown after regular Space switches remains non-interactive.
---
--- Works independently of `:start()` — you can bind this to a hotkey
--- without enabling sync.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SpacesSync object
function obj:showNames()
  ensureNamesLoaded()
  if totalScreens == 0 then rebuildPositionMap() end

  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  if not screen then
    obj.logger.w("showNames: no display available")
    return self
  end

  local uuid = screen:getUUID()
  local currentSpaceID = hs.spaces.activeSpaceOnScreen(screen)
  local index = currentSpaceID and getSpaceIndex(uuid, currentSpaceID) or 1
  openPicker(uuid, index)
  return self
end

--- SpacesSync:renameCurrentSpace()
--- Method
--- Prompts for a new name for the Space currently active on the display
--- under the mouse cursor (or the main display as fallback).
---
--- Names are scoped to the display's **name group**: the sync group
--- containing that display's position, or an implicit group-of-one for
--- independent displays. The rename applies to every display in the same
--- name group (which, by definition, are showing the same Space index
--- anyway because they sync in lockstep). A rename on an independent
--- display does NOT affect any sync group, and vice versa.
---
--- Submitting an empty name clears the existing name for that index in
--- that group.
---
--- After saving, the popup is shown with the renamed space highlighted.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SpacesSync object
function obj:renameCurrentSpace()
  ensureNamesLoaded()
  if totalScreens == 0 then rebuildPositionMap() end

  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  if not screen then
    hs.alert.show("SpacesSync: no display")
    return self
  end

  local uuid = screen:getUUID()
  local currentSpaceID = hs.spaces.activeSpaceOnScreen(screen)
  if not currentSpaceID then
    hs.alert.show("SpacesSync: can't read current Space")
    return self
  end

  local index = getSpaceIndex(uuid, currentSpaceID)
  if not index then
    hs.alert.show("SpacesSync: can't determine Space index")
    return self
  end

  local groupKey = getGroupKey(uuid)
  if not groupKey then
    hs.alert.show("SpacesSync: can't determine sync group")
    return self
  end

  local group = obj.spaceNames[groupKey]
  local existing = (group and group[index]) or ""

  local button, text = hs.dialog.textPrompt(
    "Rename Space " .. index,
    "Enter a name for Space " .. index .. " in group [" .. groupKey .. "]. Applies to this name group only.\nLeave blank to clear.",
    existing,
    "Save",
    "Cancel"
  )

  if button ~= "Save" then
    return self
  end

  if not obj.spaceNames[groupKey] then
    obj.spaceNames[groupKey] = {}
  end

  if text and text ~= "" then
    obj.spaceNames[groupKey][index] = text
    obj.logger.i("Renamed Space " .. index .. " in group [" .. groupKey .. "] -> \"" .. text .. "\"")
  else
    obj.spaceNames[groupKey][index] = nil
    -- Drop the group entry entirely if it's now empty so we don't persist
    -- empty tables.
    if not next(obj.spaceNames[groupKey]) then
      obj.spaceNames[groupKey] = nil
    end
    obj.logger.i("Cleared name for Space " .. index .. " in group [" .. groupKey .. "]")
  end
  saveSpaceNames()

  showPopup(uuid, index)
  return self
end

--- SpacesSync:bindHotkeys(mapping)
--- Method
--- Binds hotkeys for SpacesSync.
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for any of:
---   * toggle - Toggle Space syncing on/off
---   * showNames - Show the Space-names popup on the current display
---   * renameSpace - Rename the currently active Space
---
--- Returns:
---  * The SpacesSync object
---
--- Notes:
---  * For a quick setup with defaults, use:
---    `spoon.SpacesSync:bindHotkeys(spoon.SpacesSync.defaultHotkeys)`
function obj:bindHotkeys(mapping)
  local def = {
    toggle      = function() self:toggle() end,
    showNames   = function() self:showNames() end,
    renameSpace = function() self:renameCurrentSpace() end,
  }
  hs.spoons.bindHotkeysToSpec(def, mapping)
  return self
end

return obj
