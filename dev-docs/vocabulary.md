# SpacesSync Vocabulary

Canonical terms used throughout the SpacesSync codebase and documentation. **Two audiences, one source of truth.**

- **User-facing terms** appear in the settings pane, tooltips, hotkey descriptions, status HUD copy, README, and any prose aimed at end users.
- **Internal terms** appear in source code identifiers, code comments, ADRs, design diagrams, and developer-facing docs.

Some concepts have both a user-facing and internal name (e.g. "Sync group" vs `groupOf`); some are user-only (e.g. "Group N" labels rendered from display order); some are internal-only and **must not leak** into user copy (e.g. "trigger", "watcher", "sibling"). When in doubt, prefer the canonical user-facing name in any prose users will read.

## Quick matrix

| User-facing term | Internal term | Don't expose to users |
|------------------|---------------|------------------------|
| Display          | display, `screen` | — |
| Position number  | position, `pos` | — |
| Cursor display   | `cursorScreen` (`hs.mouse.getCurrentScreen()`) | — |
| Current Space    | current Space, `activeSpaceOnScreen()` | — |
| Sync group       | sync group, `syncGroups`, `groupOf`; identity is a **letter** from a fixed pool A–J | — |
| Group A / B / …  | letter is both the stable ID and the default display label | — |
| Group label      | optional user-set name in `groupLabels`, e.g. `{"A":"Code"}` displays as "A: Code" | — |
| Display set ＊roadmap＊ | (not modeled in code) | — |
| Space            | space, `spaceID` | — |
| Space index      | space index, `spaceIndex` | — |
| Switch delay     | `switchDelay` | — |
| Debounce         | `debounceSeconds` | — |
| Status HUD       | status HUD | — |
| Sync mode        | `syncMode` (`automatic` \| `manual`) | — |
| Sync (verb)      | sync, `syncTarget`, `syncNext` | — |
| Sync now         | `:syncNow()` | — |
| (use "the cursor display's group") | trigger (display) | ✗ user-facing |
| (use "the rest of the group") | target / sibling (display) | ✗ user-facing |
| (use "SpacesSync mirrors…")   | watcher / `hs.spaces.watcher` | ✗ user-facing |
| (use "sync") | sync chain | ✗ user-facing |
| (use the macOS preference name) | spans-displays | ✗ user-facing (quote macOS UI verbatim instead) |

---

## User-facing vocabulary

### Display
A physical monitor connected to the Mac. Identified internally by UUID (stable across reconnects) and assigned a **position number** on startup.

### Position number
An integer assigned to each display in reading order (left-to-right, then top-to-bottom as tiebreaker), based on `screen:frame()` coordinates. Position numbers are stable across restarts because they're derived from physical arrangement, not from macOS's unstable display IDs. SpacesSync rebuilds this map on every `start()`.

**Example:** A 4-monitor setup arranged horizontally has position numbers 1, 2, 3, 4 from left to right.

### Cursor display
The display under the mouse cursor at the moment a hotkey or settings-pane button fires. **The single canonical referent for any user-invoked action.** Used by `:showNames()`, `:renameCurrentSpace()`, and `:syncNow()`.

This is the user-facing equivalent of the engine-internal "trigger display": when the engine detects a Space switch, the watcher's "trigger" is internal — the user never needs to know which display the engine considers authoritative. When the user invokes an action, "cursor display" is the term.

**Implementation:** `hs.mouse.getCurrentScreen()` with `hs.screen.mainScreen()` as fallback.

### Current Space
The Space currently visible on a given display — the one the user sees when they look at it. The same as `hs.spaces.activeSpaceOnScreen(display)`. Used in user-facing copy when we need to disambiguate from "all Spaces on the display."

**Use "current," never "active."** "Active" introduces a parallel axis that overlaps with "cursor display" and creates two ways to say one thing. The pair *cursor display* × *current Space* covers every **user-invoked action**: which display, which Space on it. Watcher-detected events (the engine reacting to a Space switch) have a different subject — see the internal "trigger display" entry — but those events have no user-facing copy attached.

### Sync group
A group of displays that share Space indices. When any display in a sync group switches Spaces (in Automatic sync mode), SpacesSync moves the others to match. This is the core abstraction the Spoon provides.

