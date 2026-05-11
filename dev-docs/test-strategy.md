# SpacesSync — Test Strategy

This project follows the Autocoder Testing Policy for level definitions,
gating rules, and runner conventions. This document describes how those
rules are instantiated locally for a Hammerspoon Lua Spoon whose
integration target (`hs.spaces` / Mission Control) cannot be exercised
headlessly.

**Canonical sources** (local-only paths; not visible in a GitHub render):

- `~/dev/autocoder_v3/_bootstrap/policies/ac-testing-policy/SKILL.md` — level definitions, gating, runner conventions
- `~/dev/autocoder_v3/_bootstrap/policies/ac-testing-policy/MANIFESTO.md` — rationale & examples
- `~/dev/autocoder_v3/vocabulary/testing-vocabulary.md` — testing vocabulary
- `~/dev/autocoder_v3/dev-docs/sparks/spark-049-l6-subtiers-distributed-systems.md` — L6 sub-tier rationale
- `~/.claude/skills/testing-policy/SKILL.md` — global quick-reference subset
- `~/.claude/skills/local-testing-strategy/SKILL.md` — local setup procedure

[busted]: https://lunarmodules.github.io/busted/
[luacheck]: https://github.com/lunarmodules/luacheck

## Status

**Policy converged; implementation landed.** Tests live in `tests/`
under the layout described below. Current coverage:

| Level | Status | Tests |
|-------|--------|-------|
| L0    | green  | 4 guards (syntax, docs.json, version-sync, readme-links) |
| L1    | green  | 45 unit tests across 6 helpers |
| L3    | green  | 1 contract test (12-key `:status()` shape) |
| L6    | green  | scenario-01 + scenario-02 + scenario-03 + scenario-05 + scenario-08 (5 of 30 manual checklist scenarios automated) |
| L6h   | green  | infrastructure ready; no scenarios currently registered (scenario-05 promoted to L6 once AppleScript-via-System-Events keystroke path was verified to drive Mission Control) |

Run `tests/run.sh` for the default safe set (L0 + L3),
`tests/run.sh L3_inclusive` for the pre-commit equivalent (L0 + L1 +
L3), or `SPACESSYNC_L6=1 tests/run.sh L6_inclusive` for the full
ladder including the live sync chain.

L1 was added to the active set during implementation (the test author
proved out the pure-Lua helpers via `debug.getupvalue` introspection
of the loaded init.lua, with no source modifications). L1 is now
"green" rather than "Not yet"; the activation trigger described in
J1 below is no longer load-bearing.

L6 has 5 of 30 manual-checklist scenarios automated; the rest of the
checklist remains the parent set, with automated coverage growing one
scenario at a time.

The verification fallback for un-automated scenarios is still
`dev-docs/manual-test-checklist.md`.

## Project Context

SpacesSync is a Hammerspoon Spoon (Lua) that wraps the private-API
`hs.spaces` and uses `hs.spaces.gotoSpace` (which drives Mission Control
via accessibility automation) to keep multiple displays' active Spaces
in sync. Two facts shape the strategy:

1. **Hammerspoon-private APIs are hard to fake.** `hs.spaces` reads CGS
   state and dispatches Mission Control via `hs.axuielement`. There is
   no public surface that returns deterministic responses. Mocking
   these APIs tests the mock, not the integration that's the entire
   point.
2. **Headless execution is unavailable.** Hammerspoon runs as a macOS
   GUI application attached to the user's display server; `hs.spaces`
   only behaves correctly inside a running HS instance with real
   displays. There is no CI surface short of a self-hosted macOS runner
   with displays attached.

The combination means most code touches `hs.*`, so unit-with-mock (L1)
and component-with-mock (L2) require substantial test doubles for
limited real coverage. The cheapest wins are at L0 (guards on the repo
itself) and L6 (live integration via `hs -c` on a multi-display host).
Contract tests (L3) at the public-API boundary are also cheap and
high-value.

## Active Levels

Single canonical table for level status. Other sections in this doc
reference this table — do not restate ✅/🔄/❌ status symbols elsewhere.

