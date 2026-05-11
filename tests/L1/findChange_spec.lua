-- L1 — findChange
--
-- Pure-ish helper at Source/SpacesSync.spoon/init.lua:1293. Compares
-- currentSpaces (UUID → SpaceID map) against lastActiveSpaces, returns
-- (changedUUID, changedSpaceID, newIndex) for the FIRST display whose
-- Space changed. Returns nil if no change. Multi-display change → only
-- the first one returned (Lua pairs order is not deterministic, but
-- the assertion holds: ONE of the changed displays is returned).
--
-- Touches hs.spaces.spacesForScreen via getSpaceIndex (for newIndex
-- computation). We seed the L1 stub's per-screen-spaces map so
-- getSpaceIndex returns real numbers; tests verify newIndex matches.

local h = require("helpers")
local loader = require("loader")
local fn = loader.helpers.findChange

local function reset_spaces()
  hs.spaces._test_reset()
  hs.screen._test_reset()
end

-- Seed both the screen registry (so hs.screen.find returns a usable
-- object) AND the per-screen-spaces map (so spacesForScreen returns
-- the list).
local function seed_screen(uuid, sids)
  hs.screen._test_seed_screen(uuid)
  hs.spaces._test_seed(uuid, sids)
end

h.describe("findChange", function()

  h.it("empty currentSpaces -> nil", function()
    reset_spaces()
    local u, s, i = fn({}, { ["uuid-A"] = "sid-A1" })
    h.eq(u, nil)
    h.eq(s, nil)
    h.eq(i, nil)
  end)

  h.it("no changes -> nil", function()
    reset_spaces()
    local u, s, i = fn(
      { ["uuid-A"] = "sid-A1", ["uuid-B"] = "sid-B1" },
      { ["uuid-A"] = "sid-A1", ["uuid-B"] = "sid-B1" }
    )
    h.eq(u, nil); h.eq(s, nil); h.eq(i, nil)
  end)

  h.it("one display changed -> returns that uuid + new sid + new idx", function()
    reset_spaces()
    seed_screen("uuid-A", { "sid-A1", "sid-A2", "sid-A3" })
    local u, s, i = fn(
      { ["uuid-A"] = "sid-A2" },
      { ["uuid-A"] = "sid-A1" }
    )
    h.eq(u, "uuid-A")
    h.eq(s, "sid-A2")
    h.eq(i, 2, "idx should be the index of sid-A2 in spacesForScreen(uuid-A)")
  end)

  h.it("multiple displays changed -> returns ONE of them (any is acceptable)", function()
    reset_spaces()
    seed_screen("uuid-A", { "sid-A1", "sid-A2" })
    seed_screen("uuid-B", { "sid-B1", "sid-B2" })
    local u, s, i = fn(
      { ["uuid-A"] = "sid-A2", ["uuid-B"] = "sid-B2" },
      { ["uuid-A"] = "sid-A1", ["uuid-B"] = "sid-B1" }
    )
    -- pairs() iteration order is not guaranteed; assert the returned
    -- triple is one of the two valid options.
    local valid =
      (u == "uuid-A" and s == "sid-A2" and i == 2) or
      (u == "uuid-B" and s == "sid-B2" and i == 2)
    h.istrue(valid, "expected uuid-A/sid-A2/2 or uuid-B/sid-B2/2, got " ..
            tostring(u) .. "/" .. tostring(s) .. "/" .. tostring(i))
  end)

  h.it("lastActiveSpaces missing the changed uuid -> not flagged", function()
    reset_spaces()
    seed_screen("uuid-A", { "sid-A1" })
    -- uuid-A is in currentSpaces but NOT in lastActiveSpaces (e.g.
    -- the display was just plugged in). findChange should NOT
    -- flag this — there's no prior state to diff against.
    local u, s, i = fn(
      { ["uuid-A"] = "sid-A1" },
      {}  -- empty lastActiveSpaces
    )
    h.eq(u, nil); h.eq(s, nil); h.eq(i, nil)
  end)

  h.it("display removed from currentSpaces -> not flagged", function()
    reset_spaces()
    seed_screen("uuid-A", { "sid-A1" })
    -- lastActiveSpaces has uuid-A; currentSpaces does NOT. The
    -- display was unplugged. findChange iterates currentSpaces, so
    -- uuid-A isn't even considered. Returns nil.
    local u, s, i = fn(
      {},  -- empty currentSpaces
      { ["uuid-A"] = "sid-A1" }
    )
    h.eq(u, nil); h.eq(s, nil); h.eq(i, nil)
  end)

  h.it("changed to a sid not in spacesForScreen -> newIndex defaults to '?'", function()
    reset_spaces()
    seed_screen("uuid-A", { "sid-A1", "sid-A2" })
    -- Current sid sid-A99 isn't in the seeded space list. getSpaceIndex
    -- returns nil; findChange replaces nil with "?".
    local u, s, i = fn(
      { ["uuid-A"] = "sid-A99" },
      { ["uuid-A"] = "sid-A1" }
    )
    h.eq(u, "uuid-A")
    h.eq(s, "sid-A99")
    h.eq(i, "?", "unknown sid -> newIndex = '?'")
  end)

  h.it("change between two known sids preserves type (number)", function()
    reset_spaces()
    seed_screen("uuid-A", { "sid-A1", "sid-A2", "sid-A3", "sid-A4" })
    local _, _, i = fn(
      { ["uuid-A"] = "sid-A4" },
      { ["uuid-A"] = "sid-A2" }
    )
    h.eq(i, 4)
    h.eq(type(i), "number")
  end)

end)
