-- tests/L1/loader.lua
--
-- Loads `Source/SpacesSync.spoon/init.lua` in a controlled harness with
-- a stubbed `hs` global, then exposes the file's local helpers via
-- `debug.getupvalue` introspection. This implements approach (a) from
-- the testing-strategy briefing — "load init.lua in a way that lets
-- you mutate those locals" — without modifying init.lua itself.
--
-- API:
--   loader.obj                 — the Spoon table returned by init.lua
--   loader.helpers             — { compareVersions, isLegacyFlatSchema,
--                                  getGroupKey, getTargetsFor,
--                                  getDisplayLabel } pulled from upvalues
--   loader.set_position_state(p2u, u2p, total)
--                              — reassign the file's local
--                                positionToUUID / uuidToPosition /
--                                totalScreens via debug.setupvalue.
--   loader.get_position_state()
--                              — returns the current values for
--                                inspection / round-trip checks.
--
-- Implementation notes:
-- * `debug.getupvalue` walks a closure's upvalues by index. We seed the
--   walk on a method we KNOW closes over the helper or local we want
--   (e.g. `obj.start` closes over `compareVersions`; the various sync
--   methods close over `positionToUUID` etc.).
-- * Lua 5.5 keeps the same upvalue semantics as 5.1+. The interpreter
--   we run under is Lua 5.5 (verified via `lua -v`).
-- * If init.lua is refactored such that a helper is no longer reachable
--   as an upvalue from a public method, this loader fails fast at
--   load time rather than silently testing nothing.

local INIT_PATH = "Source/SpacesSync.spoon/init.lua"

local M = {}

-- Walk every upvalue of `closure` recursively (depth-first) and collect
-- the first one matching `name`. Returns (value, parent_closure, idx)
-- so the caller can use debug.setupvalue.
--
-- For function-typed upvalues, recurse into THEIR upvalues too — this
-- is how we reach helpers that are never directly closed over by a
-- public method but ARE closed over by another local function that IS.
local function find_upvalue(closure, name, _seen)
  _seen = _seen or {}
  if _seen[closure] then return nil end
  _seen[closure] = true

  local i = 1
  while true do
    local n, v = debug.getupvalue(closure, i)
    if n == nil then break end
    if n == name then
      return v, closure, i
    end
    i = i + 1
  end

  -- Recurse into function upvalues
  i = 1
  while true do
    local n, v = debug.getupvalue(closure, i)
    if n == nil then break end
    if type(v) == "function" then
      local found, fclosure, fidx = find_upvalue(v, name, _seen)
      if found ~= nil then return found, fclosure, fidx end
    end
    i = i + 1
  end

  return nil
end

local function require_upvalue(seed_closure, name)
  local v, closure, idx = find_upvalue(seed_closure, name)
  if v == nil then
    error("loader: could not find upvalue '" .. name ..
          "' starting from given seed closure", 2)
  end
  return v, closure, idx
end

-- Stub `hs`, load init.lua, return the obj table.
local function load_init(repo_root)
  -- Inject hs stub into _G so init.lua's references resolve.
  local stub_path = repo_root .. "/tests/L1/hs_stub.lua"
  package.path = repo_root .. "/tests/L1/?.lua;" .. package.path
  _G.hs = dofile(stub_path)

  -- spoon table is referenced via `obj.spoon` in some code paths;
  -- init.lua reads `spoon` directly nowhere at module load, but
  -- assigns to it indirectly via Hammerspoon's loader. Provide an
  -- empty stub.
  _G.spoon = _G.spoon or {}

  local chunk, err = loadfile(repo_root .. "/" .. INIT_PATH)
  if not chunk then
    error("loader: failed to loadfile init.lua: " .. tostring(err))
  end
  local ok, obj_or_err = pcall(chunk)
  if not ok then
    error("loader: failed to execute init.lua: " .. tostring(obj_or_err))
  end
  return obj_or_err
end

-- Initialize on require.
do
  -- Repo root = current working directory. The tests are run from
  -- the repo root via tests/run.sh, so . is the repo.
  local repo_root = os.getenv("PWD") or "."
  M.obj = load_init(repo_root)

  -- Seed: the methods that close over the helpers we need.
  --   - obj.start closes over compareVersions (calls it inside
  --     :start's environment-checks)
  --   - obj.start also closes over isLegacyFlatSchema indirectly
  --     via ensureNamesLoaded -> loadSpaceNames -> isLegacyFlatSchema
  --   - obj.start closes over rebuildPositionMap which closes over
  --     positionToUUID / uuidToPosition / totalScreens
  --   - obj.renameCurrentSpace closes over getGroupKey
  --   - obj methods that drive the sync chain close over
  --     getTargetsFor and getDisplayLabel
  -- All five helpers should be reachable from obj.start via the
  -- recursive find_upvalue walk.
  if type(M.obj) ~= "table" or type(M.obj.start) ~= "function" then
    error("loader: init.lua did not return an obj with :start method")
  end

  M.helpers = {}
  for _, name in ipairs({
    "compareVersions", "isLegacyFlatSchema",
    "getGroupKey", "getTargetsFor", "getDisplayLabel",
    -- nameForIndex transitively touches hs.settings via ensureNamesLoaded;
    -- hs_stub.lua provides a real in-memory hs.settings to support this.
    "nameForIndex",
    -- findChange + getSpaceIndex use hs.spaces.spacesForScreen; the
    -- L1 stub provides a seedable in-memory map (per_screen_spaces).
    "findChange", "getSpaceIndex",
  }) do
    M.helpers[name] = (require_upvalue(M.obj.start, name))
  end

  -- Find upvalue handles for the position-map locals so we can
  -- mutate them via debug.setupvalue.
  local _, p2u_closure, p2u_idx = require_upvalue(M.obj.start, "positionToUUID")
  local _, u2p_closure, u2p_idx = require_upvalue(M.obj.start, "uuidToPosition")
  local _, ts_closure,  ts_idx  = require_upvalue(M.obj.start, "totalScreens")

  function M.set_position_state(positionToUUID, uuidToPosition, totalScreens)
    debug.setupvalue(p2u_closure, p2u_idx, positionToUUID)
    debug.setupvalue(u2p_closure, u2p_idx, uuidToPosition)
    debug.setupvalue(ts_closure,  ts_idx,  totalScreens)
  end

  function M.get_position_state()
    local _, p2u = debug.getupvalue(p2u_closure, p2u_idx)
    local _, u2p = debug.getupvalue(u2p_closure, u2p_idx)
    local _, ts  = debug.getupvalue(ts_closure,  ts_idx)
    return p2u, u2p, ts
  end

  -- namesLoaded is the once-only flag inside ensureNamesLoaded. Tests
  -- need to reset it between fixtures so subsequent nameForIndex
  -- calls re-read hs.settings (otherwise we test ALL fixtures against
  -- the FIRST seeded value).
  local _, nl_closure, nl_idx = require_upvalue(M.obj.start, "namesLoaded")
  function M.reset_names_loaded()
    debug.setupvalue(nl_closure, nl_idx, false)
  end

  -- SETTINGS_KEY is the constant string used to namespace persisted
  -- names in hs.settings. Tests need it to seed values via
  -- hs.settings.set(SETTINGS_KEY, table).
  M.SETTINGS_KEY = require_upvalue(M.obj.start, "SETTINGS_KEY")
end

return M
