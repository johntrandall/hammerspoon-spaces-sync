# Spaces Sync

Hammerspoon module that keeps macOS Spaces synchronized across monitors. When you switch Spaces on one monitor, the others in its sync group follow in lockstep.

## Usage

**Toggle:** `Ctrl+Alt+Cmd+Y` (starts disabled)

Also available in the Hammerspoon automations menu (the menubar icon).

## Install

```bash
./install.sh
```

Symlinks `spaces-sync.lua` into `~/.hammerspoon/`. The automations menu loads it via `require("spaces-sync")`.

Then add to `~/.hammerspoon/init.lua`:

```lua
local spacesSync = require("spaces-sync")
spacesSync.init()
```

## How It Works

Monitors are assigned position numbers in reading order (left-to-right, then top-to-bottom as tiebreaker). You define sync groups as sets of position numbers. When a monitor in a group switches spaces, all other monitors in that group switch to the matching space index.

Switches are chained with a configurable delay between each `hs.spaces.gotoSpace()` call (macOS drops rapid back-to-back calls). A debounce period after all switches prevents the watcher from reacting to its own changes.

## Configuration

Edit `M.config` at the top of `spaces-sync.lua`:

```lua
M.config = {
  -- Sync groups: each group is a list of monitor position numbers.
  -- Monitors not in any group are independent.
  syncGroups = {
    { 2, 3, 4 },         -- right three monitors sync together
  },

  -- Or two independent pairs:
  -- syncGroups = {
  --   { 1, 2 },
  --   { 3, 4 },
  -- },

  switchDelay = 0.3,      -- seconds between each gotoSpace call
  debounceSeconds = 0.8,  -- seconds after sync before watcher re-enables
  debug = true,           -- log to Hammerspoon console
}
```

### Position numbers

On init, the module logs the position map so you can see which physical monitor is which number:

```
[SpacesSync] Position map (4 screens, reading order):
  pos 1: LG SDQHD (4) [pos 1/4, x=0, y=25]
  pos 2: LG SDQHD (1) [pos 2/4, x=2048, y=25]
  pos 3: LG SDQHD (3) [pos 3/4, x=4096, y=25]
  pos 4: LG SDQHD (2) [pos 4/4, x=6144, y=25]
```

### Space count mismatches

If the source monitor switches to space index 5 but a partner only has 3 spaces, that partner is skipped with a log message. No error, no crash.

## Requirements

- macOS Sequoia 15+
- Hammerspoon 1.0.0+
- Accessibility permissions for Hammerspoon
