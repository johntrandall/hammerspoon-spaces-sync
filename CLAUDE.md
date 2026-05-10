# macos-spaces-multimonitor-sync-hammerspoon

Hammerspoon Spoon that synchronizes macOS Spaces across monitors in configurable sync groups.

## Before You Start

**Read `dev-docs/hammerspoon-and-spaces-quirks.md` first.** It documents critical `hs.spaces` behaviors (async gotoSpace, dropped rapid calls, watcher loops, lazy load timing) that are not obvious from the API docs and caused real bugs during development.

## Current state — v0.3 (verify-based)

v0.3 shipped (tag `v0.3`, commit `af5097e`). It replaced v0.2's
fixed-`switchDelay`/`debounceSeconds` timing with poll-based
verification per F-010. The original design package below remains as
historical reference:

- `dev-docs/v3-implementation-handoff.md` — implementation handoff (now archival)
- `dev-docs/code-changes-pending.md` — catalog of changes (all v3 items implemented; P3 ✅ done)
- `dev-docs/diagrams/workflow-roadmap.mermaid` — runtime flow diagram
- `dev-docs/findings/F-010-polling-model-a-vs-b.md` — empirical basis for the verify-based design
- `dev-docs/v3-vs-settings-track-harmonization.md` — interaction with the parallel settings/config GUI track

## Testing strategy

See `dev-docs/test-strategy.md` for the project's testing levels
(L0/L1/L3/L6 active; L2/L4/L5/L7/L8 not active or deferred), gating
defaults, and operational notes (`hs -c` runloop blocking, `hs.ipc`
recursion recovery). Tests live in `tests/`.

Quick reference (full table in `tests/run.sh --help`):

```bash
tests/run.sh                    # default — L0 + L3 (safe; HS must be running)
tests/run.sh L1                 # pure-Lua unit tests (no HS needed)
tests/run.sh L3_inclusive       # L0 + L1 + L3 — pre-commit equivalent
SPACESSYNC_L6=1 tests/run.sh L6_inclusive
                                # L0 + L1 + L3 + L6 — pre-release; switches Spaces ~10s
```

The `SPACESSYNC_L6=1` gate is enforced once in `tests/run.sh` (Deviations §5).

## Project Structure

- `Source/SpacesSync.spoon/init.lua` — the Spoon (symlinked into `~/.hammerspoon/Spoons/`)
- `Source/SpacesSync.spoon/docs.json` — generated documentation
- `install.sh` — symlinks the Spoon into Hammerspoon
- `configure-macos.sh` — checks/sets required macOS Mission Control settings
- `dev-docs/` — development notes, quirks, settings analysis, publication checklist

## Available Documentation MCPs

- **Context7** and **Dash** MCP servers have Lua and Hammerspoon docs available. Use these for API reference lookups rather than web searches.

## Testing

See `dev-docs/test-strategy.md` for the full strategy (L0/L1/L3/L6 active; canonical sources, gating, operational notes) and `## Testing strategy` above for the quick-reference command table. For interactive debugging: set logger to debug level (`spoon.SpacesSync.logger.setLogLevel('debug')`) and watch the Hammerspoon console.

## Publishing

See `dev-docs/publication-checklist.md` before releasing a new version.
