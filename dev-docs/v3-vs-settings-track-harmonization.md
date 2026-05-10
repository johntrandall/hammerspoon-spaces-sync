# v3 sync-engine track vs settings/config track — harmonization review

Two parallel design efforts are in flight in `dev-docs/diagrams/`:

- **v3 sync-engine track** (this session) — `workflow-roadmap.mermaid`, `code-changes-pending.md`, `F-010` empirical study. Focuses on replacing fixed `switchDelay`/`debounceSeconds` with poll-based verification.
- **Settings/config track** (parallel session) — `architecture-components-roadmap.mermaid`, `config-change-flow.mermaid`, `data-model.mermaid`, `settings-pane-mockup.html`. Adds an `hs.webview` settings GUI, migrates config to a canonical `SpacesSync.json`, introduces opaque group IDs, and uses `hs.pathwatcher` for hand-edit support.

This doc records where the two tracks compose cleanly, where they conflict, and what each owes the other before either ships. Written from the v3 side; the settings track may have a symmetric review.

## Where they compose cleanly

1. **Component model.** The settings track adds two new components (`ConfigMod`, `SettingsPane`) and two new external surfaces (`SpacesSync.json`, `hs.shutdownCallback`). v3 doesn't touch those, and the settings track doesn't touch the sync engine's internals. Different components, no overlap.
2. **`hs.shutdownCallback` for teardown.** Useful regardless. v3 also benefits — it can register cleanup for the new `hs.screen.watcher`, watchdog timers, and chain-state.
3. **Hotkeys schema.** The settings track adds `syncNow` and `openSettings` to the hotkey table. Both compose with v3 — they bind to existing or trivially new public methods.
4. **Workspace name migration on `groupOf` change.** Independent of v3's sync logic; the migration contract (atomic key rewrite, orphans surface as warnings) is good craft. v3 doesn't fight it.
5. **`enabled` master flag.** Already exists in v3 as `state.enabled`. The settings track's `enabled` JSON field maps directly.

## Where they conflict (real points to resolve)

### 1. `switchDelay` and `debounceSeconds` in `SpacesSync.json` schema

**Conflict:** `data-model.mermaid` shows `"switchDelay": 0.3` and `"debounceSeconds": 0.8` in the JSON.

**v3 status:** these knobs are deprecated. v3 replaces them with `pollTimeout = 2.0` (per F-010 §6.1) and `pollInterval = 0.030`. Per `code-changes-pending.md` item 1, the deprecated knobs stay accepted-but-ignored for one release.

**Resolution:** the settings JSON schema should:
- Add `pollTimeout` and `pollInterval` as canonical knobs.
- Keep `switchDelay`/`debounceSeconds` parseable but mark them deprecated in the schema and the GUI; ignore values silently after one release.
- Settings Pane should not surface `switchDelay`/`debounceSeconds` to the user as edit fields — they have no effect under v3.

### 2. "Debounce drains pendingConfig" assumption

**Conflict:** `config-change-flow.mermaid` line 77 says: *"Debounce timer fires existing path. If pendingConfig set, drain via applyConfig. Otherwise clear syncInProgress as today."* This assumes v0.2's `debounceSeconds` timer.

**v3 status:** there is no debounce timer. v3 clears `syncInProgress` immediately after the end-of-chain verifier completes (no padding).

**Resolution:** rename the post-chain trigger from "debounce timer fires" to "post-chain drain." Concretely:

- In v3, the end-of-chain VERIFY_END_STATE node is the moment when "chain is finished, gate is about to clear."
- Reframe `pendingConfig` drain as: after VERIFY_END_STATE, before CLEAR, check `state.pendingConfig`. If set, call `applyConfig(state.pendingConfig)` and clear it. Then clear `syncInProgress`.
- The mid-sync apply hazard ("corrupts lastActiveSpaces baseline") is the same in v3 — `applyConfig` may rebuild position map and re-snap baseline. Doing it inside the chain is still wrong; doing it at end-of-chain (after VERIFY_END_STATE, before CLEAR) is exactly the right place.

### 3. Group representation: `groupOf` (settings) vs `syncGroups` (engine)

**Conflict:** the settings track introduces opaque group IDs (`grp_a8x2k0`) keyed per position, derived to a list-of-lists at runtime. The engine still consumes `obj.syncGroups = {{1, 2}, {4}}`.

**v3 status:** v3's `expectedEndState`, `chainGeneration`, and `getTargetsFor` all assume the existing list-of-lists shape.

**Resolution:** clean compose. The `groupOfToGroups()` derivation function in the settings track produces exactly the shape v3 already consumes. v3 doesn't need to know about opaque IDs at all — it sees the derived `syncGroups`.

**One caveat:** when `applyConfig` re-snaps `lastActiveSpaces` after a `groupOf` change, it must do so AFTER the position map is rebuilt and BEFORE the next watcher fire. Sequencing already correct in `config-change-flow.mermaid` lines 59 + 73.

### 4. `syncMode: "automatic" | "on-demand"`

**Conflict:** new config field. `on-demand` stops the spaces-watcher; user explicitly invokes `syncNow` (a new public API).

**v3 status:** v3 has TWO watchers (spaces-watcher + screen-watcher). The settings track's `syncMode` only governs the spaces-watcher.

**Resolution:** explicit. `on-demand` should:
- Stop `spacesWatcher` (the existing one).
- Keep `screenWatcher` running — display reconfig still needs to maintain the position map and `lastActiveSpaces` baseline.
- Document this asymmetry. Otherwise users will be confused why hotkey-sync still works after a monitor unplug.

### 5. `_lastSeen` for stale entries

The settings JSON tracks last-seen metadata for displays no longer connected. v3's `screenWatcher` invokes `validateConfig` (v3's term) / `VALIDATE_CONFIG` node, which logs warnings for sync-group references that exceed `totalScreens`. Compose cleanly. v3 should also write into `_lastSeen` when a display drops; settings GUI surfaces stale entries to the user.

## What each track owes the other

### v3 owes settings

- A clean `applyConfig(state)` entry point that doesn't fire mid-chain. Concretely: an `obj:applyConfig(newConfig)` method that delegates to `pendingConfig` if `state.syncInProgress`, else does the work immediately.
- A documented post-chain drain step in `workflow-roadmap.mermaid` that mentions the pendingConfig hook.
- Stable public method names for `syncNow` and `openSettings` (settings track exposes hotkeys to these).

### Settings track owes v3

- Drop `switchDelay`/`debounceSeconds` from the GUI; replace with `pollTimeout`/`pollInterval` (both are per-deployment knobs the user might want to tweak).
- Update `config-change-flow.mermaid` to say "post-chain drain" instead of "debounce timer fires."
- Per-display `syncMode` is out of scope (the JSON schema as drawn has a single global `syncMode`); confirm this is the intent.

## Suggested next steps

1. **Settings track:** update the three diagrams to reflect v3's parameter set (`pollTimeout`/`pollInterval`, no `debounceSeconds`). Trivial edit.
2. **v3 track:** add a small `pendingConfig` drain node to `workflow-roadmap.mermaid` between `VERIFY_END_STATE` and `CLEAR`. Documents the integration point.
3. **Joint:** decide whether `syncMode: on-demand` keeps the screen-watcher alive (recommended) or stops both watchers (simpler but worse).
4. **Joint:** name the public `applyConfig` entry point and document its mid-chain semantics.

---

Generated 2026-05-10 from a v3-side review of the four untracked diagrams in `dev-docs/diagrams/`. The settings track was authored in a parallel session; this doc reflects v3's perspective only and may need a counter-review from the settings author.
