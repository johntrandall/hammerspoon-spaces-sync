-- luacheck configuration for SpacesSync.
--
-- Loaded automatically by luacheck when run from the repo root.
-- See https://luacheck.readthedocs.io/en/stable/config.html

-- Disable the 120-char line-length warning. Several lines in init.lua
-- are intentionally long: user-visible log messages that read better
-- on one line, and table-literal initializers (positionMap entries,
-- sync-group registrations) that don't gain from wrapping. The check
-- itself is opinionated and not worth churning the source for.
max_line_length = false

-- Default globals — Hammerspoon injects these into the Spoon's
-- runtime. Without this list, luacheck would warn on every
-- reference. (The check-syntax.sh wrapper passes --no-global to
-- suppress these too, but listing them here makes the configuration
-- self-documenting and works for direct `luacheck` invocations.)
globals = {
  "hs",       -- Hammerspoon API root
  "spoon",    -- loaded-Spoons table
  "obj",      -- SpacesSync's Spoon object (self-reference at file scope)
}

-- Tests/L1 files use a different style — they're invoked through a
-- driver that requires modules via plain-Lua. Skip them; they have
-- their own pure-Lua harness conventions.
exclude_files = {
  "tests/L1/**",
  ".claude/**",
}
