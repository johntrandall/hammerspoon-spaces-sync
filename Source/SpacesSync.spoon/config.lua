--- === SpacesSync.config ===
---
--- Pure data layer for the SpacesSync settings persisted at
--- `~/.hammerspoon/SpacesSync.json`.
---
--- Responsibilities:
---   * load/save/validate the JSON
---   * SHA-256 ring buffer echo suppression so the spoon's own writes
---     don't drive a pathwatcher reload loop
---   * hs.pathwatcher on the parent directory filtered by basename
---     (survives atomic-replace saves from vim, JetBrains, etc.)
---   * parse-failure retry (doAfter 0.25 s × 3) for editors that
---     truncate-then-write
---   * lossless conversion between the GUI / persistent shape (groupOf)
---     and the engine's runtime shape (syncGroups, a list-of-lists)
---   * sparse _lastSeen updates for disconnected displays
---
--- No UI concerns live here. The settings pane and the init.lua wiring
--- both go through this module.
---
--- See dev-docs/diagrams/data-model.mermaid for the schema and
--- dev-docs/diagrams/config-change-flow.mermaid for the runtime
--- interplay with the engine.

local M = {}

-- ============================================================================
-- CONSTANTS
-- ============================================================================

M.SCHEMA_VERSION = 1
M.PATH = os.getenv("HOME") .. "/.hammerspoon/SpacesSync.json"
M.BASENAME = "SpacesSync.json"
M.RING_SIZE = 5
M.PARSE_RETRY_DELAY = 0.25
M.PARSE_RETRY_MAX = 3

-- Letters in the fixed group pool A..J — see vocabulary.md "Sync group → Why 10".
M.GROUP_POOL = { "A", "B", "C", "D", "E", "F", "G", "H", "I", "J" }
local GROUP_POOL_SET = {}
for _, letter in ipairs(M.GROUP_POOL) do GROUP_POOL_SET[letter] = true end

M.DEFAULT = {
  schemaVersion = 1,
  enabled = true,
  syncMode = "automatic",      -- "automatic" | "manual"
  groupOf = {},                -- position-string → letter (A..J)
  groupLabels = {},            -- sparse letter → user label string
  spaceNames = {},             -- letter → { index-string → name }
  _lastSeen = {},              -- position-string → { name, uuid, date, wasIn }
  switchDelay = 0.3,
  debounceSeconds = 0.8,
  popupDuration = 2,
  statusDuration = 3,
  hotkeys = {
    toggle       = { mods = {"ctrl", "alt", "cmd"}, key = "Y" },
    showNames    = { mods = {"ctrl", "alt", "cmd"}, key = "N" },
    renameSpace  = { mods = {"ctrl", "alt", "cmd"}, key = "R" },
    syncNow      = { mods = {"ctrl", "alt", "cmd"}, key = "S" },
    openSettings = { mods = {"ctrl", "alt", "cmd"}, key = "," },
  },
}

-- Optional logger — set to a real hs.logger by init.lua at load time.
-- Stays a silent no-op if not assigned (useful at L1).
local function noopLog() end
M.logger = { d = noopLog, i = noopLog, w = noopLog, e = noopLog, f = noopLog }

-- ============================================================================
-- LOW-LEVEL HELPERS — exposed for L1 testing via debug.getupvalue
-- ============================================================================

