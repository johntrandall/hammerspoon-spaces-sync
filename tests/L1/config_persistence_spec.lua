-- L1 — config.lua load / save / pathwatcher retry counter

local h = require("helpers")
local cl = require("config_loader")
local config = cl.config

-- The save() / load() paths require a real file. We swap config.PATH
-- to a tmp path per-test so specs don't fight each other.
local function withTmpPath(fn)
  local original = config.PATH
  config.PATH = cl.tmpPath()
  cl.reset()
  local ok, err = pcall(fn)
  os.remove(config.PATH)
  config.PATH = original
  if not ok then error(err, 2) end
end

h.describe("config.load (file missing)", function()

  h.it("returns DEFAULT and no warnings", function()
    withTmpPath(function()
      local cfg, warns, bytes = config.load()
      h.eq(cfg.schemaVersion, 1)
      h.eq(cfg.enabled, true)
      h.eq(cfg.syncMode, "automatic")
      h.eq(#warns, 0)
      h.eq(bytes, nil, "no bytes returned when file missing")
    end)
  end)

  h.it("does NOT create the file as a side effect", function()
    withTmpPath(function()
      config.load()
      local f = io.open(config.PATH, "rb")
      h.eq(f, nil, "load() must not seed a file")
      if f then f:close() end
    end)
  end)

end)

h.describe("config.save then config.load", function()

  h.it("round-trips a configured spoon state", function()
    withTmpPath(function()
      local original = {
        schemaVersion = 1,
        enabled = false,
        syncMode = "manual",
        groupOf = { ["1"] = "A", ["2"] = "A", ["4"] = "B" },
        groupLabels = { A = "Code" },
        spaceNames = { A = { ["1"] = "Notes", ["2"] = "Email" } },
        switchDelay = 0.5,
        debounceSeconds = 1.0,
        popupDuration = 3,
        statusDuration = 4,
        hotkeys = {
          syncNow = { mods = {"ctrl", "alt", "cmd"}, key = "S" },
          openSettings = { mods = {"ctrl", "alt", "cmd"}, key = "," },
        },
      }
      h.istrue(config.save(original))

      local loaded, warns = config.load()
      h.eq(#warns, 0)
      h.eq(loaded.enabled, false)
      h.eq(loaded.syncMode, "manual")
      h.eq(loaded.groupOf["1"], "A")
      h.eq(loaded.groupOf["4"], "B")
      h.eq(loaded.groupLabels["A"], "Code")
      h.eq(loaded.spaceNames["A"]["1"], "Notes")
      h.eq(loaded.switchDelay, 0.5)
      h.eq(loaded.popupDuration, 3)
      h.eq(loaded.hotkeys.syncNow.key, "S")
      h.eq(loaded.hotkeys.openSettings.key, ",")
    end)
  end)

end)

h.describe("config.save echo suppression", function()

  h.it("pushes the SHA-256 of written bytes onto the ring", function()
    withTmpPath(function()
      config.save({ schemaVersion = 1, enabled = true })
      local snap = config._ringSnapshot()
      h.eq(#snap, 1)
      -- Sanity: that hash is what we'd compute from the encoded form.
      h.istrue(config._ringContains(snap[1]))
    end)
  end)

  h.it("multiple saves grow the ring up to RING_SIZE", function()
    withTmpPath(function()
      for i = 1, config.RING_SIZE + 2 do
        config.save({ schemaVersion = 1, popupDuration = i })
      end
      h.eq(#config._ringSnapshot(), config.RING_SIZE)
    end)
  end)

end)

h.describe("config.writeLastSeen / clearLastSeen", function()

  h.it("writeLastSeen sets a sparse _lastSeen entry", function()
    withTmpPath(function()
      config.save({ schemaVersion = 1, enabled = true })
      config.writeLastSeen(5, {
        name = "LG SDQHD #5",
        uuid = "abc-123",
        date = "2026-04-12",
        wasIn = "A",
      })
      local cfg = config.load()
      h.eq(cfg._lastSeen["5"].name, "LG SDQHD #5")
      h.eq(cfg._lastSeen["5"].wasIn, "A")
    end)
  end)

  h.it("clearLastSeen drops the entry on reconnect", function()
    withTmpPath(function()
      config.save({
        schemaVersion = 1,
        _lastSeen = { ["5"] = { name = "x", uuid = "y", date = "z", wasIn = "A" } },
      })
      config.clearLastSeen(5)
      local cfg = config.load()
      h.eq(cfg._lastSeen["5"], nil)
    end)
  end)

  h.it("clearLastSeen is a no-op when no entry exists", function()
    withTmpPath(function()
      config.save({ schemaVersion = 1 })
      config.clearLastSeen(99)  -- no entry
      local cfg = config.load()
      h.tableq(cfg._lastSeen, {})
    end)
  end)

end)

h.describe("config.startWatcher / stopWatcher lifecycle", function()

  h.it("startWatcher registers a pathwatcher on the parent dir", function()
    cl.reset()
    if hs.pathwatcher and hs.pathwatcher._reset then hs.pathwatcher._reset() end
    config.startWatcher(function() end)
    if hs.pathwatcher and hs.pathwatcher._registered then
      local registered = hs.pathwatcher._registered()
      h.eq(#registered, 1, "exactly one watcher registered")
      -- The dir should be the parent of PATH.
      local parent = config.PATH:match("(.+)/[^/]+$")
      h.eq(registered[1]._dir, parent)
      h.istrue(registered[1]._running)
    end
    config.stopWatcher()
  end)

  h.it("startWatcher is idempotent (second call is a no-op)", function()
    cl.reset()
    if hs.pathwatcher and hs.pathwatcher._reset then hs.pathwatcher._reset() end
    config.startWatcher(function() end)
    config.startWatcher(function() end)  -- second call should not create a new watcher
    if hs.pathwatcher and hs.pathwatcher._registered then
      h.eq(#hs.pathwatcher._registered(), 1, "still exactly one watcher")
    end
    config.stopWatcher()
  end)

  h.it("stopWatcher stops the registered watcher", function()
    cl.reset()
    if hs.pathwatcher and hs.pathwatcher._reset then hs.pathwatcher._reset() end
    config.startWatcher(function() end)
    config.stopWatcher()
    if hs.pathwatcher and hs.pathwatcher._registered then
      local reg = hs.pathwatcher._registered()
      h.eq(#reg, 1)
      h.isfalse(reg[1]._running, "watcher marked stopped")
    end
  end)

  h.it("stopWatcher is safe to call without a prior startWatcher", function()
    cl.reset()
    -- Should not error.
    config.stopWatcher()
    config.stopWatcher()
  end)

end)

h.describe("config pathwatcher parse-retry counter", function()

  h.it("starts at 0", function()
    cl.reset()
    h.eq(config._getRetryCount(), 0)
  end)

  h.it("retry counter bumps on parse failure and caps at PARSE_RETRY_MAX", function()
    withTmpPath(function()
      -- Write garbage that the JSON stub will fail to decode.
      local f = io.open(config.PATH, "wb")
      f:write("this is not valid lua-return source")
      f:close()

      -- Each handleEvent call should bump the retry counter (it'll fail
      -- to parse and reschedule). Capture the retry count after each call.
      config._setRetryCount(0)
      config._handleEvent()
      h.eq(config._getRetryCount(), 1)
      config._handleEvent()
      h.eq(config._getRetryCount(), 2)
      config._handleEvent()
      h.eq(config._getRetryCount(), 3)
      -- 4th attempt resets after the cap is hit.
      config._handleEvent()
      h.eq(config._getRetryCount(), 0, "resets to 0 after exhausting retries")
    end)
  end)

  h.it("self-write echo is ignored and does not bump retry counter", function()
    withTmpPath(function()
      cl.reset()
      config.save({ schemaVersion = 1, enabled = true })
      -- After save, the SHA is in the ring. A pathwatcher fire reading
      -- the same bytes should be classified as echo and ignored.
      config._handleEvent()
      h.eq(config._getRetryCount(), 0, "no parse attempt triggered")
    end)
  end)

end)
