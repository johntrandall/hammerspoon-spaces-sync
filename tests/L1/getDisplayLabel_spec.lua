-- L1 — getDisplayLabel
--
-- Module-state-dependent helper at Source/SpacesSync.spoon/init.lua:264-272.
-- Composes a human-readable label for a display UUID:
--   "<screen name> [position N/totalScreens]"  (when uuid is in position map)
--   "<screen name>"                             (when uuid not in position map)
--   "<uuid:8>"                                  (when hs.screen.find(uuid) returns nil)
--
-- Reads: uuidToPosition (local), totalScreens (local).
-- Calls: hs.screen.find(uuid) — returns nil under our hs stub, exercising
--        the fallback path to uuid:sub(1, 8).
--
-- This means our L1 stub-based test can exercise the "unknown screen"
-- branch but NOT the "known screen with name" branch. Real-screen labels
-- are L3/L6 territory.

local h = require("helpers")
local loader = require("loader")
local fn = loader.helpers.getDisplayLabel

local function fixture4()
  local p2u = { "uuid-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "uuid-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                "uuid-cccccccc-cccc-cccc-cccc-cccccccccccc",
                "uuid-dddddddd-dddd-dddd-dddd-dddddddddddd" }
  local u2p = {
    [p2u[1]] = 1, [p2u[2]] = 2, [p2u[3]] = 3, [p2u[4]] = 4,
  }
  loader.set_position_state(p2u, u2p, 4)
  return p2u, u2p
end

h.describe("getDisplayLabel", function()

  h.it("known position + stub hs.screen.find returns nil -> 'uuid:8 [position N/total]'", function()
    local p2u = fixture4()
    -- Under the hs stub, hs.screen.find returns nil (no real screen),
    -- so name falls back to uuid:sub(1, 8). Format becomes:
    --   "<first-8-chars> [position N/total]"
    h.eq(fn(p2u[1]), "uuid-aaa [position 1/4]")
    h.eq(fn(p2u[2]), "uuid-bbb [position 2/4]")
    h.eq(fn(p2u[4]), "uuid-ddd [position 4/4]")
  end)

  h.it("uuid not in position map + stub -> 'uuid:8' (no position suffix)", function()
    fixture4()
    -- No `pos` lookup match -> the function returns just the name.
    h.eq(fn("uuid-zzzz-not-mapped"), "uuid-zzz")
  end)

  h.it("totalScreens reflected in label", function()
    -- Set up just one display, totalScreens=1
    local p2u = { "uuid-only-one-display" }
    local u2p = { [p2u[1]] = 1 }
    loader.set_position_state(p2u, u2p, 1)
    h.eq(fn(p2u[1]), "uuid-onl [position 1/1]")

    -- Now switch to 8 displays
    p2u = { "u1", "u2", "u3", "u4", "u5", "u6", "u7", "u8" }
    u2p = {}
    for i, uuid in ipairs(p2u) do u2p[uuid] = i end
    loader.set_position_state(p2u, u2p, 8)
    h.eq(fn(p2u[3]), "u3 [position 3/8]")
  end)

  h.it("short uuid (< 8 chars) -> truncation is no-op", function()
    local p2u = { "abc" }
    local u2p = { abc = 1 }
    loader.set_position_state(p2u, u2p, 1)
    -- string.sub("abc", 1, 8) == "abc" — uuid:sub doesn't pad.
    h.eq(fn("abc"), "abc [position 1/1]")
  end)

  h.it("empty position map -> position lookup fails -> returns name only", function()
    loader.set_position_state({}, {}, 0)
    h.eq(fn("any-uuid-here"), "any-uuid")
  end)

end)