| Level | Status | Rationale | Runner |
|-------|--------|-----------|--------|
| **L0** — Guards | ✅ Active | Repo conventions: lua syntax (via [luacheck] or `luac -p`; SKIP if neither on PATH), `docs.json` shape, version sync between `obj.version` and the latest release tag, README link integrity. Headless. Runs on any host without Hammerspoon. | `tests/run.sh L0` |
| **L1** — Unit | ✅ Active | 45 tests across 6 helpers: stateless (`compareVersions`, `isLegacyFlatSchema`), module-state-dependent (`getGroupKey`, `getTargetsFor`, `getDisplayLabel`), and `hs.settings`-backed (`nameForIndex` — via an in-memory `hs.settings` stub in `tests/L1/hs_stub.lua`). Implementation uses a minimal plain-Lua harness (per Deviations §1) and `debug.getupvalue` introspection on the loaded init.lua to access local helpers without modifying the source. State-dependent helpers are seeded via `debug.setupvalue` on `positionToUUID` / `uuidToPosition` / `totalScreens` / `namesLoaded` before each fixture. | `tests/run.sh L1` |
| **L2** — Integration | 🔄 Not yet | Scope is internal wiring within a component. The Spoon is a single file with no internal component boundaries that would benefit from intra-domain integration tests. | (n/a) |
| **L3** — Contract | ✅ Active | Public API surface is small and stable: `:start`, `:stop`, `:status`, `:isEnabled`, `:toggle`, `:bindHotkeys`, `:showNames`, `:renameCurrentSpace`. Asserts methods exist with correct types and `:status()` returns the spec'd 12-key shape (see L3 Contract Spec below). Does NOT verify chaining (`return self`) — that would require calling stateful methods on the live Spoon. Test ASSUMES Spoon is already `:start()`-ed; SKIPs with an actionable message if not. Does NOT itself call `:start()` or `:stop()`. Runs inside Hammerspoon via `hs -c`; does NOT require multiple displays — single-display hosts get degenerate values (e.g. `positionMap = {[1] = uuid}`) but shape/type checks still pass. | `tests/run.sh L3` |
| **L4** — Workflow | 🔄 Not yet | Multi-component user stories don't apply to a single-file Spoon. | (n/a) |
| **L5** — E2E mocked | 🔄 Not yet | Mocking `hs.spaces.*` from inside Hammerspoon is possible but high-cost; the conceptual gap to L6 is small (just the actual `gotoSpace`). | (n/a) |
| **L6** — E2E live | ✅ Active | The actual sync engine: dispatch → poll → verify → CLEAR. Runs inside Hammerspoon on a multi-display host. Drives a known `gotoSpace`, asserts on `state.lastVerifierResult.mismatches == {}` via `:status()`. **Will briefly switch Spaces on the test host's displays** (duration: see Operational Notes § SLEEP_BETWEEN sizing). See L6 Sub-Tiers section below for sub-tier breakdown. | `tests/run.sh L6` |
| **L6h** — Human-in-loop | ✅ Active | Sub-tier of L6 for scenarios where the trigger cannot be emulated via `hs.spaces.gotoSpace` because Mission Control silently drops a second `gotoSpace` while SpacesSync's chain is in flight (see `dev-docs/hammerspoon-and-spaces-quirks.md` § Rapid `gotoSpace()` drops, L6 testing footnote). The runner prints structured instructions, waits for the user to perform a real trackpad swipe (or other real input), then asserts on `:status().lastVerifierResult`. Replaces the prose-only "v3 actual" column in the manual checklist for those scenarios with programmatic assertions. **INTERACTIVE** — requires a human at the terminal. | `tests/run.sh L6h` |
| **L7** — Browser | ❌ N/A | No web UI. |
| **L8** — GUI | 🔄 Not yet | Could verify popup canvas appearance via screenshot diffing. Overkill for a 4-row `hs.canvas` popup. |

## L3 Contract Spec

The `:status()` return shape (12 keys; canonical authority is `obj:status()`
in `Source/SpacesSync.spoon/init.lua` — if that method changes, this
table must be updated alongside the L3 test):

| Key | Type | Notes |
|---|---|---|
| `enabled` | boolean | `:start()` succeeded, watcher armed |
| `osBlocked` | boolean | env or Accessibility check failed |
| `syncInProgress` | boolean | sync chain mid-flight |
| `chainGeneration` | number | monotonically-increasing token (item 0a) |
| `activeChainTimers` | number | count of chain-owned hs.timer handles (poll timers + watchdog) |
| `totalScreens` | number | from `hs.screen.allScreens()` |
| `positionMap` | table | shallow copy of position → UUID |
| `syncGroups` | table | shallow copy of `obj.syncGroups` |
| `lastActiveSpaces` | table | shallow copy of UUID → SpaceID baseline |
| `lastVerifierResult` | table or nil | `{ timestamp, mismatches }`; each `mismatches[i]` has `{ uuid, kind }` where `kind` is `"wrong-space"` / `"vanished"` / `"appeared"`; entries with `kind == "wrong-space"` additionally have `expectedIdx` and `actualIdx` fields (other kinds do NOT have them — assert conditionally). Whole record is nil if no chain has run. |
| `pollTimeout` | number | current `obj.pollTimeout` |
| `pollInterval` | number | current `obj.pollInterval` |