-- Deep clone a JSON-compatible Lua value. Tables become fresh tables;
-- primitives pass through.
local function deepClone(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do
    out[k] = deepClone(val)
  end
  return out
end
M._deepClone = deepClone

-- SHA-256 over a raw byte string. Returns a hex digest. Delegates to
-- hs.hash.SHA256 in production; L1 hs_stub provides an FNV-style
-- substitute so the ring-buffer logic can be unit-tested.
local function sha256(bytes)
  if type(hs) ~= "table" or type(hs.hash) ~= "table" or
     type(hs.hash.SHA256) ~= "function" then
    -- Should not happen in production. Return the empty-string sentinel so
    -- the ring buffer behaves "no echoes seen" rather than silently
    -- coercing every write to the same digest (which would cause every
    -- write to look like an echo).
    return "<no-hasher:" .. tostring(#bytes) .. ">"
  end
  return hs.hash.SHA256(bytes)
end
M._sha256 = sha256

-- ============================================================================
-- DISPLAY-NAME HELPER (matches vocabulary.md "Sync group → Default name")
-- ============================================================================

--- displayName(letter, groupLabels) → "A: Code" | "Group A"
function M.displayName(letter, groupLabels)
  if type(letter) ~= "string" or not GROUP_POOL_SET[letter] then
    return tostring(letter)
  end
  local label = groupLabels and groupLabels[letter]
  if type(label) == "string" and label ~= "" then
    return letter .. ": " .. label
  end
  return "Group " .. letter
end

-- ============================================================================
-- groupOf ↔ syncGroups CONVERSIONS
-- ============================================================================

-- groupOf is a JSON object keyed by stringified position numbers:
--   { ["1"] = "A", ["2"] = "A", ["4"] = "B" }
-- syncGroups is the engine's list-of-lists:
--   { {1, 2}, {4} }
-- Letter-ordering is alphabetical (A before B); within each letter, positions
-- are sorted ascending. Both orderings are deterministic so two equivalent
-- configs produce identical syncGroups output.
function M.groupOfToGroups(groupOf)
  if type(groupOf) ~= "table" then return {} end

  -- Bucket positions by letter.
  local buckets = {}
  for posKey, letter in pairs(groupOf) do
    local pos = tonumber(posKey)
    if pos and GROUP_POOL_SET[letter] then
      buckets[letter] = buckets[letter] or {}
      table.insert(buckets[letter], pos)
    end
  end

  -- Emit groups in alphabetical letter order, with positions sorted within.
  local groups = {}
  for _, letter in ipairs(M.GROUP_POOL) do
    local positions = buckets[letter]
    if positions and #positions > 0 then
      table.sort(positions)
      table.insert(groups, positions)
    end
  end
  return groups
end

-- Inverse, used ONCE on first run to seed groupOf from a user's
-- pre-existing obj.syncGroups (the v0.3 way of defining groups). After
-- the JSON file exists, this is never called again.
function M.groupsToGroupOf(syncGroups)
  if type(syncGroups) ~= "table" then return {} end
  local groupOf = {}
  for gi, group in ipairs(syncGroups) do
    local letter = M.GROUP_POOL[gi]
    if not letter then break end  -- past pool size: silently truncate
    if type(group) == "table" then
      for _, pos in ipairs(group) do
        if type(pos) == "number" and pos > 0 and pos == math.floor(pos) then
          groupOf[tostring(pos)] = letter
        end
      end
    end
  end
  return groupOf
end

-- ============================================================================
-- VALIDATION
-- ============================================================================

local function isPositiveNumber(v)
  return type(v) == "number" and v > 0
end

local function asString(v)
  if type(v) == "string" then return v end
  return nil
end

local VALID_MODIFIERS = {
  ctrl = true, alt = true, cmd = true, shift = true,
  fn = true, hyper = true,
}

local function validateHotkey(entry)
  if type(entry) ~= "table" then return nil end
  local key = asString(entry.key)
  if not key or key == "" then return nil end

  local mods = {}
  if type(entry.mods) == "table" then
    for _, m in ipairs(entry.mods) do
      if type(m) == "string" and VALID_MODIFIERS[m:lower()] then
        table.insert(mods, m:lower())
      end
    end
  end
  return { mods = mods, key = key }
end

--- validate(config) → (validated, warnings)
---
--- Returns a config table that's safe to feed to the engine. Unknown or
--- malformed fields are dropped or replaced with defaults; each replacement
--- pushes a string onto the warnings list (caller can log).
---
--- schemaVersion mismatch: log a warn, use the safe subset of known fields.
--- Never silently coerce a future schema into the current one.
function M.validate(cfg)
  local warnings = {}
  local out = deepClone(M.DEFAULT)

  if type(cfg) ~= "table" then
    table.insert(warnings, "config root is not a table; using defaults")
    return out, warnings
  end

  -- schemaVersion: keep the original number, but if it mismatches we
  -- only copy known fields (no silent coercion).
  if type(cfg.schemaVersion) == "number" then
    out.schemaVersion = cfg.schemaVersion
    if cfg.schemaVersion ~= M.SCHEMA_VERSION then
      table.insert(warnings, string.format(
        "schemaVersion %d != expected %d; using safe subset of known fields",
        cfg.schemaVersion, M.SCHEMA_VERSION))
    end
  else
    out.schemaVersion = M.SCHEMA_VERSION
  end

  -- enabled
  if type(cfg.enabled) == "boolean" then
    out.enabled = cfg.enabled
  end

  -- syncMode
  if cfg.syncMode == "automatic" or cfg.syncMode == "manual" then
    out.syncMode = cfg.syncMode
  elseif cfg.syncMode ~= nil then
    table.insert(warnings, "syncMode must be 'automatic' or 'manual'; using 'automatic'")
  end

  -- groupOf
  if type(cfg.groupOf) == "table" then
    out.groupOf = {}
    for posKey, letter in pairs(cfg.groupOf) do
      local pos = tonumber(posKey)
      if pos and pos > 0 and pos == math.floor(pos) and
         type(letter) == "string" and GROUP_POOL_SET[letter] then
        out.groupOf[tostring(pos)] = letter
      else
        table.insert(warnings,
          "groupOf[" .. tostring(posKey) .. "]=" .. tostring(letter) ..
          " is invalid; ignored")
      end
    end
  end

  -- groupLabels (sparse map of letter → user label)
  if type(cfg.groupLabels) == "table" then
    out.groupLabels = {}
    for letter, label in pairs(cfg.groupLabels) do
      if GROUP_POOL_SET[letter] and type(label) == "string" and label ~= "" then
        out.groupLabels[letter] = label
      end
    end
  end

  -- spaceNames (letter → index-string → name)
  if type(cfg.spaceNames) == "table" then
    out.spaceNames = {}
    for letter, inner in pairs(cfg.spaceNames) do
      if GROUP_POOL_SET[letter] and type(inner) == "table" then
        local innerOut = {}
        for idxKey, name in pairs(inner) do
          local idx = tonumber(idxKey)
          if idx and idx > 0 and type(name) == "string" and name ~= "" then
            innerOut[tostring(idx)] = name
          end
        end
        if next(innerOut) then
          out.spaceNames[letter] = innerOut
        end
      end
    end
  end

  -- _lastSeen (position-string → { name, uuid, date, wasIn })
  if type(cfg._lastSeen) == "table" then
    out._lastSeen = {}
    for posKey, entry in pairs(cfg._lastSeen) do
      local pos = tonumber(posKey)
      if pos and pos > 0 and type(entry) == "table" then
        local clean = {
          name = asString(entry.name) or "",
          uuid = asString(entry.uuid) or "",
          date = asString(entry.date) or "",
        }
        -- wasIn is nullable: present (a letter) when the position had a
        -- group assignment at disconnect; absent (nil) otherwise.
        if type(entry.wasIn) == "string" and GROUP_POOL_SET[entry.wasIn] then
          clean.wasIn = entry.wasIn
        end
        out._lastSeen[tostring(pos)] = clean
      end
    end
  end

  -- Timing knobs
  for _, name in ipairs({"switchDelay", "debounceSeconds",
                        "popupDuration", "statusDuration"}) do
    if isPositiveNumber(cfg[name]) then
      out[name] = cfg[name]
    elseif cfg[name] ~= nil then
      table.insert(warnings,
        name .. "=" .. tostring(cfg[name]) .. " is not a positive number; using default")
    end
  end

  -- Hotkeys
  if type(cfg.hotkeys) == "table" then
    -- Start from defaults so a partial user hotkey table doesn't strip the
    -- others; then overlay every well-formed entry.
    for action, entry in pairs(cfg.hotkeys) do
      local validated = validateHotkey(entry)
      if validated then
        out.hotkeys[action] = validated
      else
        table.insert(warnings,
          "hotkeys." .. tostring(action) .. " is malformed; using default")
      end
    end
  end

  return out, warnings
end

-- ============================================================================
-- SERIALIZATION
-- ============================================================================

local function encodeJSON(t)
  if type(hs) ~= "table" or type(hs.json) ~= "table" or
     type(hs.json.encode) ~= "function" then
    error("config: hs.json.encode unavailable (running outside Hammerspoon?)")
  end
  -- Pretty-print so hand-edits in vim are readable.
  return hs.json.encode(t, true)
end

local function decodeJSON(bytes)
  if type(hs) ~= "table" or type(hs.json) ~= "table" or
     type(hs.json.decode) ~= "function" then
    error("config: hs.json.decode unavailable")
  end
  return hs.json.decode(bytes)
end

local function readBytes(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local bytes = f:read("*all")
  f:close()
  return bytes
end

local function writeBytes(path, bytes)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(bytes)
  f:close()
  return true
end

M._readBytes = readBytes
M._writeBytes = writeBytes

-- ============================================================================
-- ECHO-SUPPRESSION RING BUFFER
-- ============================================================================
--
-- Every write pushes the SHA-256 of the bytes onto a small circular buffer
-- (most-recent first). On a pathwatcher fire, we hash the file contents and
-- compare against the ring; a hit means "this is my own write, ignore it".
--
-- Why a ring and not just last-write tracking: FSEvents coalesces; a single
-- write can fire 1..N times, and editors that atomically rename may also
-- produce extra events. The 5-slot ring absorbs all reasonable bursts without
-- making the buffer big enough to drop genuine external edits.

local ringBuffer = {}  -- newest at [1]

local function ringPush(hash)
  table.insert(ringBuffer, 1, hash)
  while #ringBuffer > M.RING_SIZE do
    table.remove(ringBuffer)
  end
end

local function ringContains(hash)
  for _, h in ipairs(ringBuffer) do
    if h == hash then return true end
  end
  return false
end

-- Test hooks.
M._ringPush = ringPush
M._ringContains = ringContains
function M._ringReset() ringBuffer = {} end
function M._ringSnapshot()
  local copy = {}
  for i, h in ipairs(ringBuffer) do copy[i] = h end
  return copy
end

-- ============================================================================
-- PUBLIC LOAD / SAVE
-- ============================================================================

--- load() → (config, warnings, rawBytes)
---
--- Reads the JSON, validates, returns a usable config table. If the file
--- doesn't exist, returns the default config and an empty warnings list
--- (does NOT create the file — first-run seeding is the caller's
--- responsibility via save()).
---
--- On JSON parse error, the failure is logged and DEFAULT is returned with
--- a warning entry. The caller may want to schedule a retry; see
--- loadWithRetry() for the pathwatcher path.
function M.load()
  local bytes, ioErr = readBytes(M.PATH)
  if not bytes then
    -- File missing or unreadable; return defaults silently. Caller knows
    -- whether this is first-run vs an error case by checking the path.
    return deepClone(M.DEFAULT), {}, nil
  end

  local ok, parsed = pcall(decodeJSON, bytes)
  if not ok or type(parsed) ~= "table" then
    M.logger.e("config: JSON parse failed: " .. tostring(parsed or "non-table root"))
    local cfg = deepClone(M.DEFAULT)
    return cfg, { "JSON parse failed; using defaults" }, bytes
  end

  local validated, warnings = M.validate(parsed)
  return validated, warnings, bytes
end

--- save(config) → (ok, err)
---
--- Validates the config, encodes to JSON, writes atomically (well: with
--- write-and-flush; atomic rename is not added since the spoon owns the
--- file and the pathwatcher uses the SHA ring to filter echoes anyway),
--- pushes the hash onto the ring buffer.
function M.save(cfg)
  local validated = M.validate(cfg)
  local bytes = encodeJSON(validated)

  ringPush(sha256(bytes))

  local ok, err = writeBytes(M.PATH, bytes)
  if not ok then
    M.logger.e("config: write failed: " .. tostring(err))
    return false, err
  end
  return true
end

-- ============================================================================
-- LAST-SEEN HELPERS (called from screen_watcher.lua)
-- ============================================================================

--- writeLastSeen(position, info)
---
--- Writes a single _lastSeen entry. Reads-modifies-saves; the screen
--- watcher invokes this on disconnect with the position number, the
--- display's last reported name + UUID, today's ISO date, and the group
--- letter the position was assigned to at disconnect (or nil if it was
--- independent).
function M.writeLastSeen(position, info)
  if type(position) ~= "number" or position <= 0 then return end
  local cfg = M.load()
  cfg._lastSeen = cfg._lastSeen or {}
  cfg._lastSeen[tostring(position)] = {
    name = info and info.name or "",
    uuid = info and info.uuid or "",
    date = info and info.date or os.date("%Y-%m-%d"),
    wasIn = info and info.wasIn or nil,
  }
  M.save(cfg)
end

--- clearLastSeen(position)
---
--- Drops a _lastSeen entry — invoked on reconnect once the position
--- rejoins the active set.
function M.clearLastSeen(position)
  if type(position) ~= "number" or position <= 0 then return end
  local cfg = M.load()
  if cfg._lastSeen and cfg._lastSeen[tostring(position)] then
    cfg._lastSeen[tostring(position)] = nil
    M.save(cfg)
  end
end

-- ============================================================================
-- PATHWATCHER
-- ============================================================================
--
-- Watches the parent directory (~/.hammerspoon/) filtered by basename
-- "SpacesSync.json". Watching the parent is what survives atomic-replace
-- saves (vim's :w writes to a tempfile then renames over the target;
-- watching the file itself would stop tracking the new inode).

local watcher = nil
local pendingRetry = nil
local retryCount = 0
local onExternalChange = nil

local function deliverChange(parsed, warnings)
  retryCount = 0
  if onExternalChange then
    local ok, err = pcall(onExternalChange, parsed, warnings)
    if not ok then
      M.logger.e("config: onChange callback raised: " .. tostring(err))
    end
  end
end

-- Forward decl so handleEvent and the retry closure can mutually reference.
local handleEvent

handleEvent = function()
  local bytes, ioErr = readBytes(M.PATH)
  if not bytes then
    M.logger.d("config: pathwatcher fired but file unreadable: " .. tostring(ioErr))
    return
  end

  -- Echo suppression — bail if this is the SHA of our own recent write.
  local hash = sha256(bytes)
  if ringContains(hash) then
    M.logger.d("config: pathwatcher fired with own-write echo; ignored")
    return
  end

  local ok, parsed = pcall(decodeJSON, bytes)
  if not ok or type(parsed) ~= "table" then
    -- Partial-write window: editor truncated the file, we read empty/
    -- malformed bytes before it finished writing. Retry up to 3 times
    -- with a 250 ms delay; if all retries fail, log and give up (the
    -- next real edit will trigger another event).
    retryCount = retryCount + 1
    if retryCount <= M.PARSE_RETRY_MAX then
      M.logger.d(string.format(
        "config: parse failed (attempt %d/%d); retrying in %.2fs",
        retryCount, M.PARSE_RETRY_MAX, M.PARSE_RETRY_DELAY))
      if pendingRetry then pendingRetry:stop() end
      if type(hs) == "table" and hs.timer and hs.timer.doAfter then
        pendingRetry = hs.timer.doAfter(M.PARSE_RETRY_DELAY, handleEvent)
      end
    else
      M.logger.e("config: JSON parse failed after " ..
                 M.PARSE_RETRY_MAX .. " retries; ignoring this edit")
      retryCount = 0
    end
    return
  end

  local validated, warnings = M.validate(parsed)
  deliverChange(validated, warnings)
end

M._handleEvent = handleEvent
function M._setRetryCount(n) retryCount = n end
function M._getRetryCount() return retryCount end

--- startWatcher(onChange)
---
--- Begin watching ~/.hammerspoon/ for SpacesSync.json edits. `onChange` is
--- invoked with (validatedConfig, warnings) whenever an external edit is
--- detected (i.e., not an echo of the spoon's own save).
function M.startWatcher(onChange)
  if watcher then return end  -- idempotent
  if type(hs) ~= "table" or type(hs.pathwatcher) ~= "table" or
     type(hs.pathwatcher.new) ~= "function" then
    M.logger.w("config: hs.pathwatcher unavailable; external edits will not be detected")
    return
  end

  onExternalChange = onChange

  local parent = M.PATH:match("(.+)/[^/]+$") or "."
  watcher = hs.pathwatcher.new(parent, function(paths)
    -- Filter to events that mention our basename. paths is a list of
    -- absolute paths from FSEvents — basename match is enough.
    for _, p in ipairs(paths or {}) do
      if p:match(M.BASENAME .. "$") then
        handleEvent()
        return
      end
    end
  end)
  watcher:start()
  M.logger.d("config: pathwatcher started on " .. parent)
end

--- stopWatcher()
function M.stopWatcher()
  if pendingRetry then
    pendingRetry:stop()
    pendingRetry = nil
  end
  retryCount = 0
  if watcher then
    watcher:stop()
    watcher = nil
    onExternalChange = nil
    M.logger.d("config: pathwatcher stopped")
  end
end

return M
