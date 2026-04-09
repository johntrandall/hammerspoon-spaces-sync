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

| Option | Default | Description |
|---|---|---|
| `syncGroups` | `{ {1, 2} }` | List of sync groups. Each group is a list of monitor position numbers. |
| `hotkey` | `{ {"ctrl","alt","cmd"}, "Y" }` | Hotkey to toggle sync. Set to `false` to disable. |
| `switchDelay` | `0.3` | Seconds between each `gotoSpace` call. |
| `debounceSeconds` | `0.8` | Seconds after sync before watcher re-enables. |
| `debug` | `false` | Log to Hammerspoon console. |

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

- macOS Sequoia 15+ (tested on 15.5; YMMV on other 15.x releases — `hs.spaces` uses private APIs that can break between point releases)
- Hammerspoon 1.0.0+
- Accessibility permissions for Hammerspoon

## License

MIT
