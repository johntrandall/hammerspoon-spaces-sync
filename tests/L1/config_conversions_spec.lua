-- L1 — config.lua conversions and displayName

local h = require("helpers")
local cl = require("config_loader")
local config = cl.config

h.describe("config.displayName", function()

  h.it("returns 'Group A' when no label", function()
    h.eq(config.displayName("A", {}), "Group A")
    h.eq(config.displayName("A", nil), "Group A")
    h.eq(config.displayName("B", { A = "Code" }), "Group B")
  end)

  h.it("returns 'A: Label' when labeled", function()
    h.eq(config.displayName("A", { A = "Code" }), "A: Code")
    h.eq(config.displayName("J", { J = "Reference" }), "J: Reference")
  end)

  h.it("falls back to default when label is empty string", function()
    h.eq(config.displayName("A", { A = "" }), "Group A")
  end)

  h.it("ignores letters outside the pool", function()
    -- Not crashy — returns tostring(letter) — but should never happen
    -- with valid input.
    h.eq(config.displayName("Z", {}), "Z")
  end)

end)

h.describe("config.groupOfToGroups", function()

  h.it("empty map → empty list", function()
    h.tableq(config.groupOfToGroups({}), {})
    h.tableq(config.groupOfToGroups(nil), {})
  end)

  h.it("single letter, multiple positions, alphabetical letter order", function()
    local groups = config.groupOfToGroups({ ["1"] = "A", ["2"] = "A" })
    h.tableq(groups, { {1, 2} })
  end)

  h.it("multiple letters emit in A..J order regardless of insertion order", function()
    local groups = config.groupOfToGroups({
      ["4"] = "B",
      ["1"] = "A",
      ["3"] = "A",
      ["7"] = "C",
    })
    h.tableq(groups, { {1, 3}, {4}, {7} })
  end)

  h.it("positions within each group are sorted ascending", function()
    local groups = config.groupOfToGroups({
      ["9"] = "A", ["2"] = "A", ["5"] = "A",
    })
    h.tableq(groups, { {2, 5, 9} })
  end)

  h.it("invalid letters are dropped", function()
    local groups = config.groupOfToGroups({
      ["1"] = "A", ["2"] = "Z", ["3"] = "a",  -- only A is valid
    })
    h.tableq(groups, { {1} })
  end)

  h.it("non-numeric position keys are dropped", function()
    local groups = config.groupOfToGroups({
      ["abc"] = "A", ["1"] = "A",
    })
    h.tableq(groups, { {1} })
  end)

end)

h.describe("config.groupsToGroupOf", function()

  h.it("empty list → empty map", function()
    h.tableq(config.groupsToGroupOf({}), {})
    h.tableq(config.groupsToGroupOf(nil), {})
  end)

  h.it("first-run seed: positional → letter, alpha order", function()
    local groupOf = config.groupsToGroupOf({ {1, 2}, {3, 4} })
    h.tableq(groupOf, { ["1"] = "A", ["2"] = "A", ["3"] = "B", ["4"] = "B" })
  end)

  h.it("truncates beyond pool of 10", function()
    local groups = {}
    for i = 1, 12 do groups[i] = { i + 100 } end  -- 12 groups, more than the pool
    local groupOf = config.groupsToGroupOf(groups)
    -- groups 11 and 12 should be dropped.
    h.eq(groupOf["110"], "J")
    h.eq(groupOf["111"], nil, "11th group truncated")
    h.eq(groupOf["112"], nil, "12th group truncated")
  end)

  h.it("ignores non-numeric or non-positive positions", function()
    local groupOf = config.groupsToGroupOf({ {1, "x", -3, 2.5, 4} })
    h.tableq(groupOf, { ["1"] = "A", ["4"] = "A" })
  end)

  h.it("round-trips through groupOfToGroups", function()
    local original = { {1, 2}, {4}, {6, 7, 8} }
    local groupOf = config.groupsToGroupOf(original)
    local roundtrip = config.groupOfToGroups(groupOf)
    h.tableq(roundtrip, original)
  end)

end)
