-- Copy this file to .spaces-sync-config.lua and edit to taste.
-- The dot-prefixed file is gitignored, so your personal config won't
-- be committed. Delete or empty it to use defaults.
--
-- Any values set here override the built-in defaults in spaces-sync.lua.
-- You only need to include the settings you want to change.

return {
  -- Sync groups: each is a list of monitor position numbers.
  -- Positions assigned in reading order (left-to-right, top-to-bottom).
  -- Monitors not in any group are independent.
  syncGroups = {
    { 1, 2 },         -- monitors 1 and 2 sync together
    -- { 3, 4 },       -- uncomment for a second pair
  },

  -- Hotkey to toggle sync on/off. Set to false to disable.
  -- hotkey = { {"ctrl", "alt", "cmd"}, "Y" },

  -- Delay between each space switch (seconds).
  -- switchDelay = 0.3,

  -- Debounce after all switches (seconds).
  -- debounceSeconds = 0.8,

  -- Log to Hammerspoon console.
  -- debug = false,
}