- **Example:** sync group containing positions 2, 3, 4 — all three displays move together.
- **Example:** two independent sync groups: {1, 2} and {3, 4} — each pair syncs internally, the pairs don't affect each other.

Displays not in any sync group are **independent** — SpacesSync never moves them.

**Identity:** groups are drawn from a **fixed pool of 10 letters: A, B, C, D, E, F, G, H, I, J.** All 10 always exist; there is no creation or deletion lifecycle. A group is "in use" when one or more positions are assigned to it in `groupOf`; otherwise it's empty and inert. Empty groups remain in the pool — their letter and label persist across emptiness.

**Why 10:** more than enough for any current Mac with comfortable buffer. Max useful sync groups = ⌊displays / 2⌋ since each group needs at least 2 members to be meaningful. The fixed cap eliminates a class of edge cases — no "next unused letter" logic, no retired-letter tracking, no creation/dissolution events.

**Default name:** every group has a default display name of `"Group <letter>"` — Group A, Group B, Group C, …, Group J. This is the fallback shown anywhere a group is rendered with no user-set label.

**Custom label (optional):** each group can have an **optional** user-set label in `groupLabels` — a sparse map containing only entries for labeled groups. When a label exists, the group renders as `"<letter>: <label>"` (e.g. "A: Code"). When absent, it falls back to the default name (e.g. "Group A"). Labels are user-editable in the settings pane's Group Labels section.

### Display set ＊roadmap, not in v1＊
A physical arrangement of displays. Think "my home desk" vs "my office desk" — different hardware, different number of monitors, different layouts. **The current Spoon does not model display sets.** This entry exists to reserve the term for a future feature where the user could keep multiple `groupOf` configurations and switch between them when their hardware setup changes. Do not surface "display set" in any user-facing copy until that feature exists — using the term now misleads users into expecting profile switching.

**Example (future):** "On my home display set I have 4 LG displays. On my office display set I have a laptop and one external."

### Space
macOS's native concept of a virtual desktop — what you switch between with Mission Control or ⌃→/⌃←. Each display has its own independent list of Spaces.

### Space index
The ordinal position (1-based) of a Space within a display's Space list. Index 1 = leftmost / first in Mission Control, index 2 = second, etc.

SpacesSync operates entirely on indices, never on Space IDs across displays. "Space 2 on display A" and "Space 2 on display B" are different macOS Spaces with different IDs, but they share index 2 — SpacesSync guarantees they're visited together.

### Space-name scope
**Spaces have names. Groups don't (in v1).** The rename action targets the current Space, and the name auto-propagates within the sync group at the same index because storage is keyed by *(group letter, Space index)* — not *(display, Space ID)*.

- **Example:** `spaceNames = { ["A"] = { [1] = "Code", [2] = "Email" } }` — when group A is at index 1, every display in A shows "Code".
- **User-facing copy** says "Rename current Space" with the sublabel making the cross-display behavior explicit ("Names this Space across the sync group — every display in the group sees the same name at this index").
- **Why no "workspace" term?** Earlier vocab drafts introduced "workspace" for "the named state across a sync group at one index." Council review found it was an over-promoted abstraction: the term implied a UI artifact (a Workspaces list) that didn't exist, and asked users to learn a noun whose only payoff was precision they could derive from "I'm in a sync group, names propagate." Reverted. The internal field stays named `spaceNames` — no `workspaceNames` rename.
- **What about renaming a group?** v1 has a Group Labels section in the settings pane that lets users set an optional label per group (`groupLabels: {"A": "Code"}`). This is a *separate* surface from "Rename current Space" — labels target the group letter; Space names target the (group, index) tuple.

### Switch delay
The pause between consecutive Space switches when SpacesSync is moving multiple displays. macOS silently drops rapid back-to-back calls; the delay gives each one time to be accepted. Default: 0.3s.

User-facing in the Timing section of the settings pane and in the Debounce/Switch-delay tooltips.

### Debounce
The waiting period after a sync completes before SpacesSync resumes reacting to Space changes. Prevents reacting to its own switches and looping. Default: 0.8s.

