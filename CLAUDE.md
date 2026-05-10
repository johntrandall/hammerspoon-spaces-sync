# macos-spaces-multimonitor-sync-hammerspoon

Hammerspoon Spoon that synchronizes macOS Spaces across monitors in configurable sync groups.

## Before You Start

**Read `dev-docs/hammerspoon-and-spaces-quirks.md` first.** It documents critical `hs.spaces` behaviors (async gotoSpace, dropped rapid calls, watcher loops, lazy load timing) that are not obvious from the API docs and caused real bugs during development.

## Current work — v3 redesign

A v3 redesign is in progress (designed, not yet implemented). If you're picking up implementation work, start at **`dev-docs/v3-implementation-handoff.md`** — it orients a fresh agent and points at the design package in the right reading order.

The v3 design package:
- `dev-docs/v3-implementation-handoff.md` — entry point for implementers
- `dev-docs/code-changes-pending.md` — catalog of code changes (12 items, build order in 5 stages)
- `dev-docs/diagrams/workflow-roadmap.mermaid` — runtime flow diagram
- `dev-docs/findings/F-010-polling-model-a-vs-b.md` — empirical basis for the verify-based design
- `dev-docs/v3-vs-settings-track-harmonization.md` — interaction with the parallel settings/config GUI track

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
