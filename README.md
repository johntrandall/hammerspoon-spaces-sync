# SpacesSync

![SpacesSync](spaces-sync-hero.png)

A [Hammerspoon](https://www.hammerspoon.org/) Spoon that keeps macOS Spaces synchronized across monitors. When you switch Spaces on one monitor, the others in its sync group follow in lockstep.

Requires [Hammerspoon](https://www.hammerspoon.org/) — a macOS automation tool scripted in Lua.

> **Note:** This Spoon has been [submitted for inclusion](https://github.com/Hammerspoon/Spoons/pull/361) in the official [Hammerspoon Spoons repository](https://github.com/Hammerspoon/Spoons). Once merged, it will be installable via `SpoonInstall` and the [Spoons directory](http://www.hammerspoon.org/Spoons/).

## Install

### From source

```bash
git clone https://github.com/johntrandall/hammerspoon-spaces-sync.git
cd hammerspoon-spaces-sync
./install.sh
```

This symlinks `Source/SpacesSync.spoon` into `~/.hammerspoon/Spoons/`.

### Manual

Download `SpacesSync.spoon.zip`, unzip, and double-click — Hammerspoon auto-installs it to `~/.hammerspoon/Spoons/`.

### Then add to `~/.hammerspoon/init.lua`

```lua
hs.loadSpoon("SpacesSync")
spoon.SpacesSync.syncGroups = { {1, 2} }
spoon.SpacesSync:bindHotkeys({ toggle = {{"ctrl", "alt", "cmd"}, "Y"} })
spoon.SpacesSync:start()
```

## Configuration

Set properties on `spoon.SpacesSync` before calling `:start()`:

```lua
hs.loadSpoon("SpacesSync")

spoon.SpacesSync.syncGroups = {
  { 2, 3, 4 },    -- right three monitors sync together
}
spoon.SpacesSync.logger.setLogLevel('debug')  -- verbose logging

spoon.SpacesSync:bindHotkeys(spoon.SpacesSync.defaultHotkeys)
spoon.SpacesSync:start()
```

### Options

| Property          | Default      | Description                                                                                                  |
| ----------------- | ------------ | ------------------------------------------------------------------------------------------------------------ |
| `syncGroups`      | `{ {1, 2} }` | List of sync groups. Each group is a list of monitor position numbers.                                       |
| `switchDelay`     | `0.3`        | Seconds between each `gotoSpace` call.                                                                       |
| `debounceSeconds` | `0.8`        | Seconds after sync before watcher re-enables.                                                                |
| `logger`          | `hs.logger` at `info` | Logger object. Set level with `spoon.SpacesSync.logger.setLogLevel('debug')`.                         |

Hotkeys are configured via `:bindHotkeys()`:

```lua
spoon.SpacesSync:bindHotkeys({
  toggle = {{"ctrl", "alt", "cmd"}, "Y"},
})
```

### Position numbers

Monitors are assigned position numbers in reading order: left-to-right, then top-to-bottom as tiebreaker. On start, the Spoon logs the map so you can verify:

```
SpacesSync: Screens (4, reading order):
SpacesSync:   pos 1: LG SDQHD (4) [pos 1/4]
SpacesSync:   pos 2: LG SDQHD (1) [pos 2/4]
SpacesSync:   pos 3: LG SDQHD (3) [pos 3/4]
SpacesSync:   pos 4: LG SDQHD (2) [pos 4/4]
```

### Excluding monitors

Monitors not listed in any sync group are independent — they're never affected by sync. To exclude a monitor, simply leave its position number out of all groups.

For example, with 4 monitors and only the right three synced:

```lua
spoon.SpacesSync.syncGroups = {
  { 2, 3, 4 },  -- pos 1 is independent
}
```

### Space count mismatches

Monitors in a sync group don't need the same number of Spaces. If a target monitor doesn't have a Space at the triggering index, it's skipped with a log message.

## Usage

**Toggle:** via the hotkey you bind (starts disabled — call `:start()` to enable)

Also available programmatically:

```lua
spoon.SpacesSync:start()
spoon.SpacesSync:stop()
spoon.SpacesSync:toggle()
spoon.SpacesSync:isEnabled()
```

## How it works

1. `hs.spaces.watcher` detects a space change on any monitor
2. If that monitor is in a sync group, find the space index it switched to
3. For each target in the group, call `hs.spaces.gotoSpace()` to switch to the same index
4. Switches are chained with a delay (macOS drops rapid back-to-back calls)
5. A debounce period prevents the watcher from reacting to its own switches

For detailed notes on `hs.spaces` quirks and pitfalls, see [dev-docs/hammerspoon-and-spaces-quirks.md](dev-docs/hammerspoon-and-spaces-quirks.md).

## Requirements

- macOS Sequoia 15.0+ (blocks activation on macOS 14 and earlier)
- Hammerspoon 1.1.1+ (warns on older versions)
- Accessibility permissions for Hammerspoon
- Two or more monitors with multiple Spaces configured

No external Spoons or plugins required. Uses only built-in Hammerspoon extensions (`hs.screen`, `hs.spaces`, `hs.application`, `hs.timer`).

### Required macOS settings

In **System Settings > Desktop & Dock > Mission Control**:

| Setting | Value | Why |
|---|---|---|
| **Displays have separate Spaces** | **ON** (required) | If off, all monitors share one Space — nothing to sync. Requires logout to change. |

### Recommended macOS settings

| Setting | Value | Why |
|---|---|---|
| **Automatically rearrange Spaces based on most recent use** | OFF | If on, macOS reorders Space indices by recency, breaking index-based sync. |
| **When switching to an application, switch to a Space with open windows** | OFF | Cmd-Tab/Dock clicks auto-switch Spaces, which SpacesSync interprets as a user switch and syncs all targets. |
| **Stage Manager** | OFF | Untested interaction with SpacesSync. |

### Optional: Reduce motion

**System Settings > Accessibility > Display > Reduce motion** disables the Spaces sliding animation. This makes `gotoSpace()` complete faster, which can improve sync reliability — especially with 3+ monitors. The tradeoff is that Space transitions become an instant cut instead of a slide.

The Spoon checks the required and first recommended setting on start and warns if they're misconfigured.

A setup script is included to configure everything:

```bash
./configure-macos.sh
```

For the full analysis of every macOS setting that could affect sync, see [dev-docs/macos-spaces-settings.md](dev-docs/macos-spaces-settings.md).

## Compatibility

Tested on **macOS 15.5 (Sequoia)** with **Hammerspoon 1.1.1** on a 4-monitor setup (4x LG SDQHD).

> **macOS 16 (Tahoe):** Not tested. `hs.spaces` relies on private macOS APIs that Apple changes between major releases. SpacesSync should be assumed **not working on Tahoe** until someone tests and confirms. If you try it, please open an issue with your results.

`hs.spaces` relies on private macOS APIs that Apple does not document or guarantee. These APIs can and do change between point releases. If you're running a different macOS version:

- **macOS 15.x (other than 15.5):** May work, may not. The Spoon will load but warn you that your version is untested.
- **macOS 14 and earlier:** The Spoon will refuse to enable and log an error.
- **macOS 16 (Tahoe) and later:** Assumed not working until tested. The private APIs this depends on are likely to change.

If you find it works (or breaks) on a different version, please open an issue or PR.

## Logging

All output goes to the Hammerspoon console (open via the menubar icon or `hs -c`).

- **Info level** (default): logs syncs, skips, warnings, errors, version checks, and the position map on start. Enough to see what the Spoon is doing.
- **Debug level** (`spoon.SpacesSync.logger.setLogLevel('debug')`): adds watcher state dumps on every fire, per-target dispatch details, debounce lifecycle. Use when diagnosing race conditions or timing issues.

You can also tail logs from the terminal:

```bash
# Live tail
log stream --predicate 'process == "Hammerspoon"' | grep SpacesSync

# Recent history
/usr/bin/log show --last 5m --predicate 'process == "Hammerspoon"' | grep SpacesSync
```

## For AI agents

If you're an AI agent working on this codebase, read `CLAUDE.md` first — it points to `dev-docs/hammerspoon-and-spaces-quirks.md` which documents critical `hs.spaces` behaviors.

The `hs` CLI provides access to the Hammerspoon runtime from the terminal:

```bash
hs -c 'hs.reload()'
hs -c 'return tostring(spoon.SpacesSync:isEnabled())'
hs -c 'return hs.host.operatingSystemVersion()'
```

## Contributing

Contributions welcome! Open an issue or submit a PR.

Areas where help is especially useful:
- Testing on other macOS versions and reporting results
- Testing with non-standard monitor arrangements (vertical stacks, mixed resolutions)
- Automated testing strategies (mocking `hs.spaces` for unit tests)

## License

MIT