### Status HUD
The single-line "SpacesSync: ON" / "SpacesSync: OFF" overlay that flashes when the master toggle changes state. **Distinct from the Space-names popup** — the popup is the multi-row panel showing each Space's index and name; the HUD is the wider, centered, one-line status banner.

### Popup duration
How long the Space-names popup remains on screen after a sync or after `:showNames()`. **Internal name:** `popupDuration`. Default 2 s.

### Status HUD duration
How long the Status HUD banner stays visible when the master switch is toggled. **Internal name:** `statusDuration`. Default 3 s. Distinct from `popupDuration` — these are two separate overlays with separate dwell times.

### Sync mode
The two-value setting that gates the watcher: **Automatic** (SpacesSync syncs every Space change live) or **Manual** (displays move freely; the user invokes Sync now to bring the group together). Independent of the master Enable toggle.

### Sync now
The user-invoked action that switches the cursor display's group to the cursor display's current Space. Hotkey ⌃⌥⌘S by default. Scope is the cursor display's group only — other groups stay where they are.

### Sync (verb)
Canonical verb for "propagate one display's Space change to the rest of its group." Use as both verb (`SpacesSync syncs every Space switch to the rest of its group`) and noun (`a sync started by the watcher`). **Avoid** "mirror" (implies bidirectional reflection — sync is one-way), "align" (implies coordinate-matching — too geometric), "propagate" (technical jargon), "follow" (ambiguous about who follows whom). The corresponding internal narrative term is "sync chain" (the full sequence: detect → compute targets → chained gotoSpace → debounce).

### Enable SpacesSync (master switch)
The single boolean that governs whether SpacesSync does anything at all. When off: hotkeys, popups, picker, status HUD, and sync are all dormant.

---

## Internal vocabulary

These terms are for source code, ADRs, design diagrams, code review, and developer-facing docs. **Do not put these in user-facing copy.** When you find yourself reaching for one in user prose, use the user-facing equivalent from the matrix above.

### Trigger (display)
The display whose Space change was first detected by the watcher. The engine identifies the trigger inside the watcher callback by diffing `lastActiveSpaces` against the current snapshot.

**Do not surface to users.** When a user *invokes* an action, the parallel concept is "cursor display". When the engine *detects* a change, the user doesn't need to know which display the engine considered the trigger — they just see the resulting sync.

**Decision (post-council):** The console log `obj.logger.i("SYNC: <name> (trigger) ...")` is the only place "trigger" surfaces, and only in the Hammerspoon console which is power-user-debugging territory. **No user-facing parallel term will be coined.** Coining "source display" or similar would add vocabulary surface without adding clarity for users (who already have "cursor display" for the user-invoked-action case). Console logs use "trigger" as the engine-internal narrative term.

### Target (display)
A display that gets switched to match the trigger. In a sync group of N displays, one Space change produces one trigger and N-1 targets.

**Do not surface to users.** Use "the rest of the group" or "the cursor display's group" in user copy.

### Sibling (display)
Older term used interchangeably with target — surfaces in some prose. Prefer "target" in code comments and design docs. **Do not surface to users.**

### Watcher
The `hs.spaces.watcher` instance that fires the engine when macOS reports a Space change. **Do not surface to users.** In user copy, frame what happens — "SpacesSync mirrors every Space switch" — without naming the watcher.

### Sync chain
The sequence of operations triggered by one Space change: detect → identify trigger → compute targets → chain `gotoSpace` calls with `switchDelay` between → wait `debounceSeconds` → re-enable watcher. Internal narrative term used in design docs and code comments. **In user copy, just say "sync".**

### `groupOf`
The persistent map from position number to a letter from the fixed pool A–J, stored in `SpacesSync.json` (e.g. `{ "1": "A", "2": "A", "4": "B" }`). Canonical form for sync-group membership. The letter is both the stable internal identifier and the default display label; an optional user-set label in `groupLabels` can be combined ("A: Code") for display.

### `syncGroups`
The runtime list-of-lists derived from `groupOf` — what the sync engine consumes. Stable derivation: sort group IDs, sort positions within each group.

