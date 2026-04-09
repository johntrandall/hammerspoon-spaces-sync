# Spaces Sync

Hammerspoon module that keeps macOS Spaces synchronized across monitors. When you switch Spaces on one monitor, the others in its sync group follow in lockstep.

## Install

```bash
git clone https://github.com/youruser/hammerspoon-macos-spaces-sync.git
cd hammerspoon-macos-spaces-sync
./install.sh
```

This symlinks `spaces-sync.lua` into `~/.hammerspoon/`.

Then add to `~/.hammerspoon/init.lua`:

```lua
local spacesSync = require("spaces-sync")
spacesSync.init()
```

## Configuration

Copy the example config:

```bash
cp spaces-sync-config.example.lua .spaces-sync-config.lua
```

Edit `.spaces-sync-config.lua` (gitignored) to match your setup:

```lua
return {
  syncGroups = {
    { 1, 2 },           -- monitors 1 and 2 sync together
    -- { 3, 4 },         -- a second independent pair
  },
  debug = true,          -- log to Hammerspoon console
}
```

If the config file is missing or empty, built-in defaults are used (`{1, 2}` synced, debug off).

You can also pass config directly:

```lua
spacesSync.init({
  syncGroups = { {1, 2, 3} },
  debug = true,
})
```

### Options

| Option            | Default                         | Description                                                                                                  |
| ----------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `syncGroups`      | `{ {1, 2} }`                    | List of sync groups. Each group is a list of monitor position numbers.                                       |
| `hotkey`          | `{ {"ctrl","alt","cmd"}, "Y" }` | Hotkey to toggle sync. Set to `false` to disable.                                                            |
| `switchDelay`     | `0.3`                           | Seconds between each `gotoSpace` call.                                                                       |
| `debounceSeconds` | `0.8`                           | Seconds after sync before watcher re-enables.                                                                |
| `debug`           | `false`                         | Verbose logging (watcher state dumps, per-call details). Normal mode still logs syncs, warnings, and errors. |
|                   |                                 |                                                                                                              |

### Position numbers

Monitors are assigned position numbers in reading order: left-to-right, then top-to-bottom as tiebreaker. On init, the module logs the map so you can verify:

```
[SpacesSync] Screens (4, reading order):
  pos 1: LG SDQHD (4) (x=0.0, y=25.0)
  pos 2: LG SDQHD (1) (x=2048.0, y=25.0)
  pos 3: LG SDQHD (3) (x=4096.0, y=25.0)
  pos 4: LG SDQHD (2) (x=6144.0, y=25.0)
```

### Space count mismatches

If the source monitor switches to space index 5 but a partner only has 3 spaces, that partner is skipped with a log message.

## Usage

**Toggle:** `Ctrl+Alt+Cmd+Y` (starts disabled)

Also available programmatically:

```lua
spacesSync.enable()
spacesSync.disable()
spacesSync.toggle()
spacesSync.isEnabled()
```

## How it works

1. `hs.spaces.watcher` detects a space change on any monitor
2. If that monitor is in a sync group, find the space index it switched to
3. For each partner in the group, call `hs.spaces.gotoSpace()` to switch to the same index
4. Switches are chained with a delay (macOS drops rapid back-to-back calls)
5. A debounce period prevents the watcher from reacting to its own switches

## Requirements

- macOS Sequoia 15.0+ (blocks activation on macOS 14 and earlier)
- Hammerspoon 1.1.1+ (warns on older versions)
- Accessibility permissions for Hammerspoon
- Two or more monitors with multiple Spaces configured

No external Spoons or plugins required. Uses only built-in Hammerspoon extensions (`hs.screen`, `hs.spaces`, `hs.application`, `hs.timer`).

## Compatibility

This module has been tested on **macOS 15.5 (Sequoia)** with **Hammerspoon 1.1.1** on a 4-monitor setup (4x LG SDQHD).

`hs.spaces` relies on private macOS APIs that Apple does not document or guarantee. These APIs can and do change between point releases. If you're running a different macOS version:

- **macOS 15.x (other than 15.5):** May work, may not. The module will load but warn you that your version is untested.
- **macOS 14 and earlier:** The module will refuse to enable and log an error. The `hs.spaces` APIs behave differently on older macOS versions.
- **macOS 16+:** Unknown. Test with `debug = true` and check the Hammerspoon console.

If you find it works (or breaks) on a different version, please open an issue or PR.

## Logging

All output goes to the Hammerspoon console (open via the menubar icon or `hs -c`).

- **Normal mode** (`debug = false`): logs syncs, skips, warnings, errors, version checks, and the position map on init. Enough to see what the module is doing.
- **Debug mode** (`debug = true`): adds watcher state dumps on every fire, per-target dispatch details, debounce lifecycle. Use when diagnosing race conditions or timing issues.

You can also tail logs from the terminal:

```bash
# Live tail
log stream --predicate 'process == "Hammerspoon"' | grep SpacesSync

# Recent history
/usr/bin/log show --last 5m --predicate 'process == "Hammerspoon"' | grep SpacesSync
```

## For AI agents

If you're an AI agent working on this codebase, read `CLAUDE.md` first — it points to `dev-docs/hammerspoon-quirks.md` which documents critical `hs.spaces` behaviors.

The `hs` CLI provides access to the Hammerspoon runtime from the terminal:

```bash
hs -c 'hs.reload()'
hs -c 'local ss = require("spaces-sync"); return "enabled=" .. tostring(ss.isEnabled())'
hs -c 'return hs.host.operatingSystemVersion()'
```

## Contributing

Contributions are welcome! This is a small project — open an issue or submit a PR.

Areas where help is especially useful:
- Testing on other macOS versions and reporting results
- Testing with non-standard monitor arrangements (vertical stacks, mixed resolutions)
- Automated testing strategies (mocking `hs.spaces` for unit tests)

## License

MIT
