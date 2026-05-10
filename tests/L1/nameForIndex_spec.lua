-- L1 — nameForIndex
--
-- Module-state-dependent helper at Source/SpacesSync.spoon/init.lua:472.
-- Looks up the user-visible name for `(uuid, index)`:
--   * Returns (name, false) if a stored name exists for that
--     (groupKey, index) pair.
--   * Returns ("Space N", true) — i.e. "isUnnamed" — for every other
--     case: no stored name, empty string stored, no groupKey,
--     legacy flat schema in storage, etc.
--
-- Reads (transitively):
--   * uuidToPosition + obj.syncGroups via getGroupKey
--   * obj.spaceNames (populated from hs.settings on first call)
--   * SETTINGS_KEY constant + namesLoaded flag (file locals)
--
-- Per-fixture setup must:
--   1. Reset hs.settings (in-memory stub backing store).
--   2. Reset namesLoaded -> false (via loader.reset_names_loaded()).
--   3. Reset obj.spaceNames -> {} (the in-memory cache).
--   4. Seed positionToUUID / uuidToPosition / totalScreens.
--   5. Set obj.syncGroups.
--   6. (optional) hs.settings.set(SETTINGS_KEY, persisted_value) to
--      simulate a stored name table.

local h = require("helpers")
local loader = require("loader")
local fn = loader.helpers.nameForIndex
local obj = loader.obj

-- 2-display group fixture: positions 1 and 2 are uuid-1/uuid-2; both
-- are in sync group {1,2}; group key is "1,2". Position 3 is uuid-3,
-- not in any group, so its group key is "3".
local function fixture_2group()
  hs.settings._test_reset()
  loader.reset_names_loaded()
  for k in pairs(obj.spaceNames) do obj.spaceNames[k] = nil end
  loader.set_position_state(
    { "uuid-1", "uuid-2", "uuid-3" },
    { ["uuid-1"] = 1, ["uuid-2"] = 2, ["uuid-3"] = 3 },
    3
  )
  obj.syncGroups = { { 1, 2 } }
end

h.describe("nameForIndex", function()

  h.it("no persisted names, valid groupKey -> 'Space N', isUnnamed=true", function()
    fixture_2group()
    local name, isUnnamed = fn("uuid-1", 3)
    h.eq(name, "Space 3")
    h.istrue(isUnnamed)
  end)

  h.it("no persisted names, uuid not in position map -> 'Space N', isUnnamed=true", function()
    fixture_2group()
    -- uuid-not-here is not in uuidToPosition; getGroupKey returns nil.
    -- nameForIndex falls through to the default arm.
    local name, isUnnamed = fn("uuid-not-here", 1)
    h.eq(name, "Space 1")
    h.istrue(isUnnamed)
  end)

  h.it("persisted current schema, exact match -> stored name, isUnnamed=false", function()
    fixture_2group()
    -- Inner keys persisted as strings (the saveSpaceNames format);
    -- loadSpaceNames re-normalizes to numbers.
    hs.settings.set(loader.SETTINGS_KEY, {
      ["1,2"] = { ["1"] = "Work", ["2"] = "Email" },
    })
    local name, isUnnamed = fn("uuid-1", 1)
    h.eq(name, "Work")
    h.isfalse(isUnnamed)
    -- And the group's other display gets the same name (group-shared).
    name, isUnnamed = fn("uuid-2", 2)
    h.eq(name, "Email")
    h.isfalse(isUnnamed)
  end)

  h.it("persisted but no entry for this index -> 'Space N', isUnnamed=true", function()
    fixture_2group()
    hs.settings.set(loader.SETTINGS_KEY, {
      ["1,2"] = { ["1"] = "Work" },
    })
    -- idx 2 has no stored name for group "1,2"
    local name, isUnnamed = fn("uuid-1", 2)
    h.eq(name, "Space 2")
    h.istrue(isUnnamed)
  end)

  h.it("persisted empty string -> treated as unnamed", function()
    fixture_2group()
    hs.settings.set(loader.SETTINGS_KEY, {
      ["1,2"] = { ["1"] = "" },
    })
    local name, isUnnamed = fn("uuid-1", 1)
    h.eq(name, "Space 1", "empty string is not a valid stored name")
    h.istrue(isUnnamed)
  end)

  h.it("legacy flat schema discarded, returns 'Space N'", function()
    fixture_2group()
    -- Legacy flat schema: index (number) -> name (string), no group keys.
    -- isLegacyFlatSchema detects: all values are strings (or empty).
    hs.settings.set(loader.SETTINGS_KEY, {
      [1] = "Work",
      [2] = "Email",
    })
    local name, isUnnamed = fn("uuid-1", 1)
    -- Legacy detection discards the stored value entirely.
    h.eq(name, "Space 1")
    h.istrue(isUnnamed)
    -- And the storage was cleared as a side effect.
    h.eq(hs.settings.get(loader.SETTINGS_KEY), nil,
         "loadSpaceNames clears legacy storage as a side effect")
  end)

  h.it("non-table value in storage -> ignored, returns 'Space N'", function()
    fixture_2group()
    -- A scalar (or nil) where loadSpaceNames expected a table.
    hs.settings.set(loader.SETTINGS_KEY, "not a table")
    local name, isUnnamed = fn("uuid-1", 1)
    h.eq(name, "Space 1")
    h.istrue(isUnnamed)
  end)

  h.it("inner non-string values silently dropped during normalization", function()
    fixture_2group()
    hs.settings.set(loader.SETTINGS_KEY, {
      ["1,2"] = {
        ["1"] = "Work",
        ["2"] = 42,           -- not a string -> dropped
        ["3"] = "Email",
      },
    })
    h.eq((fn("uuid-1", 1)), "Work", "string entry preserved")
    h.eq((fn("uuid-1", 2)), "Space 2", "non-string entry dropped")
    h.eq((fn("uuid-1", 3)), "Email", "later string entry preserved")
  end)

  h.it("namesLoaded gate: second call does not re-read hs.settings", function()
    fixture_2group()
    hs.settings.set(loader.SETTINGS_KEY, {
      ["1,2"] = { ["1"] = "First" },
    })
    -- First call: loads from hs.settings, namesLoaded -> true.
    h.eq((fn("uuid-1", 1)), "First")
    -- Replace storage. If nameForIndex re-read, the next call would
    -- return "Replaced". The contract is that it does NOT re-read.
    hs.settings.set(loader.SETTINGS_KEY, {
      ["1,2"] = { ["1"] = "Replaced" },
    })
    h.eq((fn("uuid-1", 1)), "First",
         "namesLoaded prevents re-read; the in-memory cache wins")
  end)

  h.it("position not in any sync group: implicit group-of-one key (tostring(pos))", function()
    fixture_2group()
    hs.settings.set(loader.SETTINGS_KEY, {
      ["3"] = { ["1"] = "Solo" },  -- position 3 alone, key is "3"
    })
    local name, isUnnamed = fn("uuid-3", 1)
    h.eq(name, "Solo")
    h.isfalse(isUnnamed)
  end)

end)