### `syncInProgress`, `pendingConfig`
Engine-internal flags. `syncInProgress` is true during a sync chain; while true, config edits are stashed in `pendingConfig` and drained by the debounce callback (avoids corrupting `lastActiveSpaces` baseline mid-flight).

### `_lastSeen`
JSON field. Map from position number to `{ name, uuid, date, wasIn }` for displays that *were* configured at some point but aren't currently connected. `wasIn` is the group letter the position was last assigned to. Used by the settings pane to show stale entries with useful context ("LG SDQHD #5 — last seen 2026-04-12, was in A: Code") rather than anonymous warnings. Written by the screen-watcher on disconnect events; cleared when a position rejoins.

---

## Cross-system terminology

Use macOS / Hammerspoon names verbatim when referring to those systems' concepts.

| Term | Where it comes from | Use as-is |
|---|---|---|
| Mission Control | macOS feature | yes |
| Space (the macOS feature) | macOS feature | yes |
| "Displays have separate Spaces" | macOS preference name | yes — quote literally; never paraphrase to "spans-displays" or "separate spaces mode" |
| Hammerspoon | Runtime | yes |
| `hs.spaces`, `hs.screen`, `hs.canvas`, `hs.webview`, `hs.pathwatcher` | Hammerspoon module names | yes — appropriate in design docs and code comments; **avoid in user-facing copy** (users should see the consequence, not the API) |

---

## Forbidden / avoid

| Don't say | Say instead | Why |
|---|---|---|
| Monitor | Display | Consistency with macOS and the rest of the codebase. |
| Active display / active Space | Cursor display / current Space | Two ways to say one thing. The cursor display × current Space pair covers every user-action reference; "active" introduces a third overlapping concept and breeds drift. |
| "Workspace" (any sense) | "Space" with cross-display copy in sublabel | Council review found "workspace" was an over-promoted abstraction (no UI artifact, asks users to learn a noun whose only payoff is precision). Dropped. The internal field stays `spaceNames` keyed by `(group letter, index)`. |
| "Rename / name the sync group" | "Rename current Space" with sublabel "Names this Space across the sync group" | A sync group has many named Spaces (one per index). Renaming names just the current Space — and that name propagates across the group automatically because it's keyed `(group letter, index)`. |
| "Rename current group" / "rename the sync group" | (split: see right) | v1 has *two* surfaces for naming. **"Rename current Space"** targets the current Space; the name is keyed `(group, index)` and propagates within the group. **"Group label"** in the Group Labels section sets a per-group display name. Conflating them in copy is wrong. |
| Trigger / target (in user copy) | Cursor display, or "the group" / "the rest of the group" | Internal only. |
| Sibling (in user copy) | The rest of the group | Internal only. |
| Watcher (in user copy) | "SpacesSync mirrors…" or "automatic sync mode" | Internal only. |
| Sync chain (in user copy) | Just "sync" | Internal narrative term. |
| Source / partner | Trigger / target (in code) or cursor display (in user copy) | Old v0.1 vocabulary. |
| Space ID (in cross-display comparisons) | Space index | IDs aren't comparable across displays. |
| `pos N` (abbreviation) | `position N` | Don't abbreviate user-facing labels. |
| "Across each group" (when describing mirroring) | "to the rest of its sync group" | "Across each" reads as sweeping multiple groups. Mirroring is per-group: one Space switch propagates within one group. |
| "Align" / "re-align" (the propagation action) | "Sync" | Users switch Spaces; SpacesSync syncs across a group. "Align" implies coordinate-matching. |
| "Mirror" (the propagation action) | "Sync" | "Mirror" implies bidirectional reflection. Sync is one-way: trigger display first, group follows. |
| "Propagate" / "follow" (in user copy) | "Sync" | Engineering jargon and ambiguous direction; "sync" reads naturally to end users. |
| "On demand only" / "On-demand sync" (Sync mode label) | "Manual" | The standard pairing is Automatic / Manual. "On demand only" reads as a feature restriction. |

---

## When this doc and the running code disagree

Code wins for code identifiers. This doc wins for prose, comments, diagrams, ADRs, and any text the user might read. If you find drift, fix it — open a small PR that aligns one or the other.
