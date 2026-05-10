-- L1 — isLegacyFlatSchema
--
-- Pure-Lua helper at Source/SpacesSync.spoon/init.lua:396-401.
-- Returns true if the stored value looks like the pre-group-key flat
-- schema (top-level values are strings, not nested tables). Used by
-- loadSpaceNames to decide whether to discard the stored data.

local h = require("helpers")
local loader = require("loader")
local fn = loader.helpers.isLegacyFlatSchema

h.describe("isLegacyFlatSchema", function()

  h.it("flat string-valued table -> true (legacy)", function()
    h.istrue(fn({ ["1"] = "Notes", ["2"] = "Music" }))
    h.istrue(fn({ ["1"] = "Notes" }))
  end)

  h.it("nested table-valued table -> false (current schema)", function()
    h.isfalse(fn({
      ["1"]     = { ["1"] = "Notes" },
      ["2,3"]   = { ["1"] = "Code" },
    }))
  end)

  h.it("empty table -> false (no values to inspect)", function()
    -- The function iterates pairs() looking for ANY string value.
    -- An empty table has no pairs, so returns false.
    h.isfalse(fn({}))
  end)

  h.it("mixed string + table values -> true (any string triggers)", function()
    -- The function returns true on the first string-valued entry it sees.
    -- Iteration order is unspecified, but ANY string present means at least
    -- one iteration could trip the check.
    h.istrue(fn({ ["1"] = "stringvalue", ["2"] = { foo = "bar" } }))
  end)

  h.it("number / boolean / nil values -> false", function()
    -- Only string values trigger legacy detection.
    h.isfalse(fn({ ["1"] = 42 }))
    h.isfalse(fn({ ["1"] = true }))
    -- Note: pairs skips nil values, so {["1"] = nil} is equivalent to {}.
  end)

end)
