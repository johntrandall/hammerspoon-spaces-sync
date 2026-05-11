-- L1 — config.lua validate()

local h = require("helpers")
local cl = require("config_loader")
local config = cl.config

h.describe("config.validate", function()

  h.it("non-table input → defaults + warning", function()
    local out, warns = config.validate("not a table")
    h.eq(out.schemaVersion, 1)
    h.eq(out.enabled, true)
    h.eq(out.syncMode, "automatic")
    h.istrue(#warns >= 1)
  end)

  h.it("empty table → defaults, no warnings", function()
    local out, warns = config.validate({})
    h.eq(out.schemaVersion, 1)
    h.eq(out.enabled, true)
    h.eq(out.syncMode, "automatic")
    h.tableq(out.groupOf, {})
    h.eq(#warns, 0)
  end)

  h.it("schemaVersion mismatch → warn, keeps known fields", function()
    local out, warns = config.validate({
      schemaVersion = 99,
      enabled = false,
    })
    h.eq(out.schemaVersion, 99, "preserves user's schemaVersion verbatim")
    h.eq(out.enabled, false, "still picks up known field")
    -- Warning fired.
    local hasMismatchWarn = false
    for _, w in ipairs(warns) do
      if w:match("schemaVersion") then hasMismatchWarn = true end
    end
    h.istrue(hasMismatchWarn)
  end)

  h.it("syncMode coerces to 'automatic' if invalid string", function()
    local out, warns = config.validate({ syncMode = "auto" })
    h.eq(out.syncMode, "automatic")
    h.istrue(#warns >= 1)
  end)

  h.it("groupOf accepts valid (position, letter) pairs", function()
    local out = config.validate({
      groupOf = { ["1"] = "A", ["2"] = "A", ["4"] = "B" },
    })
    h.eq(out.groupOf["1"], "A")
    h.eq(out.groupOf["2"], "A")
    h.eq(out.groupOf["4"], "B")
  end)

  h.it("groupOf drops invalid letters with warnings", function()
    local out, warns = config.validate({
      groupOf = { ["1"] = "A", ["2"] = "Z", ["3"] = "a" },
    })
    h.eq(out.groupOf["1"], "A")
    h.eq(out.groupOf["2"], nil)
    h.eq(out.groupOf["3"], nil)
    h.istrue(#warns >= 2)
  end)

  h.it("groupLabels keeps non-empty strings for valid letters", function()
    local out = config.validate({
      groupLabels = { A = "Code", B = "", C = "Reference", Z = "Bad" },
    })
    h.eq(out.groupLabels["A"], "Code")
    h.eq(out.groupLabels["B"], nil, "empty string dropped")
    h.eq(out.groupLabels["C"], "Reference")
    h.eq(out.groupLabels["Z"], nil, "Z not in pool")
  end)

  h.it("spaceNames preserves (letter → index-string → name)", function()
    local out = config.validate({
      spaceNames = {
        A = { ["1"] = "Notes", ["2"] = "Email" },
        B = { ["1"] = "Browser" },
      },
    })
    h.eq(out.spaceNames["A"]["1"], "Notes")
    h.eq(out.spaceNames["A"]["2"], "Email")
    h.eq(out.spaceNames["B"]["1"], "Browser")
  end)

  h.it("spaceNames drops empty groups and empty names", function()
    local out = config.validate({
      spaceNames = {
        A = { ["1"] = "", ["2"] = "OK" },
        B = {},
      },
    })
    h.eq(out.spaceNames["A"]["1"], nil)
    h.eq(out.spaceNames["A"]["2"], "OK")
    h.eq(out.spaceNames["B"], nil, "empty group entry pruned")
  end)

  h.it("_lastSeen captures name/uuid/date/wasIn", function()
    local out = config.validate({
      _lastSeen = {
        ["5"] = { name = "LG", uuid = "abc-123", date = "2026-04-12", wasIn = "A" },
        ["6"] = { name = "Apple", uuid = "def-456", date = "2026-04-10" },  -- no wasIn
      },
    })
    h.eq(out._lastSeen["5"].name, "LG")
    h.eq(out._lastSeen["5"].wasIn, "A")
    h.eq(out._lastSeen["6"].name, "Apple")
    h.eq(out._lastSeen["6"].wasIn, nil, "wasIn omitted when no prior group")
  end)

  h.it("_lastSeen drops invalid wasIn letters", function()
    local out = config.validate({
      _lastSeen = {
        ["5"] = { name = "X", uuid = "y", date = "z", wasIn = "Q" },
      },
    })
    h.eq(out._lastSeen["5"].wasIn, nil)
  end)

  h.it("timing knobs reject non-positive numbers", function()
    local out, warns = config.validate({
      switchDelay = -1,
      debounceSeconds = 0,
      popupDuration = 2.5,
      statusDuration = "x",
    })
    h.eq(out.switchDelay, 0.3, "reset to default")
    h.eq(out.debounceSeconds, 0.8, "reset to default")
    h.eq(out.popupDuration, 2.5, "valid positive accepted")
    h.eq(out.statusDuration, 3, "non-number → default")
    h.istrue(#warns >= 3)
  end)

  h.it("hotkeys: partial user overrides merge over defaults", function()
    local out = config.validate({
      hotkeys = {
        toggle = { mods = {"ctrl", "shift"}, key = "T" },
      },
    })
    h.tableq(out.hotkeys.toggle.mods, {"ctrl", "shift"})
    h.eq(out.hotkeys.toggle.key, "T")
    -- Other defaults still present.
    h.eq(out.hotkeys.syncNow.key, "S")
    h.eq(out.hotkeys.openSettings.key, ",")
    h.eq(out.hotkeys.showNames.key, "N")
  end)

  h.it("hotkeys: malformed entry falls back to default with warning", function()
    local out, warns = config.validate({
      hotkeys = {
        toggle = { mods = "not a list" },  -- bad mods, missing key
      },
    })
    h.eq(out.hotkeys.toggle.key, "Y", "fell back to default")
    h.istrue(#warns >= 1)
  end)

  h.it("hotkeys: unknown modifiers are silently dropped", function()
    local out = config.validate({
      hotkeys = {
        syncNow = { mods = {"ctrl", "gibberish", "cmd"}, key = "S" },
      },
    })
    h.tableq(out.hotkeys.syncNow.mods, {"ctrl", "cmd"})
  end)

end)
