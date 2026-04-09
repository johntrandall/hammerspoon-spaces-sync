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
  --
  -- Examples:
  --   { {1, 2} }               -- two monitors sync together
  --   { {1, 2}, {3, 4} }       -- two independent pairs
  --   { {1, 2, 3} }            -- three monitors sync together
  --   { {2, 3, 4} }            -- right three sync, leftmost independent
  syncGroups = {
    { 1, 2 },
  },

  -- Hotkey to toggle sync on/off. Set to false to disable.
  hotkey = { {"ctrl", "alt", "cmd"}, "Y" },

  -- Delay between each space switch (seconds).
  switchDelay = 0.3,

  -- Debounce after all switches (seconds).
  debounceSeconds = 0.8,

  -- Verbose debug logging (watcher dumps, per-target details).
  -- Normal mode still logs syncs, warnings, and errors.
  debug = false,
}
