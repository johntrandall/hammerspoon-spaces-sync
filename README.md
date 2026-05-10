# SpacesSync

![SpacesSync](spaces-sync-hero.png)

A [Hammerspoon](https://www.hammerspoon.org/) Spoon that keeps macOS Spaces synchronized across monitors. When you switch Spaces on one monitor, the others in its sync group follow in lockstep.

Requires [Hammerspoon](https://www.hammerspoon.org/) — a macOS automation tool scripted in Lua.

> **Note:** This Spoon has been [submitted for inclusion](https://github.com/Hammerspoon/Spoons/pull/361) in the official [Hammerspoon Spoons repository](https://github.com/Hammerspoon/Spoons). Once merged, it will be installable via `SpoonInstall` and the [Spoons directory](http://www.hammerspoon.org/Spoons/).

## Install

Pick **one** of the three methods below:

### Method 1: SpoonInstall (recommended for most users)

Single block in `~/.hammerspoon/init.lua` — downloads, installs, configures, and starts the Spoon in one go:

```lua
hs.loadSpoon("SpoonInstall")
spoon.SpoonInstall.repos.SpacesSync = {
  url = "https://github.com/johntrandall/hammerspoon-spaces-sync",
  desc = "SpacesSync Spoon repository",
  branch = "main",
}
spoon.SpoonInstall:andUse("SpacesSync", {
  repo = "SpacesSync",
  start = true,
  config = {
    syncGroups = { {1, 2} },
  },
  hotkeys = {
    toggle      = {{"ctrl", "alt", "cmd"}, "Y"},
    showNames   = {{"ctrl", "alt", "cmd"}, "N"},
    renameSpace = {{"ctrl", "alt", "cmd"}, "R"},
  },
})
```

### Method 2: Manual download (no command line)

1. Download [`SpacesSync.spoon.zip`](https://github.com/johntrandall/hammerspoon-spaces-sync/releases/latest/download/SpacesSync.spoon.zip) from the [latest release](https://github.com/johntrandall/hammerspoon-spaces-sync/releases/latest)
2. Unzip it
3. Double-click `SpacesSync.spoon` — Hammerspoon auto-installs it to `~/.hammerspoon/Spoons/`
4. Add to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("SpacesSync")
spoon.SpacesSync.syncGroups = { {1, 2} }
spoon.SpacesSync:bindHotkeys(spoon.SpacesSync.defaultHotkeys)
spoon.SpacesSync:start()
```

### Method 3: From source (for development)

```bash
git clone https://github.com/johntrandall/hammerspoon-spaces-sync.git
cd hammerspoon-spaces-sync
./install.sh
```

This symlinks `Source/SpacesSync.spoon` into `~/.hammerspoon/Spoons/` so edits to the source tree are live. Then add the same init.lua block as Method 2.

## Configuration

Set properties on `spoon.SpacesSync` before calling `:start()`:

```lua
hs.loadSpoon("SpacesSync")

spoon.SpacesSync.syncGroups = {
  { 2, 3, 4 },    -- monitors 2, 3, 4 sync together; monitor 1 is independent
}

spoon.SpacesSync:bindHotkeys(spoon.SpacesSync.defaultHotkeys)
spoon.SpacesSync:start()
```

Space names are set at runtime using the `renameSpace` hotkey (⌃⌥⌘R by default) — see [Space names](#space-names) below. Do not set `spaceNames` in your config; it is populated from `hs.settings` at runtime.

### Options

| Property          | Default      | Description                                                                                                  |
| ----------------- | ------------ | ------------------------------------------------------------------------------------------------------------ |
| `syncGroups`      | `{ {1, 2} }` | List of sync groups. Each group is a list of monitor position numbers.                                       |
| `pollTimeout`     | `2.0`        | Seconds to wait for each `gotoSpace` to verify on the target before continuing. See [Verify-based sync](#verify-based-sync). |
| `pollInterval`    | `0.030`      | Polling cadence for the verify loop.                                                                         |
| `spaceNames`      | `{}`         | Runtime name map (read-only from config). Populated from `hs.settings`; set via ⌃⌥⌘R. See [Space names](#space-names). |
| `popupDuration`   | `2`          | Seconds the space-names popup stays visible.                                                                 |
| `logger`          | `hs.logger` at `info` | Logger object. Set level with `spoon.SpacesSync.logger.setLogLevel('debug')`.                       |
| `switchDelay`     | `0.3`        | **Deprecated** — superseded by `pollTimeout` in v3. Parsed but ignored at runtime; will be removed in a future release. |
| `debounceSeconds` | `0.8`        | **Deprecated** — superseded by per-target observed-value writes in v3. Parsed but ignored at runtime; will be removed in a future release. |

Hotkeys are configured via `:bindHotkeys()`:

```lua
spoon.SpacesSync:bindHotkeys({
  toggle      = {{"ctrl", "alt", "cmd"}, "Y"},
  showNames   = {{"ctrl", "alt", "cmd"}, "N"},
  renameSpace = {{"ctrl", "alt", "cmd"}, "R"},
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

### Space names

Each Space index can carry a name. Names are global (they apply to the Nth Space on every monitor) and are persisted to `hs.settings`, so they survive Hammerspoon reloads and restarts.

Every time you switch Spaces, a popup appears on the trigger monitor listing all Spaces on that monitor with the newly active one highlighted. The popup fades after `popupDuration` seconds (default 2).

**Rename the current Space:** press the `renameSpace` hotkey (`⌃⌥⌘R` by default). A native dialog prompts for a name; submitting an empty name clears the existing name. The new name is persisted and the popup is shown with the renamed space highlighted.

**Show the popup on demand:** press the `showNames` hotkey (`⌃⌥⌘N` by default). The popup appears on the monitor under the mouse cursor, highlighting its currently active Space.

Names are set entirely at runtime via the rename hotkey and stored in `hs.settings`. Do not assign `spoon.SpacesSync.spaceNames` in your config — that table is populated from persisted storage on first use, and any config-time assignments are discarded.

Names for indices beyond the current monitor's Space count are kept in storage but hidden from the popup. Unnamed indices render as dim italic "Space N".

## Usage

**Toggle:** via the hotkey you bind (starts disabled — call `:start()` to enable)

Also available programmatically:

```lua
spoon.SpacesSync:start()
spoon.SpacesSync:stop()
spoon.SpacesSync:toggle()
spoon.SpacesSync:isEnabled()
spoon.SpacesSync:showNames()
spoon.SpacesSync:renameCurrentSpace()
spoon.SpacesSync:status()        -- diagnostic snapshot, see Debugging below
```

## How it works

### Verify-based sync

Two entry paths fire the engine:

1. **Spaces watcher** (`hs.spaces.watcher`) — fires when any monitor's active Space changes. The primary path, triggered by user swipes, ⌃→/⌃←, Dock clicks, or other macOS UI.
2. **Screen watcher** (`hs.screen.watcher`) — fires when the display layout changes (monitor plug/unplug, lid open/close, dock/undock, displays rearranged in System Settings, resolution change). Coalesces macOS's 2-5x burst into one rebuild via a 250 ms debounce.

When the spaces watcher fires:

1. Compute the *expected end state*: for each sync-group target, the Space ID at the trigger's index.
2. For each target, dispatch `hs.spaces.gotoSpace()`, then **poll** `hs.spaces.activeSpaceOnScreen()` every `pollInterval` (default 30 ms) until it matches the expected Space ID — or `pollTimeout` (default 2 s) elapses.
3. After each verify, write the **observed** post-poll value into the per-target baseline. macOS's own echo for the dispatch then diffs to no-change cleanly — no debounce window needed.
4. After the last target, run an **end-of-chain verifier** that diffs the actual world against the expected end state. Any mismatch is logged at error level and the baseline is refreshed from reality.

The polling cadence and timeout were calibrated empirically (mean Mission Control flip latency on macOS 15.7.5 is ~753 ms; the largest observed flip was ~898 ms). For the full analysis see [dev-docs/findings/F-010-polling-model-a-vs-b.md](dev-docs/findings/F-010-polling-model-a-vs-b.md).

When the screen watcher fires (after the 250 ms debounce):

1. Bail any in-flight sync chain.
2. Rebuild the position map.
3. Refresh the baseline.
4. Validate `syncGroups` against the new layout.
5. Show a "SpacesSync: display layout changed" HUD.

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

### Setup script

A setup script is included to check and configure the required and recommended settings:

```bash
./configure-macos.sh
```

The Spoon also checks the required and first recommended setting on start and warns if they're misconfigured.

For the full analysis of every macOS setting that could affect sync, see [dev-docs/findings/macos-spaces-settings.md](dev-docs/findings/macos-spaces-settings.md).

## Compatibility

Tested on **macOS 15.5 (Sequoia)** with **Hammerspoon 1.1.1** on a 4-monitor setup (4x LG SDQHD).

> **macOS 16 (Tahoe):** Not tested. `hs.spaces` relies on private macOS APIs that Apple changes between major releases. SpacesSync should be assumed **not working on Tahoe** until someone tests and confirms. If you try it, please open an issue with your results.

`hs.spaces` relies on private macOS APIs that Apple does not document or guarantee. These APIs can and do change between point releases. If you're running a different macOS version:

- **macOS 15.x (other than 15.5):** May work, may not. The Spoon will load but warn you that your version is untested.
- **macOS 14 and earlier:** The Spoon will refuse to enable and log an error.
- **macOS 16 (Tahoe) and later:** Assumed not working until tested. The private APIs this depends on are likely to change.

If you find it works (or breaks) on a different version, please open an issue or PR.

## Logging

All output goes to the **Hammerspoon Console** (open via the menubar icon, or `hs -c 'hs.openConsole()'`).

- **Info level** (default): logs syncs, skips, warnings, errors, version checks, and the position map on start.
- **Debug level** (`spoon.SpacesSync.logger.setLogLevel('debug')`): adds watcher state dumps on every fire, computed `expectedEndState` per chain, per-target dispatch and verify ticks, end-of-chain verifier results. Use when diagnosing race conditions or timing issues.

### Viewing logs from the terminal

Hammerspoon does **not** write to the macOS unified log, so `log stream --predicate 'process == "Hammerspoon"'` returns nothing. This is a known Hammerspoon limitation ([issue #1684](https://github.com/Hammerspoon/hammerspoon/issues/1684)).

One-shot snapshot of the current Console buffer:

```bash
hs -c 'return hs.console.getConsole()' | grep SpacesSync
```


## Debugging from the terminal

The `hs` CLI provides access to the Hammerspoon runtime from the terminal:

```bash
hs -c 'hs.reload()'
hs -c 'return tostring(spoon.SpacesSync:isEnabled())'
hs -c 'return hs.host.operatingSystemVersion()'
```

### `:status()` — diagnostic snapshot

`spoon.SpacesSync:status()` returns a table summarizing internal state. It also logs a one-line summary at info level so you can see it in the Hammerspoon Console.

```bash
hs -c 'return hs.inspect(spoon.SpacesSync:status())'
```

Fields returned:

| Key | Type | Meaning |
|---|---|---|
| `enabled` | bool | `:start()` succeeded and watchers are armed |
| `osBlocked` | bool | environment / Accessibility checks failed |
| `syncInProgress` | bool | a sync chain is currently mid-flight |
| `chainGeneration` | int | monotonically increasing chain token (used to invalidate stale closures) |
| `activeChainTimers` | int | number of chain-owned timers currently scheduled |
| `totalScreens` | int | count of connected displays |
| `positionMap` | table | copy of position → display UUID map |
| `syncGroups` | table | copy of `obj.syncGroups` |
| `lastActiveSpaces` | table | copy of UUID → Space ID baseline |
| `lastVerifierResult` | table | `{ timestamp, mismatches }` from the most recent end-of-chain verifier run, or `nil` if no chain has run yet |
| `pollTimeout`, `pollInterval` | number | current values of the timing knobs |

The one-line log looks like `SpacesSync v0.3: idle, 4 screens, 1 sync group(s), last verify clean at HH:MM:SS`.

For AI agents working on this codebase, read `CLAUDE.md` first.

## Contributing

Contributions welcome! Open an issue or submit a PR.

Areas where help is especially useful:
- Testing on other macOS versions and reporting results
- Testing with non-standard monitor arrangements (vertical stacks, mixed resolutions)
- Adding L6 scenarios from `dev-docs/manual-test-checklist.md` to `tests/L6/` — currently only Scenario 1 is automated. See `dev-docs/test-strategy.md` for the policy and `tests/L6/scenario-01-single-swipe.lua` for the three-phase pattern.

### Running the test suite

```bash
tests/run.sh                              # default: L0 + L3 (safe)
tests/run.sh L1                           # pure-Lua units, no Hammerspoon needed
tests/run.sh L3_inclusive                 # L0 + L1 + L3 — pre-commit equivalent
SPACESSYNC_L6=1 tests/run.sh L6_inclusive # full suite — switches Spaces ~10s
```

L6 requires `SPACESSYNC_L6=1` because it dispatches real `gotoSpace` calls and switches Spaces on the test host. See `dev-docs/test-strategy.md` § Deviations §5.

## License

MIT
