-- tests/L1/hs_stub.lua
--
-- Minimal `hs` stub sufficient to let `Source/SpacesSync.spoon/init.lua`
-- LOAD without error. We do NOT stub semantic behavior — anything that
-- actually depends on real macOS state must be exercised at L3 / L6,
-- not L1.
--
-- The stub provides table shells for every `hs.*` namespace that init.lua
-- touches at module-load time (i.e., outside of method bodies). Method
-- bodies that call `hs.spaces.gotoSpace()` or `hs.screen.allScreens()` are
-- not invoked at load time, so we don't need to make those callable.
--
-- What IS called at module load:
--   - hs.logger.new('SpacesSync', 'info')   — must return a logger object
--   - hs.host                                — accessed lazily inside getOSVersion (called from :start)
--
-- Everything else is just a table that responds to method-style indexing
-- without erroring. Methods called from inside obj methods at L1 test
-- time would be a separate concern but L1 tests only invoke pure helpers.

local M = {}

-- A no-op logger satisfying hs.logger.new()'s return contract that
-- init.lua expects (level setting + info/warn/error/debug methods).
local function makeLogger()
  local logger = {
    level = 3,  -- info
  }
  function logger.setLogLevel(lvl)
    if type(lvl) == "string" then
      logger.level = ({ debug = 4, info = 3, warning = 2, error = 1 })[lvl] or 3
    else
      logger.level = lvl
    end
  end
  function logger.getLogLevel() return logger.level end
  function logger.d(...) end
  function logger.i(...) end
  function logger.w(...) end
  function logger.e(...) end
  function logger.f(...) end
  return logger
end

-- A permissive table that behaves harmlessly on any access — used as a
-- catch-all for hs subnamespaces we don't need to model.
local function noopNamespace()
  return setmetatable({}, {
    __index = function() return function() end end,
  })
end

M.logger = setmetatable({}, {
  __index = function(_, k)
    if k == "new" then return makeLogger end
    return function() end
  end,
})

M.host = setmetatable({}, {
  __index = function(_, k)
    if k == "operatingSystemVersion" then
      return function() return { major = 15, minor = 7, patch = 5 } end
    end
    return function() end
  end,
})

M.processInfo = { version = "1.1.1-stub" }

-- Below are namespaces whose existence we have to fake but whose
-- functions L1 tests never call. Method calls would just return nil.
-- hs.screen — opt-in stub. By default `find(uuid)` returns nil
-- (preserves the original noop-stub behavior that existing
-- getDisplayLabel tests rely on for the "unknown screen → uuid:8
-- fallback" branch). Tests that NEED hs.screen.find to return a
-- usable screen object — like findChange / getSpaceIndex which
-- pass the screen down to hs.spaces.spacesForScreen — call
-- `hs.screen._test_seed_screen(uuid)` first, which registers the
-- uuid so subsequent find() calls return a fake screen object.
do
  local registered = {}

  M.screen = setmetatable({
    find = function(uuid)
      if not uuid or not registered[uuid] then return nil end
      return {
        _uuid  = uuid,
        getUUID = function(self) return self._uuid end,
        name   = function(self) return "fake-screen-" .. tostring(self._uuid) end,
        frame  = function(self) return { x = 0, y = 0, w = 1920, h = 1080 } end,
      }
    end,
    allScreens = function() return {} end,
    _test_seed_screen = function(uuid) registered[uuid] = true end,
    _test_reset       = function() registered = {} end,
  }, {
    __index = function() return function() end end,
  })
end

-- hs.spaces — partial real stub. `getSpaceIndex` (called from
-- findChange) walks hs.spaces.spacesForScreen looking for a sid.
-- Tests seed _per_screen_spaces[uuid] = {sid1, sid2, ...} then
-- spacesForScreen does an in-memory lookup. Everything else
-- (gotoSpace, activeSpaces, ...) stays a no-op.
M.spaces = setmetatable({
  _per_screen_spaces = {},  -- uuid → list of sids
  spacesForScreen = function(scr)
    -- scr is a stub screen object with a getUUID() method, OR a uuid
    -- string directly (the source code calls spacesForScreen(scr)).
    local uuid = type(scr) == "string" and scr or
                 (scr and scr.getUUID and scr:getUUID())
    return M.spaces._per_screen_spaces[uuid]
  end,
  _test_reset = function() M.spaces._per_screen_spaces = {} end,
  _test_seed = function(uuid, sids) M.spaces._per_screen_spaces[uuid] = sids end,
}, {
  __index = function() return function() end end,  -- everything else: noop
})
M.application = noopNamespace()
M.timer = noopNamespace()
M.canvas = noopNamespace()
M.styledtext = noopNamespace()
M.dialog = noopNamespace()
M.mouse = noopNamespace()
M.eventtap = noopNamespace()
M.alert = noopNamespace()
M.drawing = noopNamespace()

-- hs.settings — a real in-memory stub (not a noopNamespace) because
-- nameForIndex / loadSpaceNames / saveSpaceNames test cases need to
-- seed, read, and clear persisted values. Backing store is a single
-- module-local table; tests reset it via M.settings._test_reset().
do
  local store = {}
  M.settings = {}
  function M.settings.get(key) return store[key] end
  function M.settings.set(key, val)
    if val == nil then store[key] = nil else store[key] = val end
  end
  function M.settings.clear(key) store[key] = nil end
  -- Test helpers — not part of the real hs.settings API.
  function M.settings._test_reset() store = {} end
  function M.settings._test_dump()
    local copy = {}
    for k, v in pairs(store) do copy[k] = v end
    return copy
  end
end
M.execute = function() return "" end  -- returns "" so checkEnvironment string-coerces cleanly
M.accessibilityState = function() return true end
M.spoons = noopNamespace()
M.console = noopNamespace()

-- inspect — used in some debug code; a passthrough is fine.
M.inspect = function(v) return tostring(v) end

return M
