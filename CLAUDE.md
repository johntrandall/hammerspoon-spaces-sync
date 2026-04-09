# macos-spaces-multimonitor-sync-hammerspoon

Hammerspoon module that synchronizes macOS Spaces across monitors in configurable sync groups.

## Before You Start

**Read `dev-docs/hammerspoon-and-spaces-quirks.md` first.** It documents critical `hs.spaces` behaviors (async gotoSpace, dropped rapid calls, watcher loops, lazy load timing) that are not obvious from the API docs and caused real bugs during development.

## Project Structure

- `spaces-sync.lua` — the module (symlinked into `~/.hammerspoon/`)
- `.spaces-sync-config.lua` — personal config (gitignored, loaded at runtime)
- `spaces-sync-config.example.lua` — config template for new users
- `dev-docs/` — development notes and quirks documentation

## Available Documentation MCPs

- **Context7** and **Dash** MCP servers have Lua and Hammerspoon docs available. Use these for API reference lookups rather than web searches.

## Testing

No automated tests yet. Testing requires a multi-monitor Mac — `hs.spaces.gotoSpace()` needs real displays. Toggle debug logging (`debug = true` in config) and watch the Hammerspoon console.