## L6 Sub-Tiers (single-machine adaptation)

The canonical policy defines L6a/L6b/L6c sub-tiers for distributed
systems (Spark 049). For SpacesSync as a single-machine project:

| Sub-tier | Status here |
|----------|-------------|
| **L6a — Smoke** | Folded into the runner's preflight. The check `spoon.SpacesSync ~= nil and spoon.SpacesSync.start ~= nil` proves only that `hs.loadSpoon` ran; it does NOT prove `:start()` succeeded. The L3 contract test (which asserts `state.enabled = true` and the populated position map) is the stronger gate for "Spoon initialized correctly." If Hammerspoon is unresponsive the `hs -c` invocation fails outright. |
| **L6b — Assembly** | Trivially satisfied. The Spoon is one file symlinked into `~/.hammerspoon/Spoons/SpacesSync.spoon/` via `install.sh`. If preflight + L3 pass, assembly passed. |
| **L6c — Journey** | Non-trivial. The active sync chain — what the user actually triggers — is what L6 tests. |
| **L6h — Human-in-loop** | SpacesSync-specific extension (not part of the canonical Spark 049 sub-tier set). Tests whose trigger requires a real input device (trackpad swipe, hotkey on a specific display, accessibility revoke in System Settings) that `hs.spaces.gotoSpace` and `hs -c` cannot emulate. Same probe/arm/assert harness as L6, with two added user-prompt phases between arm and assert. See `tests/L6h/run.sh` and the "L6h scenarios" sub-section below. |

For SpacesSync, "L6" in this doc means L6c (and "L6h" means the human-in-loop tier).

### L6h scenarios

L6h fills the gap left by manual-checklist scenarios that can't be
driven from `hs -c` because of the
[gotoSpace-mid-chain-drop quirk](hammerspoon-and-spaces-quirks.md).
The L6h runner prints structured instructions, fires an automated
"first" action (often a `gotoSpace`), prompts the user to perform the
manual "second" action (e.g. a trackpad swipe), then asserts on
`:status().lastVerifierResult` after a chain settle. Each scenario
costs ~30 seconds of human attention and gives full programmatic
assertions on the outcome.

Scenarios currently in `tests/L6h/`: none. (scenario-05 was originally
prototyped here as human-in-loop, then promoted to fully-automated L6
once we discovered that AppleScript-via-System-Events
(`tell application "System Events" to key code 124 using {control
down}`) drives Mission Control's space-switch hotkey where
`hs.eventtap.keyStroke` does not. See `tests/L6/scenario-05-mid-chain-reswipe.lua`
for the AppleScript-based version, and `dev-docs/hammerspoon-and-spaces-quirks.md`
§ "Driving Mission Control hotkeys programmatically" for the input-path
distinction.)

Candidate scenarios for future L6h port (from manual-checklist):
* Group B #6 — user swipes a target display mid-chain.
  Status: may also be promotable to L6 if the AppleScript keystroke
  trick works for a TARGET display (cursor placement on target,
  fire ⌃-rightArrow during the chain's poll cycle for that target).
* Group B #7 — user swipes an independent (non-sync-group) display mid-chain.
* Group E #22 — accessibility revoked at `:start` (user toggles
  System Settings → Privacy & Security → Accessibility).

L6h gating: requires BOTH `SPACESSYNC_L6=1` (because the test
dispatches `gotoSpace` in its arm phase) AND `SPACESSYNC_L6H=1`
(explicit acknowledgement that the run is interactive). The gates
are enforced at a single point in `tests/run.sh` — Deviations §5
applies to both.

## Cumulative `_inclusive` Runners

Per the canonical SKILL.md §Tiered Test Runners, `_inclusive` runners
include every level at or below the named one. Any `_inclusive`
invocation expands the full prefix chain and silently skips inactive
levels — so `tests/run.sh L2_inclusive` is effectively a no-op beyond
running L0.

For SpacesSync's four active levels:

