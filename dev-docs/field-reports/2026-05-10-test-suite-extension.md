---
date: 2026-05-10
outcome: corrections
agent: direct session (a42bdc08-8d01-4413-a236-40b2efb75241)
---

## Field Report — SpacesSync test suite extension (2026-05-10 to 2026-05-11)

**Goal:** Extend the SpacesSync test suite past the foundation laid in
`78bde1e` — add scenario-08 (mid-chain `:stop`), an L0 link-check guard,
an engram entry, then "do more deferred items if they're worth doing."

**Mode:** Spike (the policy was converged but the implementation
surface was novel; lots of empirical discovery)

**Outcome:** corrections — multiple canonical docs were incomplete,
specifically the inferred conclusion that scenario #5 must stay
manual-checklist-only.

### Summary

Eight commits landed on `main` extending the suite:

| Tier | Before | After |
|---|---|---|
| L0 | 3 guards | 4 guards (added readme-links check) |
| L1 | 35 tests, 5 helpers | 45 tests, 6 helpers (added `nameForIndex` + in-memory `hs.settings` stub) |
| L3 | 1 contract | 1 contract (unchanged) |
| L6 | 1 scenario | **3 scenarios** (added scenario-08 + scenario-05) |
| L6h | (didn't exist) | infrastructure built, scenarios promoted to L6, no current users |

The most consequential discovery: `hs.eventtap.keyStroke` does NOT
reach Mission Control's system-hotkey handler, but
`hs.osascript.applescript` with `tell application "System Events"` DOES.
This let scenario-05 (mid-chain user re-swipe) be fully automated
instead of staying as a human-in-loop test.

### Corrections to canonical docs

#### 1. `gotoSpace` silently dropped mid-chain — workaround exists *(quirks doc + test-strategy)*
**Confidence:** Verified

**What the doc said (in commit `62b9701`):**
> simulating "user re-swipes mid-chain" (manual-checklist Group B #5)
> via the AX path is therefore NOT reliably automatable — a real
> trackpad swipe goes through a different input path that Mission
> Control prioritizes. Conclusion: scenario #5 stays manual-checklist-only.

**What's actually true:**
There IS a programmatic input path that reaches Mission Control:
`hs.osascript.applescript([[tell application "System Events" to key
code 124 using {control down}]])`. We tested both:

| Approach | Moves Space? |
|---|---|
| `hs.spaces.gotoSpace(sid)` mid-chain | NO — silently dropped |
| `hs.eventtap.keyStroke({"ctrl"}, "right", 0)` | NO — fires without error, MC doesn't receive |
| AppleScript-via-System-Events ⌃-rightArrow | **YES — reliably** |

**Already applied in commit `8c0f749`:**
- Quirks doc § "Rapid gotoSpace() calls get silently dropped" L6
  footnote updated with the workaround.
- New top-level quirks doc section "Driving Mission Control hotkeys
  programmatically" with the input-path table and the canonical
  pattern (cursor placement → 150 ms wait → AppleScript → restore cursor).
- Strategy doc Status table: L6 now 3 of 30 scenarios; L6h marked
  "infrastructure ready, no scenarios registered."
- scenario-05 promoted from L6h to L6.

#### 2. Test-owned config save/restore is a viable pattern *(test-strategy doc)*
**Confidence:** Verified

**What the doc was silent on:**
The strategy doc described L6 tests as reading the live `obj.syncGroups`
and discovering a viable pair within it. No mention of tests OWNING
their required configuration.

**What's actually viable:**
A test can save the current `obj.syncGroups` (and timing knobs like
`pollInterval`, `pollTimeout`), swap in its required values, run, and
restore in a `cleanup()` phase. This makes tests independent of the
host's live configuration. scenario-05 needs `pollInterval=3.0` to
keep the chain in flight long enough for the disrupt phase; scenarios
2/3 will need 3-display and 4-display syncGroups.

**Status:**
The pattern is implemented per-scenario in scenario-05. NOT yet
generalized into the L6 dispatcher. Surface for #4 ("dispatcher
refactor") in this session's "what's next" — generic save/restore
of `M.required_*` fields would let every future scenario declare
config needs without each one reimplementing save/swap/restore.

#### 3. L1 testing of `hs.settings`-touching helpers needs a real stub *(test-strategy doc L1 row)*
**Confidence:** Verified

**What the doc said:**
> Other helpers (`nameForIndex` etc.) transitively touch `hs.*`;
> not yet covered.

**What's actually true:**
With a real in-memory `hs.settings` stub (8 lines of Lua replacing
the catch-all `noopNamespace()`), `nameForIndex` becomes L1-testable.
The Lua catch is that the test fixture must reset the once-only
`namesLoaded` flag between fixtures, otherwise the in-memory cache
wins and storage mutation between calls is invisible.

**Already applied in commit `1b6c583`:**
Strategy doc L1 row updated; 10 new assertions across the 6th helper.

### What worked well

- **Iterative-verification discipline.** Six rounds of L6h scenario-05
  design hardening before promoting to L6. Each round had a clear
  outcome (broken vs. progress) tied to a specific discovery.
- **The disrupt-phase dispatcher.** Scenario-08 introduced it; scenario-05
  reuses it verbatim. The grep-based detection (`grep '^function M.disrupt'`)
  remains lightweight and self-documenting.
- **`tests/L6h/last-run.log`.** Made the pane lifecycle irrelevant —
  the result survives even if the user closes the pane. Wish I'd
  added this in v1 instead of v5.
- **Hammerspoon console as a debugger.** When scenario-05 was
  failing with "0 mismatches", grepping the console for SYNC lines
  produced an unambiguous timeline (chain ran at T0, user swiped at
  T0+44s → second chain, not GATE_RUNNING drop). This was the
  diagnostic that broke the case open.

### What didn't work or was surprising

- **`hs -c` IPC backoff is fragile.** Multiple times during the
  session, rapid `hs -c` calls (faster than ~100 ms apart) caused
  Hammerspoon to silently hang subsequent invocations. Workaround:
  back off 60-90 s. Already documented in quirks doc § hs.ipc
  recursion. This is a real productivity tax during interactive
  iteration.
- **`pollTimeout` is the max, NOT the chain duration.** I spent one
  v6 cycle bumping `pollTimeout=8.0` thinking it would stretch the
  chain. It didn't — the chain ends as soon as the target lands.
  `pollInterval` is the load-bearing knob (chain can't detect
  target landing until next poll tick, so chain duration ≥ pollInterval).
  This was non-obvious from the docs; should be called out somewhere.
- **L6h ceremony bloat.** I added two Enter prompts (placement
  confirmation + fire when ready), which felt safe but turned out
  to be more friction than the user needed. The v9 design with a
  single Enter + 4 s sleep + auto-detection felt better.
- **Display sleep mid-iteration.** `pmset displaysleep=0` is set
  per memory `project_displaysleep_dock_fix.md`, but Hammerspoon
  saw 1 screen at one point. Confirmed by manual wake-up, but a
  documented "if you see 1 screen but expected N, your displays
  slept" recovery line would have saved me a confused minute.

### Patterns discovered

#### Input-path layering for macOS automation

Macros / hotkeys can be synthesized from inside Hammerspoon via at
least three input paths:

| Path | API | Reaches frontmost app? | Reaches system hotkey handler? |
|---|---|---|---|
| App-routed keystroke | `hs.eventtap.keyStroke()` | YES | NO |
| AX automation | `hs.spaces.gotoSpace()`, `hs.axuielement` | (varies) | (varies, often dropped during transitions) |
| System Events scripting | `hs.osascript.applescript("tell System Events ...")` | YES | YES |

The middle layer (AX) is where most Hammerspoon docs/examples live, so
it's tempting as "the way." For system hotkeys, you want the top
layer. This is now in the quirks doc as a generalizable principle.

#### Test-owned configuration as a generalizable pattern

Tests should declare their config requirements via convention
(e.g. `M.required_sync_groups`, `M.required_pollInterval`). The
dispatcher (or each test's probe + cleanup) saves the current value,
swaps in the required value, runs, and restores. This makes tests
independent of the host's live configuration AND independent of each
other (a test that bumps `pollInterval` doesn't pollute the next
test's environment, as long as restore happens before the next test
starts).

#### Persistent result logs survive pane lifecycle

Interactive tests that run in a separate pane (or as a subprocess)
should write a durable result log to a known path. The calling
agent reads the log post-hoc instead of racing the pane's lifecycle.
`tests/L6h/last-run.log` is the canonical example; this should be
the default for any test runner that prints structured per-phase
results to stdout.

### Open loops (handed off to future sessions)

- **Scenarios 6/7 (target swipe / independent swipe mid-chain)** —
  same AppleScript pattern as scenario-05, different verifier
  assertions. Probably promotable to L6.
- **L6h tier is currently empty** — infrastructure preserved for
  scenarios that genuinely require human input (Group E #22
  accessibility revoke remains a likely user).

### Scenario 16 — deferred (forced-timeout coverage gap)

**Status:** removed from `tests/L6/` after iterative-verification
failures during this session's tail (commits afe7946, cac81ec
land; scenario-16 prototype removed alongside the next commit).

**Why it's hard to automate:**

1. `pollTimeout=0.01` forces the chain to time out (per design).
2. After timeout, the chain calls `chainEnd` → `verifyEndState` →
   `lvr` is populated with the wrong-space mismatch.
3. Mission Control eventually finishes the target's `gotoSpace`
   (~500 ms-1 s later).
4. The late landing fires the watcher, which (since
   `syncInProgress=false` after the first chain's `chainEnd`)
   starts a SECOND chain.
5. Second chain dispatches trigger as target (since the second
   chain's "trigger" is the original target). Trigger is already at
   destination — `current == expected` → skip dispatch → straight
   to `chainEnd` → verifier runs CLEAN.
6. `lvr` is overwritten with the clean second-chain result. By the
   time `assert_` reads it, the timed-out mismatch is gone.

The capture window is on the order of 100 ms — too tight for
`hs -c` IPC polling (which adds ~50-100 ms per round trip plus
runloop-blocking `usleep`).

**Tried and rejected:**

* In-test `usleep` polling — blocks the runloop, prevents the very
  chain we're waiting for from progressing.
* `hs.timer.doEvery` callback inside `M.arm` — the timer fires
  only 6 times (0.3 s) then stops without explanation. Likely the
  Hammerspoon `hs -c` boundary semantics don't keep timer closures
  alive across invocations as expected. Worth a separate
  investigation if revisited.
* `pollInterval=0.005` (5 ms) — caused a Hammerspoon IPC hang
  (runaway timer cycle or watchdog interaction). Not safe to use.

**Viable approach for a future attempt (not implemented):**

After arm dispatches `gotoSpace`, shell-sleep ~800 ms, then have
the test invoke `spoon.SpacesSync:stop()` to PREVENT the second
chain from starting. This freezes `lvr` at the first-chain
result. Then `:start()` to restore. Sequence:

```
arm:        hs.spaces.gotoSpace(dest_sid)
shell:      sleep 0.8
disrupt:    spoon.SpacesSync:stop()      -- locks in first lvr
shell:      sleep 0.2
assert:     read lastVerifierResult; should have target wrong-space
cleanup:    spoon.SpacesSync:start()     -- restore
```

The 800 ms is a magic number; could be tuned by polling
syncInProgress between two short shell sleeps. Worth ~30 minutes
of focused work if/when forced-timeout coverage becomes important.

**Coverage gap:** the verifier's per-target timeout path
(`verifyEndState` flagging a wrong-space when chain's poll
deadline elapses before target lands) is now exercised only by
manual-checklist scenario #16. The chain's chainGeneration bail
path (when `:stop()` interrupts a chain) IS exercised by L6
scenario-08.
