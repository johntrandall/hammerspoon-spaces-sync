# Spaces Sync

Hammerspoon module that keeps macOS Spaces synchronized across monitors. When you switch Spaces on one synced monitor, the others follow in lockstep.

## Setup

- Two LG monitors are synced by index (Desktop 3 left = Desktop 3 right)
- Geminos-T monitor stays independent
- Configurable via pattern matching on monitor names

## Usage

**Toggle:** `Ctrl+Alt+Cmd+Y` (starts disabled)

Also available in the Hammerspoon automations menu (the menubar icon).

## Install

```bash
./install.sh
```

Symlinks `spaces-sync.lua` into `~/.hammerspoon/`. The automations menu loads it via `require("spaces-sync")`.

## How It Works

Watches `hs.spaces.watcher` for space changes. When a synced display changes spaces, it calls `hs.spaces.gotoSpace()` on the partner display at the matching index. A 0.8s debounce prevents sync loops.

## Configuration

Edit the config table at the top of `spaces-sync.lua`:

- `syncedMonitorPatterns` — monitor names to keep in lockstep (default: `{"LG"}`)
- `independentMonitorPatterns` — monitor names to leave alone (default: `{"Geminos"}`)
- `debounceSeconds` — loop prevention delay (default: `0.8`)