| Command | Levels | Notes |
|---------|--------|-------|
| `tests/run.sh L1_inclusive` | L0 + L1 | Headless; no Hammerspoon needed |
| `tests/run.sh L3_inclusive` | L0 + L1 + L3 | Pre-commit equivalent; Hammerspoon must be running |
| `tests/run.sh L6_inclusive` | L0 + L1 + L3 + L6 | Pre-release equivalent; switches Spaces (see Active Levels L6 row); requires `SPACESSYNC_L6=1` (see Deviations §5) |
| `tests/run.sh L6h_inclusive` | L0 + L1 + L3 + L6 + L6h | Full interactive validation; requires `SPACESSYNC_L6=1` AND `SPACESSYNC_L6H=1`; ~30 s/scenario of human attention |
| `tests/run.sh` (no arg) | L0 + L3 | Default. "Safe" = no Spaces disruption (still requires HS) |

Bare-level invocations (`tests/run.sh L3`, `tests/run.sh L6`) exist for
debugging a single level in isolation but are not the recommended path —
prefer the cumulative form.

## Test Layout

Level-first directory layout, single-domain project. Current shape:

```
tests/
├── run.sh           # dispatcher — cumulative-level orchestrator; checks SPACESSYNC_L6
├── L0/              # guards (shell-based, headless)
│   ├── check-syntax.sh
│   ├── check-docs-json.sh
│   ├── check-version-sync.sh
│   └── run.sh
├── L1/              # unit tests (plain Lua + minimal harness, no hs runtime)
│   ├── helpers.lua  # describe/it/eq/tableq/throws etc.
│   ├── hs_stub.lua  # minimal `hs` shell so init.lua loads
│   ├── loader.lua   # debug.getupvalue accessors for init.lua locals
│   ├── *_spec.lua   # one spec per helper
│   └── run.sh
├── L3/              # contract (Lua, runs inside hs via hs -c)
│   ├── contract.lua
│   └── run.sh
└── L6/              # E2E live (Lua, runs inside hs + multi-display)
    ├── scenario-*.lua  # automates manual-test-checklist scenarios
    └── run.sh
```

Each L6 test file should cite the `dev-docs/manual-test-checklist.md`
scenario it automates in its header comment. The checklist is the
parent set; automated coverage grows by automating one scenario at a
time.

**L6 test design note.** Each L6 test's probe phase MUST read
`positionMap` and `syncGroups` from `:status()` to discover a viable
trigger/target pair at runtime — picking a trigger whose current
Space index has somewhere to go (i.e., not the last index, and the
target display has a Space at the candidate destination index).
Tests SKIP if no viable pair exists rather than hard-coding display
positions (which would silently pass or fail under non-default
arrangements).

## Quick Reference for Agents

| When | Run |
|------|-----|
| Edited a doc / version bump / quick local change | `tests/run.sh L0` |
| Edited a pure-Lua helper (`compareVersions`, `getGroupKey`, etc.) | `tests/run.sh L1_inclusive` |
| Edited public API surface (`:start`, `:stop`, `:status`, etc.) | `tests/run.sh L3_inclusive` |
| Edited the sync chain (`runSyncChain`, `verifyEndState`, polling logic) | `SPACESSYNC_L6=1 tests/run.sh L6_inclusive` (see Deviations §5) |
| Pre-release | `SPACESSYNC_L6=1 tests/run.sh L6_inclusive` + manual checklist sample |

## Gating

This project does not have CI. Gating is currently advisory:

- **Pre-commit** — `tests/run.sh L1_inclusive` (L0 + L1; headless, fast)
- **Pre-merge** — `tests/run.sh L3_inclusive` (adds L3 — needs HS running)
- **Pre-release** — `SPACESSYNC_L6=1 tests/run.sh L6_inclusive` (full ladder; switches Spaces — see Deviations §5 for the env-var gate)

When CI is added (future), `L3_inclusive` is the recommended PR gate.
`L6_inclusive` requires a multi-display test host and would need a
self-hosted runner; not yet justified.

## Test Lifecycle Categories

Per the canonical vocabulary (`~/dev/autocoder_v3/vocabulary/testing-vocabulary.md`):

| Category | Definition | This project |
|---|---|---|
| **permanent** | Runs at every gate trigger; never deleted unless workflow removed | All tests in active levels are permanent |
| **ephemeral** | Written to drive out behavior; deleted when stable and L1–L4 covered | None yet |
| **interval** | Runs on schedule, not every merge | None yet |

