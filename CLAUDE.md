# macos-spaces-multimonitor-sync-hammerspoon

Hammerspoon Spoon that synchronizes macOS Spaces across monitors in configurable sync groups.

## Before You Start

**Read `dev-docs/hammerspoon-and-spaces-quirks.md` first.** It documents critical `hs.spaces` behaviors (async gotoSpace, dropped rapid calls, watcher loops, lazy load timing) that are not obvious from the API docs and caused real bugs during development.

## Project Structure

- `Source/SpacesSync.spoon/init.lua` — the Spoon (symlinked into `~/.hammerspoon/Spoons/`)
- `Source/SpacesSync.spoon/docs.json` — generated documentation
- `install.sh` — symlinks the Spoon into Hammerspoon
- `configure-macos.sh` — checks/sets required macOS Mission Control settings
- `dev-docs/` — development notes, quirks, settings analysis, publication checklist

## Available Documentation MCPs

- **Context7** and **Dash** MCP servers have Lua and Hammerspoon docs available. Use these for API reference lookups rather than web searches.

## Testing

No automated tests. Testing requires a multi-monitor Mac — `hs.spaces.gotoSpace()` needs real displays. Set logger to debug level (`spoon.SpacesSync.logger.setLogLevel('debug')`) and watch the Hammerspoon console.

## Publishing

See `dev-docs/publication-checklist.md` before releasing a new version.
