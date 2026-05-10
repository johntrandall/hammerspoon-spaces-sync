-- L1 — getTargetsFor
--
-- Module-state-dependent helper at Source/SpacesSync.spoon/init.lua:278-303.
-- Given the UUID of a triggering display, returns the list of OTHER
-- displays' UUIDs in the same sync group. Returns nil if the trigger
-- is not in any sync group.
--
-- Behaviors:
--   * Trigger uuid not in position map      -> nil
--   * Trigger position not in any group     -> nil
--   * Trigger in group of one (just itself) -> {} (empty list)
--   * Group references a position that has no UUID assigned
--     (display not connected) -> WARNS via obj.logger.w; the missing
--     position is silently dropped from the returned list.

local h = require("helpers")
local loader = require("loader")
local fn = loader.helpers.getTargetsFor
local obj = loader.obj

local function fixture4()
  local p2u = { "uuid-1", "uuid-2", "uuid-3", "uuid-4" }
  local u2p = { ["uuid-1"] = 1, ["uuid-2"] = 2, ["uuid-3"] = 3, ["uuid-4"] = 4 }
  loader.set_position_state(p2u, u2p, 4)
end

h.describe("getTargetsFor", function()

  h.it("uuid not in position map -> nil", function()
    fixture4()
    obj.syncGroups = { { 1, 2 } }
    h.eq(fn("uuid-not-here"), nil)
  end)

  h.it("trigger not in any sync group -> nil", function()
    fixture4()
    obj.syncGroups = { { 2, 3 } }
    h.eq(fn("uuid-1"), nil, "pos 1 not in any group")
    h.eq(fn("uuid-4"), nil, "pos 4 not in any group")
  end)

  h.it("trigger in two-display group -> [other display's uuid]", function()
    fixture4()
    obj.syncGroups = { { 2, 3 } }
    h.tableq(fn("uuid-2"), { "uuid-3" })
    h.tableq(fn("uuid-3"), { "uuid-2" })
  end)

  h.it("trigger in three-display group -> two other uuids in group order", function()
    fixture4()
    obj.syncGroups = { { 1, 2, 3 } }
    -- The implementation iterates the group in declared order and
    -- skips the trigger position. So for trigger=2, the result is
    -- {uuid-1, uuid-3}.
    h.tableq(fn("uuid-2"), { "uuid-1", "uuid-3" })
    h.tableq(fn("uuid-1"), { "uuid-2", "uuid-3" })
    h.tableq(fn("uuid-3"), { "uuid-1", "uuid-2" })
  end)

  h.it("trigger in four-display group -> three other uuids", function()
    fixture4()
    obj.syncGroups = { { 1, 2, 3, 4 } }
    h.tableq(fn("uuid-1"), { "uuid-2", "uuid-3", "uuid-4" })
    h.tableq(fn("uuid-3"), { "uuid-1", "uuid-2", "uuid-4" })
  end)

  h.it("group of one (just trigger) -> empty list", function()
    fixture4()
    obj.syncGroups = { { 2 } }
    h.tableq(fn("uuid-2"), {})
  end)

  h.it("group references a position with no UUID -> dropped from result", function()
    -- Only 2 displays connected; group declares pos 5.
    local p2u = { "uuid-1", "uuid-2" }
    local u2p = { ["uuid-1"] = 1, ["uuid-2"] = 2 }
    loader.set_position_state(p2u, u2p, 2)
    obj.syncGroups = { { 1, 2, 5 } }
    -- Pos 5 has no UUID; it's logged at warn level and skipped.
    h.tableq(fn("uuid-1"), { "uuid-2" })
    h.tableq(fn("uuid-2"), { "uuid-1" })
  end)

  h.it("multiple groups: uses the first group containing trigger position", function()
    fixture4()
    -- pos 2 in two groups (malformed config, but the function should
    -- not crash; first match wins per the loop's `return targets`
    -- as soon as it finds a group containing the trigger).
    obj.syncGroups = { { 1, 2 }, { 2, 3 } }
    h.tableq(fn("uuid-2"), { "uuid-1" }, "first matching group wins")
  end)

end)
