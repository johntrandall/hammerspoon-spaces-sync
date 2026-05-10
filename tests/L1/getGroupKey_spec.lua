-- L1 — getGroupKey
--
-- Module-state-dependent helper at Source/SpacesSync.spoon/init.lua:362-392.
-- Returns the canonical sync-group key for the display at `uuid`:
--   * For displays in a sync group: sorted positions, comma-joined
--     (e.g. "2,3,4" for {3, 2, 4}).
--   * For displays not in any group: tostring(position) (e.g. "1").
--   * For uuids not in the position map: nil.
--
-- Reads: uuidToPosition (local), obj.syncGroups (obj.* table).
-- Setup: loader.set_position_state(p2u, u2p, total) seeds the locals;
--        loader.obj.syncGroups assigns the syncGroups table.

local h = require("helpers")
local loader = require("loader")
local fn = loader.helpers.getGroupKey
local obj = loader.obj

-- Test fixtures: 4 fake displays at positions 1-4.
local function fixture4()
  local p2u = { "uuid-1", "uuid-2", "uuid-3", "uuid-4" }
  local u2p = { ["uuid-1"] = 1, ["uuid-2"] = 2, ["uuid-3"] = 3, ["uuid-4"] = 4 }
  loader.set_position_state(p2u, u2p, 4)
end

h.describe("getGroupKey", function()

  h.it("uuid not in position map -> nil", function()
    fixture4()
    obj.syncGroups = { { 1, 2 } }
    h.eq(fn("uuid-not-here"), nil)
  end)

  h.it("display in sync group -> sorted comma-joined positions", function()
    fixture4()
    obj.syncGroups = { { 2, 3, 4 } }
    h.eq(fn("uuid-2"), "2,3,4")
    h.eq(fn("uuid-3"), "2,3,4")
    h.eq(fn("uuid-4"), "2,3,4")
  end)

  h.it("group positions sort numerically before joining", function()
    fixture4()
    obj.syncGroups = { { 4, 2, 3 } }
    -- Even though the group is declared in {4,2,3} order, the key
    -- is the SORTED form. This guarantees deterministic keys
    -- regardless of how the user wrote the group.
    h.eq(fn("uuid-2"), "2,3,4")
    h.eq(fn("uuid-4"), "2,3,4")
  end)

  h.it("two-display group -> 'pos1,pos2'", function()
    fixture4()
    obj.syncGroups = { { 1, 2 } }
    h.eq(fn("uuid-1"), "1,2")
    h.eq(fn("uuid-2"), "1,2")
  end)

  h.it("display not in any group -> implicit group-of-one (tostring(pos))", function()
    fixture4()
    obj.syncGroups = { { 2, 3 } }
    h.eq(fn("uuid-1"), "1", "pos 1 is independent")
    h.eq(fn("uuid-4"), "4", "pos 4 is independent")
    -- And in-group displays still get the group key
    h.eq(fn("uuid-2"), "2,3")
  end)

  h.it("multiple groups: uses the first group containing the position", function()
    fixture4()
    -- Defining the same position in two groups is malformed but should
    -- not crash; the function uses the FIRST group it finds via
    -- `for _, group in ipairs(obj.syncGroups)`.
    obj.syncGroups = { { 1, 2 }, { 2, 3 } }
    h.eq(fn("uuid-2"), "1,2", "first matching group wins")
    h.eq(fn("uuid-3"), "2,3")
  end)

  h.it("non-numeric entries in a group are filtered", function()
    fixture4()
    -- The implementation only includes entries where type(p) == "number"
    -- when building the sorted list. So a malformed group like
    -- {"foo", 2, 3} would yield "2,3" not "foo,2,3".
    obj.syncGroups = { { "foo", 2, 3 } }
    h.eq(fn("uuid-2"), "2,3", "non-numeric entries filtered out of key")
  end)

  h.it("non-table syncGroups -> falls through to implicit group-of-one", function()
    fixture4()
    obj.syncGroups = nil
    h.eq(fn("uuid-2"), "2", "with nil syncGroups, every display is implicit-of-one")
    -- Restore for other tests
    obj.syncGroups = { { 1, 2 } }
  end)

  h.it("non-table individual group entry -> skipped, falls through", function()
    fixture4()
    obj.syncGroups = { "not-a-group", { 2, 3 } }
    -- The "not-a-group" string is skipped via type(group) == "table" guard;
    -- the {2,3} entry is found.
    h.eq(fn("uuid-2"), "2,3")
    -- A display not covered by any well-formed group is implicit-of-one.
    h.eq(fn("uuid-1"), "1")
  end)

end)
