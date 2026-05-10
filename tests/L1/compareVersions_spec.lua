-- L1 — compareVersions
--
-- Pure-Lua helper at Source/SpacesSync.spoon/init.lua:66-79.
-- Returns -1, 0, or 1 for a < b / a == b / a > b respectively.
-- Parses runs of digits separated by any non-digit; missing components
-- are treated as 0.

local h = require("helpers")
local loader = require("loader")
local cv = loader.helpers.compareVersions

h.describe("compareVersions", function()

  h.it("equal numeric versions -> 0", function()
    h.eq(cv("1.2.3", "1.2.3"), 0)
    h.eq(cv("0.0.0", "0.0.0"), 0)
    h.eq(cv("15.7.5", "15.7.5"), 0)
  end)

  h.it("earlier major -> -1", function()
    h.eq(cv("1.0.0", "2.0.0"), -1)
    h.eq(cv("14.99.99", "15.0.0"), -1)
  end)

  h.it("later major -> 1", function()
    h.eq(cv("2.0.0", "1.0.0"), 1)
    h.eq(cv("16.0.0", "15.7.5"), 1)
  end)

  h.it("missing components default to 0", function()
    h.eq(cv("1", "1.0.0"), 0, "1 == 1.0.0")
    h.eq(cv("1.2", "1.2.0"), 0, "1.2 == 1.2.0")
    h.eq(cv("1.2.0", "1.2"), 0, "1.2.0 == 1.2")
    h.eq(cv("1", "1.0.1"), -1, "1 < 1.0.1")
    h.eq(cv("1.0.1", "1"), 1, "1.0.1 > 1")
  end)

  h.it("Hammerspoon-style versions parse cleanly", function()
    h.eq(cv("1.1.1", "1.1.1"), 0)
    h.eq(cv("1.1.1", "1.1.2"), -1)
    h.eq(cv("1.2.0", "1.1.99"), 1)
  end)

  h.it("non-digit separators are tolerated", function()
    -- Pattern is "(%d+)" — any non-digit acts as a separator
    h.eq(cv("1-2-3", "1.2.3"), 0)
    h.eq(cv("v1.2.3", "1.2.3"), 0, "leading 'v' is non-digit, ignored")
    h.eq(cv("1.2.3-rc1", "1.2.3"), 1, "1.2.3-rc1 parses as 1.2.3.1 > 1.2.3")
  end)

  h.it("non-string inputs are tostring'd", function()
    -- compareVersions does tostring(v):gmatch — so numbers and tables
    -- with __tostring work.
    h.eq(cv(15, 15), 0)
    h.eq(cv(15, 14), 1)
    h.eq(cv(14, 15), -1)
  end)

  h.it("empty strings parse as zero-component vectors", function()
    -- parts("") returns {}, parts("0") returns {0}; both compare equal
    -- via the va = pa[i] or 0 fallback.
    h.eq(cv("", ""), 0)
    h.eq(cv("", "0.0.0"), 0)
    h.eq(cv("0.0.0", ""), 0)
  end)

end)