Canonical policy scopes these categories to L5–L6. SpacesSync applies
them across all active levels (L0, L3, L6) — a small extension noted
in Deviations §6 below.

## Deviations from Canonical Policy

1. **No pytest, no busted (yet).** The canonical policy assumes pytest
   with a directory-auto-marking conftest hook. This project uses shell
   + `hs -c` because (a) the integration boundary is a CLI-driven
   runtime, not a Python module, and (b) installing busted would be the
   first Lua dev dependency. If/when L1 tests land, busted is the
   planned framework.
2. **L0 included in `_inclusive` chains.** The canonical conftest
   reference (`local-testing-strategy/SKILL.md`) defines `_LEVELS`
   starting at L1 — the conftest silently omits L0 from `_inclusive`
   expansion rather than taking an explicit position. The canonical
   runner-table in `testing-policy/SKILL.md` explicitly includes L0
   in `L1_inclusive`. SpacesSync follows the runner-table convention
   — L0 is fast, headless, and always relevant — and implements
   cumulative semantics in shell rather than via pytest marker
   expressions.
3. **L6 restore via real `gotoSpace`, not internal snapshot.** The L6
   test stashes pre-test active SpaceIDs at probe time and, after
   assert, dispatches `hs.spaces.gotoSpace(triggerStart)` to drive
   Mission Control back to the original Space. That dispatch itself
   triggers a sync chain (the trigger is in a sync group), so target
   displays also follow back. No internal Lua state is snapshotted or
   restored — `state.lastActiveSpaces` updates organically as the
   restore chain runs. **Critical sequencing:** the assert phase MUST
   read `:status().lastVerifierResult` BEFORE dispatching the restore,
   because the restore chain's verifier overwrites
   `state.lastVerifierResult` when it completes. Restore is
   fire-and-forget; the test does NOT assert on its outcome and
   restore failure does NOT count as test failure.
4. **Gating defaults adapted to the active set.** Canonical defaults
   per `ac-testing-policy/SKILL.md` § Gating Policy are pre-commit
   L0+L1+L2; the quick-reference subset at `~/.claude/skills/testing-policy/SKILL.md`
   shows the same table with L0 omitted (the quick-ref is explicitly
   "a subset" per its own header, so `ac-testing-policy/SKILL.md` is
   the higher authority on level inclusion). Pre-merge is L3+L4 with
   L5 conditional on D2 strategy; pre-deploy is L6. SpacesSync has no
   active L1/L2/L4/L5, so the project's gating is L0 → L3_inclusive
   → L6_inclusive. This is a substantive deviation, not just a
   tooling difference.
