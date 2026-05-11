-- L1 — config.lua SHA-256 hashing + echo-suppression ring buffer

local h = require("helpers")
local cl = require("config_loader")
local config = cl.config

h.describe("config._sha256 (stubbed in L1)", function()

  h.it("is deterministic", function()
    h.eq(config._sha256("hello"), config._sha256("hello"))
  end)

  h.it("differs across distinct inputs", function()
    h.neq(config._sha256("hello"), config._sha256("world"))
    h.neq(config._sha256(""), config._sha256(" "))
  end)

  h.it("handles empty string", function()
    local v = config._sha256("")
    h.eq(type(v), "string")
    h.istrue(#v > 0)
  end)

end)

h.describe("config ring buffer", function()

  local function reset() config._ringReset() end

  h.it("starts empty", function()
    reset()
    h.tableq(config._ringSnapshot(), {})
    h.isfalse(config._ringContains("anything"))
  end)

  h.it("push then contains returns true for that hash", function()
    reset()
    config._ringPush("h1")
    h.istrue(config._ringContains("h1"))
    h.isfalse(config._ringContains("h2"))
  end)

  h.it("most-recent-first order", function()
    reset()
    config._ringPush("h1")
    config._ringPush("h2")
    config._ringPush("h3")
    h.tableq(config._ringSnapshot(), {"h3", "h2", "h1"})
  end)

  h.it("caps at RING_SIZE entries (evicts oldest)", function()
    reset()
    for i = 1, config.RING_SIZE + 3 do
      config._ringPush("h" .. i)
    end
    local snap = config._ringSnapshot()
    h.eq(#snap, config.RING_SIZE)
    -- Oldest hashes evicted; newest preserved.
    h.isfalse(config._ringContains("h1"))
    h.isfalse(config._ringContains("h2"))
    h.isfalse(config._ringContains("h3"))
    h.istrue(config._ringContains("h" .. (config.RING_SIZE + 3)))
  end)

end)
