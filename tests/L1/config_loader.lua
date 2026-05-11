-- tests/L1/config_loader.lua
--
-- Loads Source/SpacesSync.spoon/config.lua against the same hs_stub
-- used by loader.lua (so the two coexist when both are required in
-- the same run). Returns the config module table plus a tmpdir
-- helper so specs can point config.PATH at a per-test scratch file.

local M = {}

local repo_root = os.getenv("PWD") or "."
package.path = repo_root .. "/tests/L1/?.lua;" .. package.path

-- Reuse an existing _G.hs (set by loader.lua) if present; otherwise
-- bootstrap our own. Either way both modules see the same stub.
if not _G.hs then
  _G.hs = dofile(repo_root .. "/tests/L1/hs_stub.lua")
end

local chunk, err = loadfile(repo_root .. "/Source/SpacesSync.spoon/config.lua")
if not chunk then
  error("config_loader: loadfile failed: " .. tostring(err))
end
local ok, mod = pcall(chunk)
if not ok then
  error("config_loader: execution failed: " .. tostring(mod))
end

M.config = mod

-- Per-test scratch path. Each call generates a fresh path so specs
-- don't leak state into each other.
function M.tmpPath()
  local tmp = os.tmpname()
  -- os.tmpname() on macOS returns "/tmp/lua_XXXX" — file may already
  -- exist as a zero-byte placeholder. We treat it as a path string.
  -- Caller is responsible for os.remove() if they want a true blank
  -- start, but config.load() handles missing files gracefully so we
  -- can leave the placeholder alone.
  os.remove(tmp)
  return tmp
end

-- Reset module-level state so a spec starts clean.
function M.reset()
  M.config._ringReset()
  M.config._setRetryCount(0)
end

return M