5. **L6 runs against the live Hammerspoon, not a sandbox.** Canonical
   policy requires L6 to run in an isolated instance ("minimum
   isolation: dedicated instance of the external system"). macOS does
   not allow multiple Hammerspoon instances to coexist, and there is
   no self-hosted CI runner. L6 runs against the user's running HS
   with the live Spoon attached. Mitigations: (a) `SPACESSYNC_L6=1`
   env var required to invoke L6; the `tests/run.sh` dispatcher
   checks this and aborts if unset, BEFORE delegating to
   `tests/L6/run.sh`. The Spoon itself and individual L6 test files do
   NOT check the env var — single gate point in the top-level
   dispatcher. (b) Restore phase drives Spaces back to pre-test state
   (see §3 above). (c) Operational Notes below document recovery for
   crashes mid-test.
6. **Test lifecycle categories applied beyond L5–L6.** Canonical
   policy scopes `permanent`/`ephemeral`/`interval` to L5–L6 tests
   assigned by a human (per `ac-testing-policy/SKILL.md` line 454
   "Test Lifecycle Categories (L5–L6, assigned by human)" and
   MANIFESTO.md line 678 "L5 and L6 tests have three lifecycle
   categories, assigned by the human"; the vocabulary file defines
   the terms but does not scope them). SpacesSync applies the same vocabulary to L0/L3 tests
   (all currently "permanent"). Harmless extension; flagged so a
   future reader doesn't mistake it for canonical alignment.

## Operational Notes

### `hs -c` blocks the runloop until its chunk returns *(Verified — observed during prototype iteration in session `88c2fe41-0431-46cf-802e-3c38ed600266`)*

A single `hs -c` invocation runs Lua synchronously and prevents the
Hammerspoon runloop from pumping until the chunk returns. A test cannot
busy-wait inside one `hs -c` for an async watcher / poll-timer callback
to fire — the very thing it's waiting for is blocked by the wait. L6
tests are therefore split into shell-orchestrated phases:

1. **probe** — preflight + plan, stash plan in `_G[PLAN_KEY]`
2. **arm** — dispatch trigger, return immediately
3. **assert** — read `:status()` once (capture `lastVerifierResult`
   BEFORE restore), validate, restore Spaces

`tests/L6/run.sh` owns the probe/arm/sleep/assert orchestration for L6
tests: it shell-sleeps between arm and assert so the runloop pumps the
watcher, the chain, and the verifier in the meantime. The top-level
`tests/run.sh` dispatcher only handles `SPACESSYNC_L6=1` gating and
delegation; it does NOT manage L6 timing or phases itself.

**`SLEEP_BETWEEN` sizing** mirrors the watchdog bound from `init.lua`'s
`startWatchdog`:

```
SLEEP_BETWEEN ≥ max(8, 3 × pollTimeout + 2)   (seconds)
```

The `3` is hard-coded in the watchdog and does NOT scale by actual
target count — the bound is sized for the worst-case 4-display sync
group (3 targets). At default `pollTimeout = 2.0`, the bound is 8 s.
For users who lower `pollTimeout` (e.g., to 1.0), the bound is still
8 s. For users who raise `pollTimeout` (e.g., to 4.0), the bound
becomes 14 s; SLEEP_BETWEEN must follow.

The runner may either hard-code the formula or read `pollTimeout` from
`:status()` and compute. A literal-default 4-second sleep is too tight
under any pollTimeout (would race the watchdog); use 8 s as the floor.

This `hs -c` runloop quirk also applies outside testing — anyone using
the CLI to drive Hammerspoon should understand it. Mirrored in
`dev-docs/hammerspoon-and-spaces-quirks.md`.

### `hs.ipc` rejects rapid back-to-back invocations *(Observed — saw repeatedly during prototype iteration in session `88c2fe41-0431-46cf-802e-3c38ed600266`; not isolated to a single trigger)*

`hs -c` calls fired faster than ~100 ms apart sometimes return:

```
hs.ipc: Instance of [...] already recursing, refusing request.
```

and the inner Lua chunk does not run. If the rejected chunk was
mid-state-mutation, the running Spoon/script can be left in a
half-state with `syncInProgress=true` and no live chain to clear it.
Recovery:

```bash
hs -c 'spoon.SpacesSync:stop(); spoon.SpacesSync:start()'
```

The L6 runner spaces invocations ≥ ~100 ms apart; the issue is mostly
relevant when iterating tests by hand or when shell parallelism causes
overlapping invocations.

### Recovery procedure for L6 test failures

If L6 fails with `"chain still in progress at assert time"`:

1. First, check for a pre-existing stuck state:
   `hs -c 'return spoon.SpacesSync:status().syncInProgress'`. If
   `true`, you hit the `hs.ipc` recursion bug above. Reset via
   `:stop(); :start()` and re-run.
2. Otherwise, the chain genuinely didn't settle in time. Raise
   `SLEEP_BETWEEN` per the `max(8, 3 × pollTimeout + 2)` formula
   above.

If a test crashes between arm and assert (leaving Spaces in a
mid-transition state):

1. Manually switch each affected display back to the desired Space via
   Mission Control gestures, then
2. Reset the Spoon: `hs -c 'spoon.SpacesSync:stop(); spoon.SpacesSync:start()'`.

The L6 test's `restore()` phase is best-effort; a crash before it runs
leaves the displays wherever the chain dropped them.

## Open Questions

**J1: When to activate L1.** ✅ Resolved — L1 went active during
the test-suite buildout (the user overrode the "Not yet" default
and asked for ground-up TDD starting at L1). 35 tests across 5
helpers shipped via the plain-Lua harness + `debug.getupvalue`
approach (no init.lua modification, no busted dep). The activation
trigger framing is now historical; new pure-Lua helpers should get
L1 coverage at write time, not "after a regression."

**Should L8 GUI tests verify popup canvas rendering?** No. Four rows
of styled text via `hs.canvas` doesn't warrant a screenshot-diffing
pipeline.

**Should `tests/run.sh` be turned into a Makefile?** Defer until CI
exists and benefits from `make test` semantics.

## References

- This project: `dev-docs/manual-test-checklist.md` — manual test checklist (count lives in Status section)
- This project: `dev-docs/hammerspoon-and-spaces-quirks.md` — mirrors the `hs -c` runloop note

Canonical sources are listed at the top of this document.
