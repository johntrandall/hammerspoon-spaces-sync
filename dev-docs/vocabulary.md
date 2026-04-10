# SpacesSync Vocabulary

Canonical terms used throughout the SpacesSync codebase and documentation. Use these terms consistently. When in doubt, prefer the words defined here over synonyms.

## Hardware layer

### Display
A physical monitor connected to the Mac. Identified internally by UUID (stable across reconnects) and assigned a **position number** on startup.

### Display set
A physical arrangement of displays. Think "my home desk" vs "my office desk" — different hardware, different number of monitors, different layouts. A display set is a *configuration of hardware*, not a SpacesSync concept. SpacesSync doesn't directly model display sets, but the user-facing concept matters because the same `syncGroups` config may make sense on one display set and not another.

**Example:** "On my home display set I have 4 LG monitors. On my office display set I have a laptop and one external."

### Position number
An integer assigned to each display in reading order (left-to-right, then top-to-bottom as tiebreaker), based on `screen:frame()` coordinates. Position numbers are stable across restarts because they're derived from physical arrangement, not from macOS's unstable display IDs. SpacesSync rebuilds this map on every `start()`.

**Example:** A 4-monitor setup arranged horizontally has position numbers 1, 2, 3, 4 from left to right.

## Sync layer

### Sync group (or "display sync group")
A list of position numbers that should share space indices. When any display in a sync group switches spaces, SpacesSync drives the others to match. This is the core abstraction the Spoon provides.

- **Internal name:** `syncGroups` (plural; the config holds a list of sync groups)
- **Example:** `syncGroups = { {2, 3, 4} }` — one sync group containing positions 2, 3, 4
- **Example:** `syncGroups = { {1, 2}, {3, 4} }` — two independent sync groups

Displays not listed in any sync group are **independent** — SpacesSync never touches them.

### Trigger (display)
The display where a space change was first detected by the watcher. All other displays in the same sync group are **targets** that need to be driven to match.

### Target (display)
A display that needs to be switched to match the trigger's space index. In a sync group of N displays, one space change produces one trigger and N-1 targets.

## Space layer

### Space
macOS's native concept of a virtual desktop — what you switch between with Mission Control or ⌃→/⌃←. Each display has its own independent list of spaces.

### Space index
The ordinal position (1-based) of a space within a display's space list. Index 1 = leftmost/first space in Mission Control, index 2 = second, etc.

SpacesSync operates entirely on indices, never on space IDs directly when comparing across displays. "Space 2 on monitor A" and "space 2 on monitor B" are different macOS spaces with different space IDs, but they share the same index — and SpacesSync guarantees they're visited together.

### Workspace
The unified state across all displays in a sync group at a particular space index. When sync group `{2, 3, 4}` is at index 1, that's **one workspace** — three physical spaces (one per display) that move together and represent a single conceptual work context.

**This is the thing users name.** "Code" is a workspace name. It refers to index 1 across the sync group, not to a specific space on a specific monitor.

- **Internal name:** `workspaceNames` (or whatever the persistence feature ends up calling it)
- **Example:** `workspaceNames = { [1] = "Code", [2] = "Email", [3] = "Browser" }`

## Timing layer

### Switch delay
The pause between consecutive `hs.spaces.gotoSpace()` calls when syncing multiple targets. macOS silently drops rapid back-to-back calls; the delay gives each one time to be accepted. Default: 0.3s.

**Internal name:** `switchDelay`

### Debounce (period)
The waiting period after all programmatic switches complete before the watcher is re-enabled to respond to new events. Prevents the watcher from reacting to the Spoon's own `gotoSpace` calls as if they were user-initiated. Default: 0.8s.

**Internal name:** `debounceSeconds`

### Sync chain
The sequence of operations triggered by one space change: detect → identify trigger → compute targets → chain `gotoSpace` calls with `switchDelay` between each → wait `debounceSeconds` → re-enable watcher.

## What NOT to say

| Don't say | Say instead | Why |
|---|---|---|
| "Monitor N" | "Position N" or "display at position N" | "Monitor" and "display" are interchangeable in English but "position" is what SpacesSync actually uses to identify. |
| "Space name" | "Workspace name" | "Space" implies a single macOS space on a single display. We're naming a unified state across a sync group. |
| "Display set" (when talking about a sync group) | "Sync group" | "Display set" = hardware arrangement. "Sync group" = which of those displays share space indices. |
| "Source" / "partner" | "Trigger" / "target" | Older terminology from v0.1. The current code uses trigger/target throughout. |
| "Space ID" (in comparisons across displays) | "Space index" | Space IDs are unique per macOS space and can't be compared across displays. Indices are the shared reference point. |

## Related concepts outside SpacesSync

- **Mission Control** — macOS's system-level feature for managing spaces. SpacesSync uses it indirectly (`hs.spaces.gotoSpace()` is built on AX automation of Mission Control).
- **Private hs.spaces APIs** — see `hammerspoon-and-spaces-quirks.md` for why some functions work and others don't.
