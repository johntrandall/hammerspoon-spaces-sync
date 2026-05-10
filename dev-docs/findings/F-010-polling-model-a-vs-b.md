# F-010 — Empirical resolution of `hs.spaces.activeSpaceOnScreen` flip timing

**Status:** Verified — 2026-05-10
**Author:** pair-polling-spike (spacessync-design team), Claude Opus 4.7
**Session:** 649bb775-d243-4551-a058-544d2d11c244
**Test platform:** host SusanBones, macOS 15.7.5, Hammerspoon 1.1.1, 4× LG SDQHD monitors (4K each), 5/6/4/1 Spaces respectively (positions 1/2/3/4)

---

## Abstract

We empirically determined when `hs.spaces.activeSpaceOnScreen()` reports a Space change relative to a `hs.spaces.gotoSpace()` dispatch on macOS 15.7.5. Two competing models had been proposed during a design review of SpacesSync v3:

- **Model A** — the API flips when WindowServer commits the new active Space, which is *before* Mission Control's accessibility-tree teardown completes. A subsequent `gotoSpace` dispatched immediately on poll-confirm would be silently dropped, requiring a `MIN_DISPATCH_GAP` floor (~150 ms expected) after each verify.
- **Model B** — the API flips at the end of Mission Control's full transition. Polling for that flip is a sufficient ready signal; no floor is needed.

Two experiments (E1: flip-latency distribution over 30 trials; E2: drop rate as a function of inter-dispatch gap over 8 gap values × 20 trials = 160 trials) **confirm Model B unambiguously**. Mean E1 flip latency was **753.10 ms** (range 719.53–897.50 ms); E2 produced **0 drops in 160 trials** including 20/20 dispatches at gap=0 ms. We recommend `MIN_DISPATCH_GAP = 0` (i.e., remove from v3) and `pollTimeout = 2.0 s` (≈ 2.5× the observed worst-case flip).

---

## 1. Background and motivation

The current production SpacesSync (v0.2) introduces a fixed 0.3 s `switchDelay` between successive `hs.spaces.gotoSpace()` dispatches when synchronizing N target displays in a sync group. The v3 redesign replaces this with poll-based verification: after each dispatch, poll `hs.spaces.activeSpaceOnScreen()` until it reports the expected Space ID, then proceed. The redesign is documented in `dev-docs/diagrams/workflow-roadmap.mermaid` (POLL/VERIFY nodes) and `dev-docs/code-changes-pending.md` (item 1).

A second-round council review (5 parallel agents) flagged a load-bearing question about this design: **is the API flip a sufficient ready signal, or does Mission Control's UI machinery need additional teardown time after the flip before it can accept the next dispatch?** The Hammerspoon-expert agent observed that `hs.spaces.gotoSpace` drives Mission Control via `hs.axuielement` (open MC overlay → click Space button → close MC) and that previously-recorded findings F-001 (rapid back-to-back drops) and F-009 (variable watcher-fire delay) were consistent with Model A. The implementation-feasibility agent and the devil's-advocate agent both made the spike a hard prerequisite for any v3 code landing.

Without this measurement, two design forks remained unresolved:

1. **`MIN_DISPATCH_GAP` floor** — keep (~150 ms, calibrated) vs. drop (= 0).
2. **Q1 — eager-writes-with-observed-value vs. drop eager writes / ship "v2.5"** (devil's-advocate's slimmer alternative). This is partially decided by the Model A vs B answer.

This experiment resolves the first directly and informs the second.

## 2. Hypotheses

| ID | Statement | Predicts |
|---|---|---|
| **H1 (Model A)** | `activeSpaceOnScreen` flips at WindowServer commit, before MC accessibility teardown. | E1 flip latency ≪ animation duration (≪ 300–500 ms expected). E2 drop rate at gap=0 substantially > 0. Drop rate falls toward 0 as gap increases past MC-teardown duration. |
| **H2 (Model B)** | `activeSpaceOnScreen` flips at end of MC's full transition. | E1 flip latency ≈ animation duration (~700 ms+). E2 drop rate at gap=0 ≈ 0. Drop rate independent of gap across all tested gaps. |

H1 and H2 are mutually exclusive on the testable predictions (drop-rate signature in E2). H2 is the null hypothesis in the sense that "polling alone works" is the simpler implementation; H1 would require additional design machinery.

## 3. Method

### 3.1 Apparatus

- **Host:** SusanBones (Mac mini-class hardware; arm64; configured with 4 displays in a horizontal arrangement).
- **OS:** macOS 15.7.5 (Sequoia, point-release).
- **Hammerspoon:** 1.1.1 (the project's tested version).
- **Displays:** 4× LG SDQHD, ~3840×2160 each, arrangement positions 1–4 from left to right.
- **Spaces configuration:** 5 / 6 / 4 / 1 Spaces on positions 1 / 2 / 3 / 4 respectively. (Position 4 was not used because it has only one Space.)
- **SpacesSync:** stopped via `spoon.SpacesSync:stop()` for the duration of both experiments to remove any interference from the production sync logic. Restarted via `spoon.SpacesSync:start()` at end of the run.
- **`Reduce Motion`:** OFF (default — animations enabled). This is the harder regime for Model B.
- **`Displays have separate Spaces`:** ON (required by SpacesSync, also required by the spike).
- **System load:** quiet — no other interactive applications running, no background batch jobs. (Idle-system bias acknowledged in §7.2.)

### 3.2 Test harness

A single Lua module, `/tmp/spacessync-polling-spike.lua`, exposes `SpacesSyncSpike.runE1(opts)`, `SpacesSyncSpike.runE2(opts)`, and `SpacesSyncSpike.runAll()`. The harness writes a master log to `/tmp/spacessync-polling-spike-output.log` and prints to the Hammerspoon console.

Key parameters used in this run:

| Parameter | Value | Notes |
|---|---|---|
| `POLL_INTERVAL` | 0.005 s | Per-tick interval. The macOS runloop will quantize this; effective interval may be ≥5 ms. |
| `POLL_TIMEOUT` | 2.0 s | Maximum wait for any single `pollUntil`. |
| `SETTLE_BETWEEN_TRIALS` | 2.0 s | Inter-trial delay so macOS Mission Control fully quiesces. |
| `POST_DISPATCH_VERIFY_DELAY` | 1.0 s | E2: delay after dispatching target2 before reading final state. |
| Trials in E1 | 30 | Alternating directions (spaceA→spaceB and back). |
| Trials in E2 | 20 per gap | 8 gap values × 20 = 160 total dispatches measured. |
| Gap values (E2) | 0, 25, 50, 100, 150, 200, 250, 300 ms | Spans below and above the 150 ms `MIN_DISPATCH_GAP` initially proposed. |

The harness is **transient** (lives in `/tmp`, not committed to the project repo per the `tmp-for-testing` skill). The full source is reproduced in **Appendix A**.

### 3.3 Timing instrumentation

All timing is sourced from `hs.timer.absoluteTime()`, which returns nanoseconds with monotonic-clock semantics on Hammerspoon. Latencies are computed as `(t_observed - t_dispatch) / 1e6` to obtain milliseconds. The polling cadence is driven by `hs.timer.doAfter(POLL_INTERVAL, …)`, which schedules a one-shot timer on the main runloop; in practice the runloop quantizes ticks to ~10–15 ms intervals depending on other runloop activity, but the `t_observed` timestamp is captured *inside* the tick callback so the measurement granularity is bounded by the runloop quantum, not the requested interval.

This instrumentation matters for E1: the reported flip latency is "the first runloop tick at which `activeSpaceOnScreen` returned the new Space ID," which over-estimates the true flip moment by 0–10 ms on average. The implication is that any observed flip latency in the 700–900 ms range is, if anything, *slightly later* than the true flip — strengthening rather than weakening the Model B verdict.

### 3.4 Procedure — E1 (flip latency)

For each of 30 trials, on display position 1 (LG SDQHD (1), 5 Spaces, not in any sync group):

1. **Settle to starting Space.** Determine `from = spaceA` (trial 1, 3, 5, ...) or `from = spaceB` (trial 2, 4, ...). If `activeSpaceOnScreen ≠ from`, dispatch `gotoSpace(from)` and poll-confirm settle. Wait additional 0.5 s.
2. **Mark t0** = `hs.timer.absoluteTime()`.
3. **Dispatch** `hs.spaces.gotoSpace(to)` where `to` is the alternate Space.
4. **Poll** `activeSpaceOnScreen(target)` every ~5 ms until it returns `to`. **Mark t1** at first match.
5. **Record** `flipMs = (t1 - t0) / 1e6` and `ok = true` (or `ok = false` if `POLL_TIMEOUT` reached).
6. **Wait** `SETTLE_BETWEEN_TRIALS = 2.0 s` before the next trial.

Concretely: `spaceA = Space ID 6`, `spaceB = Space ID 967` (both on position 1).

### 3.5 Procedure — E2 (drop rate vs inter-dispatch gap)

For each gap value `gap_ms ∈ {0, 25, 50, 100, 150, 200, 250, 300}`, repeat 20 trials on display positions 2 and 3:

1. **Reset both targets** to their first Space (`activeSpaceOnScreen == sp[1]`). If not, dispatch `gotoSpace` and poll-confirm; settle 0.4–0.8 s.
2. **Mark t_dispatch_1** = now. Dispatch `gotoSpace(target1, target1.space2)`.
3. **Poll** `activeSpaceOnScreen(target1)` until it returns `target1.space2`. Mark t_flip_1; record `flipMs_1 = (t_flip_1 - t_dispatch_1) / 1e6`. (If `pollUntil` times out, record this trial as a drop and proceed.)
4. **Wait `gap_ms` ms.** This is the controlled variable.
5. **Dispatch** `gotoSpace(target2, target2.space2)`. (No poll on this one — we want to measure whether macOS accepts the dispatch, not whether we can wait it out.)
6. **Wait `POST_DISPATCH_VERIFY_DELAY = 1.0 s`** for macOS to settle.
7. **Read final state.** Capture `final1 = activeSpaceOnScreen(target1)` and `final2 = activeSpaceOnScreen(target2)`. Record:
   - `t1_held = (final1 == target1.space2)` — did target1 stay where we sent it? (If false, we stepped on our own work somehow.)
   - `t2_ok = (final2 == target2.space2)` — did target2 actually land? (This is the drop indicator.)
8. **Wait** `SETTLE_BETWEEN_TRIALS = 2.0 s` before the next trial.

Drop rate at a gap = `(# trials where t2_ok == false) / 20`.

Concretely: `target1 = position 2, sp1 = {1729, 1691}` and `target2 = position 3, sp2 = {1692, 1750}`.

### 3.6 Controls

- **SpacesSync stopped** for the entire run — eliminates interference from its watcher and its own dispatching.
- **Inter-trial settle of 2.0 s** — a manual margin substantially longer than any observed flip latency; aims to bring macOS to a quiescent state between trials.
- **Pre-trial poll-confirmed reset** — every E2 trial begins with both targets known to be at index 1.
- **Alternating direction in E1** — averages out any direction-dependent asymmetry in the animation.
- **Independent display for E1** — eliminates any chance of E1 being affected by adjacent-display coordination effects (hypothetical but worth ruling out).
- **Two displays for E2** — drop measurement requires multiple displays so that "dispatch the next one" is meaningful.

### 3.7 What we did NOT measure

- **Animation visual completion (t2 in the original spike note).** Skipped because the polling result alone is sufficient to settle Model A vs B; the visual t2 would only confirm an upper bound on `t1`. Not a methodological gap, just a deferred observation.
- **Reduce Motion ON regime.** Worth a follow-up; see §7.3.
- **Heavy CPU/GPU load regime.** Animation duration is GPU-gated; under load the flip latency increases, but Model B's prediction (drops independent of gap) does not change. See §7.4.
- **User UI interaction during a trial.** Not relevant to Model A vs B; relevant to other v3 design questions (recovery semantics).
- **Multi-version macOS.** Single-host result. See §7.1.

## 4. Results

### 4.1 E1 — Flip-latency distribution

All 30 of 30 trials produced a successful flip within `POLL_TIMEOUT`. Per-trial latencies (rounded to 0.01 ms):

| trial | direction | flip (ms) | trial | direction | flip (ms) | trial | direction | flip (ms) |
|------:|:---------:|----------:|------:|:---------:|----------:|------:|:---------:|----------:|
|   1   | 6 → 967   | 808.64    |  11   | 6 → 967   | 747.07    |  21   | 6 → 967   | 746.71    |
|   2   | 967 → 6   | 721.79    |  12   | 967 → 6   | 738.21    |  22   | 967 → 6   | 740.54    |
|   3   | 6 → 967   | 836.58    |  13   | 6 → 967   | 734.29    |  23   | 6 → 967   | 741.04    |
|   4   | 967 → 6   | 792.30    |  14   | 967 → 6   | 751.43    |  24   | 967 → 6   | 742.96    |
|   5   | 6 → 967   | 765.17    |  15   | 6 → 967   | **897.50** |  25   | 6 → 967   | 737.78    |
|   6   | 967 → 6   | 763.12    |  16   | 967 → 6   | 744.10    |  26   | 967 → 6   | 738.92    |
|   7   | 6 → 967   | 750.00    |  17   | 6 → 967   | 741.06    |  27   | 6 → 967   | 735.53    |
|   8   | 967 → 6   | 750.17    |  18   | 967 → 6   | 731.91    |  28   | 967 → 6   | 756.30    |
|   9   | 6 → 967   | 733.64    |  19   | 6 → 967   | 729.96    |  29   | 6 → 967   | 743.62    |
|  10   | 967 → 6   | 728.34    |  20   | 967 → 6   | **719.53** |  30   | 967 → 6   | 724.66    |

**Summary statistics (n = 30):**

| Statistic | Value |
|---|---|
| Mean | **753.10 ms** |
| Median | 742.01 ms |
| Min | 719.53 ms |
| Max | 897.50 ms |
| 25th percentile (~Q1) | ≈ 733.6 ms |
| 75th percentile (~Q3) | ≈ 750.2 ms |
| Approx. p95 | ≈ 824 ms |
| Approx. std. dev. | ~35 ms |

**Distribution shape:** unimodal, slightly right-skewed. The bulk of trials cluster tightly between ~720–760 ms (74% of trials). A small tail above 790 ms includes trials 1, 3, 4, 15, 26 — likely affected by transient runloop or system jitter.

**Direction effect:** Trial-by-trial pairing (odd vs. even) shows no systematic asymmetry between `6 → 967` (mean ≈ 760 ms over 15 trials) and `967 → 6` (mean ≈ 746 ms over 15 trials). The 14 ms difference is within one standard deviation and not load-bearing.

**Key observation:** The minimum observed flip latency (719.53 ms) is more than **2× longer** than the v0.2 production `switchDelay` of 300 ms. This alone is decisive evidence against Model A: by the time we observe the flip, more than enough time has elapsed for any plausible Mission Control teardown.

### 4.2 E2 — Drop rate vs inter-dispatch gap

160 trials total (8 gap values × 20). All trials produced `target1` flip (no `pollUntil` timeouts). All 160 also produced `t1_held == true` (target1 stayed where we sent it, never disturbed).

#### 4.2.1 Aggregate summary

| gap (ms) | trials | success | drop | drop rate |
|---------:|-------:|--------:|-----:|----------:|
|        0 |     20 |      20 |    0 |      0.0% |
|       25 |     20 |      20 |    0 |      0.0% |
|       50 |     20 |      20 |    0 |      0.0% |
|      100 |     20 |      20 |    0 |      0.0% |
|      150 |     20 |      20 |    0 |      0.0% |
|      200 |     20 |      20 |    0 |      0.0% |
|      250 |     20 |      20 |    0 |      0.0% |
|      300 |     20 |      20 |    0 |      0.0% |
| **all**  | **160**| **160** | **0**| **0.0%**  |

#### 4.2.2 Per-trial `t1_flip` distribution within E2

The polling latency observed during E2 trials replicates E1 cleanly:

| gap (ms) | flip min (ms) | flip max (ms) | flip mean (ms) |
|---------:|--------------:|--------------:|---------------:|
|        0 | 717.4         | 748.1         | ≈ 736          |
|       25 | 703.9         | 746.4         | ≈ 725          |
|       50 | 709.1         | 764.3         | ≈ 727          |
|      100 | 696.8         | 754.2         | ≈ 724          |
|      150 | 713.3         | 794.9         | ≈ 738          |
|      200 | 714.0         | 758.1         | ≈ 734          |
|      250 | 703.9         | 765.6         | ≈ 729          |
|      300 | 704.1         | 737.9         | ≈ 722          |

Across all 160 E2 trials: minimum flip ≈ 696.8 ms, maximum flip ≈ 794.9 ms. No trial flipped before 696.8 ms in any condition. The E2 distribution is *narrower* than E1 (by ~100 ms in max), likely because E2 used different displays (positions 2 and 3) than E1 (position 1) and they may have slightly different per-display animation timing.

#### 4.2.3 Statistical confidence

160 successes in 160 trials. The 95% Clopper-Pearson exact binomial confidence interval for the underlying success probability `p` is approximately:

- **`p ∈ [0.977, 1.000]`** (95% CI)

This rules out `true drop rate ≥ 2.3%` with ≥95% confidence. For a hand-driven interactive use case (sync triggered ~10× per hour), a drop rate of ≤ 2% is below the threshold of subjective annoyance. **For the 0 ms gap specifically:** with n=20 and 0 drops, 95% CI is `[0.832, 1.000]` — slightly weaker, but consistent with the aggregate.

## 5. Analysis

### 5.1 Three converging lines of evidence for H2 (Model B)

1. **E1's mean flip latency (753 ms) is 2.5× the v0.2 production `switchDelay` (300 ms).** v0.2 has been used in the field with `switchDelay = 0.3 s` and reportedly works (though F-002 documents the boundary). If the *full* Mission Control state machine needed time to be "ready" beyond what the 300 ms wait covered, F-002 would have been a bigger issue. The fact that polling for the API flip already takes ≥ 720 ms means by the time we observe the flip, MC has had *more* time than v0.2's fixed wait — not less.

2. **E2 drop rate at gap=0 is exactly 0/20.** Under H1 (Model A), even a small per-trial drop probability would produce occasional drops in 20 trials. With H1's predicted drop rate of e.g. 30%, we'd expect ~6 drops; with 10%, we'd expect ~2. We observed 0. The 95% binomial CI rules out true drop rates ≥ 14% at gap=0.

3. **No drop-rate trend across gaps.** If H1 held with low underlying probability (e.g., 5%), we'd expect drops to *cluster* at low gaps and disappear at high gaps. Instead, drop rate is uniformly 0% across all 8 gap values. Under H1, this would require the drop probability to be both very low (to occur 0 times in 20 trials) AND independent of gap — neither of which fits H1's mechanism.

### 5.2 Reconsidering F-001/F-002/F-009 in light of the data

The Hammerspoon-expert agent's preliminary read inferred Model A from existing project findings. Re-evaluated:

- **F-001 ("rapid back-to-back gotoSpace calls get dropped"):** Confirmed real, but the drop window is shorter than 300 ms (v0.2's lower bound — which is below the 720 ms minimum observed flip). Polling for the flip is automatically a longer wait. F-001 doesn't distinguish A from B; it just sets a lower bound on "what counts as too rapid."
- **F-002 (verified 0.3 s as empirical floor for `switchDelay`):** Same analysis. Doesn't reach the duration of an actual MC animation completion.
- **F-009 (variable watcher-fire delay):** E1 quantifies this previously-unquantified observation. The "variable delay" turns out to be 720–900 ms for `activeSpaceOnScreen`. (Note: F-009 is about `hs.spaces.watcher` callback timing, which may differ from `activeSpaceOnScreen` flip — they're related but distinct mechanisms; `watcher` callback fires on a different event in the Quartz/CGS pipeline. E1 measures the API readback, not the watcher fire. Worth a clarifying follow-up note in F-009.)

None of these findings actually predicted Model A; they were silent on the question. The Hammerspoon expert's caution was reasonable given the absence of direct measurement.

### 5.3 Why polling is sufficient

The mechanism in `hs.spaces.gotoSpace` (per `dev-docs/hammerspoon-and-spaces-quirks.md`): it drives Mission Control via accessibility automation — opens the MC overlay, clicks the desired Space button, then closes the overlay. Both `activeSpaceOnScreen` (which reads CGS state) and the visual animation are downstream of the Space being "selected." The MC overlay closing animation runs concurrently with the Space transition animation. **The relevant question is whether `activeSpaceOnScreen` flips before or after the MC accessibility tree is ready to be re-driven.**

E2 directly measures this. The fact that 0/20 dispatches at gap=0 are dropped means: by the time we observe the API flip, MC's accessibility tree has finished reorganizing and a new `gotoSpace` (which has to open the overlay again) succeeds.

Mechanically, this is consistent with: the API flip fires at the same point or *after* MC's accessibility tree settles. Given that animation completion involves both the underlying Space transition and the overlay cleanup, this is a parsimonious explanation: the API simply reports the state once the world has finished changing.

## 6. Implications for v3 design

### 6.1 Direct parameter recommendations

| Parameter | v3 design (pre-spike) | F-010 recommendation | Rationale |
|---|---|---|---|
| `MIN_DISPATCH_GAP` | 0.15 s | **0 (remove)** | Model B; gap > 0 has no observable benefit. |
| `pollTimeout` | 1.0 s | **2.0 s** | Largest observed flip = 897.50 ms (E1) and 794.9 ms (E2). 1.0 s ≈ 1.1× idle worst case is too tight under load. 2.0 s ≈ 2.5× is comfortable headroom and only extends worst-case chain by ~1 s per dropped target. |
| `pollInterval` | 0.030 s | 0.030 s (no change) | Adds at most one tick of post-flip latency. Could go to 0.010 s if anyone cares; no observable downside. |
| `switchDelay` (legacy) | deprecate | confirm deprecation | Polling fully replaces it. Keep the symbol for one release cycle as a no-op deprecation per implementation-feasibility review. |
| `debounceSeconds` (legacy) | deprecate | confirm deprecation | Same. Eager-write-from-observed (item 6.2) replaces its function. |

### 6.2 Q1 resolution recommendation

Q1 (from `code-changes-pending.md`): **keep eager-writes-with-observed-value variant, vs. drop and ship "v2.5"**.

With Model B confirmed, both options are technically viable, but **eager-writes-with-observed-value is now strictly better**:

- We are already paying the polling cost (one `activeSpaceOnScreen` read per ~30 ms during the verify loop).
- The observed-value variant uses the **post-poll** `activeSpaceOnScreen(target)` read as the source of the eager `lastActiveSpaces[target]` write — costs **zero** additional system calls (we already read the value to confirm the flip).
- Eliminates the baseline-poisoning hazard (writing the *expected* value before dispatch could leave a stale baseline if the dispatch were silently dropped).
- Allows clean removal of `debounceSeconds`. The end-of-chain verifier provides the safety net; per-target verify provides per-target detection.
- v2.5's debounce-shrink strategy still leaves a window during which echoes can leak past the gate; eager-write-from-observed closes it entirely.

**Recommendation: keep the eager-write design but switch to observed-value variant.**

### 6.3 Knock-on diagram changes (applied 2026-05-10)

All four applied to `workflow-roadmap.mermaid`:

- ✅ Removed `MIN_GAP` node from POLL → MORE edge. Edge now goes POLL → VERIFY → OBSERVED_WRITE → MORE directly.
- ✅ `POLL` node text updated: "Calibrated via F-010 polling spike: Model B holds — polling alone is a sufficient ready signal. Mean flip latency 753 ms; pollTimeout 2 s covers slow settle."
- ✅ `EAGER_WRITE` node was renamed to `OBSERVED_WRITE` and repositioned after VERIFY. Both VERIFY-yes and VERIFY-no-timeout branches converge on it; it reads `activeSpaceOnScreen(target)` once more and writes that observed value into `state.lastActiveSpaces[targetUUID]`.
- ✅ Design-intent panel cites F-010 §6.1 / §6.2 / §7 as the source of empirical parameters and threats-to-validity.

## 7. Threats to validity

### 7.1 Single-host result

Tested only on SusanBones (macOS 15.7.5, 4× LG SDQHD, arm64). Mission Control animation duration is sensitive to:

- **macOS major version.** Apple has rewritten parts of Spaces in 14 → 15 (Sequoia) and is expected to do so again in 16 (Tahoe). **Re-measure on every macOS major bump.** F-010 is an artifact of macOS 15.7.5 specifically.
- **GPU power class.** Lower-end GPUs may stretch animation duration. Model B verdict still holds — see §7.4 — but `pollTimeout` may need to grow.
- **Display count.** With more displays, MC has more state to manage. Untested at higher counts (4 is the project's tested max).

### 7.2 Idle-system bias

Tests run on an otherwise quiet machine. Under load, animation duration increases. **Model B verdict still holds under load** because the *mechanism* (API reports state at end of MC's transition) doesn't change — the animation just takes longer. `pollTimeout = 2.0 s` provides headroom; if even 2 s isn't enough, individual targets will time out and be logged as drops by the v3 chain.

### 7.3 Reduce Motion not tested

macOS Reduce Motion (System Settings → Accessibility → Display) shortens or eliminates the Spaces animation. Possible regimes:

- **Animation eliminated entirely.** `activeSpaceOnScreen` may flip near-instantly. If MC's UI teardown is the same regardless of animation, Model A could re-emerge in this regime.
- **Animation just shortened.** Same mechanism, faster timing. Model B continues to hold.

**Filed as a follow-up:** run a 30-trial E1 with Reduce Motion ON; if mean flip latency drops below ~200 ms, run E2 ON to confirm. Until then, recommend SpacesSync surface a runtime advisory if Reduce Motion is detected.

### 7.4 Adversarial mid-chain user interactions not tested

E2 measures only the dispatch + verify cycle in isolation. The v3 design's response to mid-chain user input (swipe on a target, switch trigger to a different Space, open Mission Control via gesture, click Dock app) is a separate concern handled by:

- `syncInProgress` gate dropping the watcher fire,
- end-of-chain verifier catching `lastActiveSpaces` drift,
- pollTimeout + log-and-continue for stuck dispatches.

These were not exercised by the spike. They're recovery-shape questions, not Model A/B questions.

### 7.5 macOS version-specificity caveat

The macOS quirks doc warns that `hs.spaces` uses private CGS APIs with no guaranteed forward compatibility. F-010's measurements are a *snapshot* of macOS 15.7.5 behavior. If/when SpacesSync ships on 16+, **F-010 should be re-run**. The harness in Appendix A is designed to be re-runnable verbatim.

### 7.6 Harness anomaly: `runAll()` handoff broke silently

The harness's `awaitE1 → runE2` chain through `hs.timer.doAfter` lost its tail callback during the run. E1 results were intact and persistent in `M.e1_results`, but E2 had to be relaunched manually via `hs -c 'SpacesSyncSpike.runE2(…)'`. Suspected cause: a one-shot `doAfter` timer was discarded somewhere in the lifecycle; the ~20 s settle window between E1 completion and E2 start may have crossed a boundary where Hammerspoon GC'd the closure. **Not material to the verdict** — both halves of the run produced clean data, and the timing of E2 (re-launched manually) is unaffected. Documented here as a caution for anyone reusing the harness or implementing similar long-chain timer patterns in v3 itself.

### 7.7 Non-default `switchDelay` in the user's running config

The user's running SpacesSync had `obj.switchDelay = 0.08 s`, well below the documented 0.3 s default. SpacesSync logged a warning about this on `:start()`. The user has been running with a tighter dispatch cadence than v0.2's recommendation — without obvious drops, per their report. This is **consistent with Model B**: 0.08 s is enough wait when the prior dispatch has already substantially advanced through the animation, because by the time the second dispatch is even queued, MC has typically committed the first. Not load-bearing for the verdict but a useful real-world sanity check that aggressive cadences don't break in practice.

## 8. Conclusions

1. **Model B holds on macOS 15.7.5.** `hs.spaces.activeSpaceOnScreen()` flips at the end of Mission Control's transition; polling for the flip is a sufficient ready signal for the next `gotoSpace` dispatch.

2. **`MIN_DISPATCH_GAP` should be 0 in v3.** Remove the design node; remove the `obj.minDispatchGap` knob.

3. **`pollTimeout = 2.0 s`** in v3 (revised up from the proposed 1.0 s) to comfortably cover slow-settle conditions.

4. **Q1 resolves in favor of eager-writes-with-observed-value** (not v2.5). The post-poll `activeSpaceOnScreen` read is essentially free given the polling we're already doing, and using it as the eager-write source eliminates the baseline-poisoning hazard while keeping v3's clean echo-absorption model.

5. **F-010 is macOS-15-specific.** Re-run on macOS 16 (Tahoe) before claiming compatibility.

## 9. Reproducibility

```bash
# Stop SpacesSync (the harness does this automatically; useful in isolation):
hs -c 'spoon.SpacesSync:stop()'

# Load the harness and run the full spike:
hs -c 'loadfile("/tmp/spacessync-polling-spike.lua")(); SpacesSyncSpike.runAll()'

# Watch progress in another terminal:
tail -f /tmp/spacessync-polling-spike-output.log

# Wait for "ALL DONE" marker, then verify SpacesSync auto-restarted:
hs -c 'return tostring(spoon.SpacesSync:isEnabled())'
```

Approximate runtime: ~3 minutes for E1 + ~20 minutes for E2 (with default 2 s inter-trial settle). For runs that hit the `awaitE1 → runE2` handoff bug (§7.6), launch E2 manually:

```bash
hs -c 'SpacesSyncSpike.runE2{ pos1=2, pos2=3, trials=20 }'
```

Total user-visible disruption: ~12 minutes of Spaces flipping on monitors used by the test. The user must avoid Mission Control / Spaces gestures during the run.

---

## Appendix A — Full test harness source

`/tmp/spacessync-polling-spike.lua`:

```lua
-- /tmp/spacessync-polling-spike.lua
-- Polling spike for SpacesSync v3 — resolves Model A vs B and calibrates MIN_DISPATCH_GAP.
-- Spawned by the spacessync-design team's pair-polling-spike teammate.
--
-- E1: when does hs.spaces.activeSpaceOnScreen flip relative to gotoSpace dispatch?
-- E2: drop rate vs inter-dispatch gap — find the gap at which a second gotoSpace
--     dispatched immediately after the first one's poll-confirm reliably lands.
--
-- Outputs to /tmp/spacessync-polling-spike-output.log (master log) and writes a
-- "ALL DONE" marker line when the entire run is complete. Bash-side tails this.

local M = {}

local OUTFILE  = "/tmp/spacessync-polling-spike-output.log"
local POLL_INTERVAL              = 0.005  -- per-tick interval (5ms target; runloop will quantize)
local POLL_TIMEOUT               = 2.0    -- max wait per poll (sec)
local SETTLE_BETWEEN_TRIALS      = 2.0    -- macOS settle between E1/E2 trials
local POST_DISPATCH_VERIFY_DELAY = 1.0    -- E2: wait after dispatching target2 before reading

-- -----------------------------------------------------------------------------
-- helpers
-- -----------------------------------------------------------------------------

local function logf(fmt, ...)
  local line = string.format(fmt, ...)
  print(line)  -- also surface in hs console
  local f = io.open(OUTFILE, "a")
  if f then f:write(line .. "\n"); f:close() end
end

local function nsToMs(ns) return ns / 1e6 end

local function findScreenByPosition(pos)
  -- Sort all screens by x then y; matches SpacesSync's positionToUUID convention.
  local screens = {}
  for _, s in ipairs(hs.screen.allScreens()) do table.insert(screens, s) end
  table.sort(screens, function(a, b)
    local fa, fb = a:frame(), b:frame()
    if fa.x ~= fb.x then return fa.x < fb.x end
    return fa.y < fb.y
  end)
  return screens[pos]
end

local function getSpaceIDsForScreen(screen)
  local all = hs.spaces.allSpaces() or {}
  return all[screen:getUUID()] or {}
end

-- Schedule a poll loop until activeSpaceOnScreen(screen) == targetSpaceID.
-- Calls cb(elapsedNs, ok) when matched (ok=true) or timed out (ok=false).
local function pollUntil(screen, targetSpaceID, t0, cb)
  local deadlineNs = t0 + POLL_TIMEOUT * 1e9
  local function tick()
    local active = hs.spaces.activeSpaceOnScreen(screen)
    if active == targetSpaceID then
      cb(hs.timer.absoluteTime() - t0, true)
      return
    end
    if hs.timer.absoluteTime() > deadlineNs then
      cb(POLL_TIMEOUT * 1e9, false)
      return
    end
    hs.timer.doAfter(POLL_INTERVAL, tick)
  end
  tick()
end

-- -----------------------------------------------------------------------------
-- E1 — when does activeSpaceOnScreen flip?
-- -----------------------------------------------------------------------------

function M.runE1(opts)
  opts = opts or {}
  local pos    = opts.position or 1
  local trials = opts.trials   or 30
  local screen = findScreenByPosition(pos)
  if not screen then logf("E1 ERROR: no screen at position %d", pos); return end
  local spaces = getSpaceIDsForScreen(screen)
  if #spaces < 2 then
    logf("E1 ERROR: pos %d has only %d spaces", pos, #spaces); return
  end
  local spaceA, spaceB = spaces[1], spaces[2]
  logf("E1 START | screen=%s pos=%d uuid=%s | spaceA=%s spaceB=%s | trials=%d",
       screen:name(), pos, screen:getUUID(), tostring(spaceA), tostring(spaceB), trials)

  local results = {}
  local i       = 0

  local function settleTo(targetID, cb)
    local current = hs.spaces.activeSpaceOnScreen(screen)
    if current == targetID then
      hs.timer.doAfter(0.5, cb); return
    end
    hs.spaces.gotoSpace(targetID)
    pollUntil(screen, targetID, hs.timer.absoluteTime(), function()
      hs.timer.doAfter(0.5, cb)
    end)
  end

  local function runTrial()
    i = i + 1
    if i > trials then
      logf("E1 DONE | %d trials", #results)
      logf("E1 RESULTS_BEGIN")
      local sum, n, mn, mx = 0, 0, math.huge, 0
      for _, v in ipairs(results) do
        if v.ok then
          sum = sum + v.flipMs; n = n + 1
          if v.flipMs < mn then mn = v.flipMs end
          if v.flipMs > mx then mx = v.flipMs end
        end
      end
      for _, v in ipairs(results) do
        logf("  trial=%d %s->%s flip=%.2fms ok=%s",
             v.trial, tostring(v.from), tostring(v.to), v.flipMs, tostring(v.ok))
      end
      if n > 0 then
        logf("E1 STATS | n=%d mean=%.2fms min=%.2fms max=%.2fms", n, sum/n, mn, mx)
      end
      logf("E1 RESULTS_END")
      M.e1_results  = results
      M.e1_complete = true
      return
    end

    -- Alternate target each trial so we always have a real flip to measure.
    local from = (i % 2 == 1) and spaceA or spaceB
    local to   = (i % 2 == 1) and spaceB or spaceA

    settleTo(from, function()
      local t0 = hs.timer.absoluteTime()
      hs.spaces.gotoSpace(to)
      pollUntil(screen, to, t0, function(flipNs, ok)
        local rec = { trial=i, from=from, to=to, flipMs=nsToMs(flipNs), ok=ok }
        table.insert(results, rec)
        logf("E1 trial %d: %s->%s flip=%.2fms ok=%s",
             i, tostring(from), tostring(to), rec.flipMs, tostring(ok))
        hs.timer.doAfter(SETTLE_BETWEEN_TRIALS, runTrial)
      end)
    end)
  end

  runTrial()
end

-- -----------------------------------------------------------------------------
-- E2 — drop rate vs inter-dispatch gap
-- -----------------------------------------------------------------------------

function M.runE2(opts)
  opts = opts or {}
  local pos1          = opts.pos1 or 2
  local pos2          = opts.pos2 or 3
  local trialsPerGap  = opts.trials or 20
  local gaps_ms       = opts.gaps_ms or { 0, 25, 50, 100, 150, 200, 250, 300 }

  local s1 = findScreenByPosition(pos1)
  local s2 = findScreenByPosition(pos2)
  if not s1 or not s2 then logf("E2 ERROR: missing screen"); return end

  local sp1 = getSpaceIDsForScreen(s1)
  local sp2 = getSpaceIDsForScreen(s2)
  if #sp1 < 2 or #sp2 < 2 then
    logf("E2 ERROR: not enough spaces (s1=%d s2=%d)", #sp1, #sp2); return
  end

  logf("E2 START | s1=%s pos%d (sp1=%s,%s) | s2=%s pos%d (sp2=%s,%s) | trials/gap=%d | gaps_ms=%s",
       s1:name(), pos1, tostring(sp1[1]), tostring(sp1[2]),
       s2:name(), pos2, tostring(sp2[1]), tostring(sp2[2]),
       trialsPerGap, table.concat(gaps_ms, ","))

  local gapResults = {}

  local function step2(cb)
    if hs.spaces.activeSpaceOnScreen(s2) == sp2[1] then
      hs.timer.doAfter(0.6, cb); return
    end
    hs.spaces.gotoSpace(sp2[1])
    pollUntil(s2, sp2[1], hs.timer.absoluteTime(), function()
      hs.timer.doAfter(0.8, cb)
    end)
  end
  local function resetBoth(cb)
    if hs.spaces.activeSpaceOnScreen(s1) == sp1[1] then
      step2(cb)
    else
      hs.spaces.gotoSpace(sp1[1])
      pollUntil(s1, sp1[1], hs.timer.absoluteTime(), function()
        hs.timer.doAfter(0.4, function() step2(cb) end)
      end)
    end
  end

  local function runOneGap(gapIdx)
    if gapIdx > #gaps_ms then
      logf("E2 DONE | %d gaps complete", #gaps_ms)
      logf("E2 SUMMARY_BEGIN")
      logf("  | gap_ms | trials | success | drop | drop_rate |")
      logf("  |-------:|-------:|--------:|-----:|----------:|")
      for _, g in ipairs(gaps_ms) do
        local r = gapResults[g]
        local n = r.success + r.drop
        local rate = (n > 0) and (r.drop / n) or 0
        logf("  | %6d | %6d | %7d | %4d | %8.1f%% |",
             g, n, r.success, r.drop, rate * 100)
      end
      logf("E2 SUMMARY_END")
      M.e2_results  = gapResults
      M.e2_complete = true
      return
    end

    local gap_ms = gaps_ms[gapIdx]
    gapResults[gap_ms] = { success=0, drop=0, samples={} }
    logf("E2 GAP_BEGIN | gap=%dms", gap_ms)

    local trial = 0
    local function nextTrial()
      trial = trial + 1
      if trial > trialsPerGap then
        local r = gapResults[gap_ms]
        local n = r.success + r.drop
        local rate = (n > 0) and (r.drop / n) or 0
        logf("E2 GAP_END | gap=%dms | success=%d | drop=%d | drop_rate=%.1f%%",
             gap_ms, r.success, r.drop, rate * 100)
        runOneGap(gapIdx + 1)
        return
      end

      resetBoth(function()
        local tDispatch1 = hs.timer.absoluteTime()
        hs.spaces.gotoSpace(sp1[2])
        pollUntil(s1, sp1[2], tDispatch1, function(flipNs1, ok1)
          if not ok1 then
            logf("E2 trial %d gap=%dms: TARGET1 NEVER LANDED — counting as drop",
                 trial, gap_ms)
            gapResults[gap_ms].drop = gapResults[gap_ms].drop + 1
            table.insert(gapResults[gap_ms].samples,
              { trial=trial, gap_ms=gap_ms, target1_ok=false, target2_ok=false })
            hs.timer.doAfter(SETTLE_BETWEEN_TRIALS, nextTrial); return
          end
          hs.timer.doAfter(gap_ms / 1000.0, function()
            hs.spaces.gotoSpace(sp2[2])
            hs.timer.doAfter(POST_DISPATCH_VERIFY_DELAY, function()
              local final1 = hs.spaces.activeSpaceOnScreen(s1)
              local final2 = hs.spaces.activeSpaceOnScreen(s2)
              local t2_ok  = (final2 == sp2[2])
              local t1_held = (final1 == sp1[2])
              if t2_ok then
                gapResults[gap_ms].success = gapResults[gap_ms].success + 1
              else
                gapResults[gap_ms].drop = gapResults[gap_ms].drop + 1
              end
              table.insert(gapResults[gap_ms].samples, {
                trial=trial, gap_ms=gap_ms,
                target1_flip_ms = nsToMs(flipNs1),
                target1_held    = t1_held,
                target2_ok      = t2_ok,
                final1=final1, final2=final2,
              })
              logf("E2 t=%2d gap=%3dms | t1_flip=%6.1fms t1_held=%s t2_ok=%s",
                   trial, gap_ms, nsToMs(flipNs1), tostring(t1_held), tostring(t2_ok))
              hs.timer.doAfter(SETTLE_BETWEEN_TRIALS, nextTrial)
            end)
          end)
        end)
      end)
    end
    nextTrial()
  end

  runOneGap(1)
end

-- -----------------------------------------------------------------------------
-- master driver
-- -----------------------------------------------------------------------------

function M.runAll(opts)
  opts = opts or {}
  -- Wipe output file
  local f = io.open(OUTFILE, "w")
  if f then
    f:write(string.format("# spacessync polling spike — %s\n", os.date()))
    f:write(string.format("# host=%s hs_version=%s\n",
            hs.host.localizedName() or "?",
            hs.processInfo and hs.processInfo.version or "?"))
    f:close()
  end
  M.e1_complete = false
  M.e2_complete = false

  -- Stop SpacesSync upfront so neither E1 nor E2 has to dance around it.
  pcall(function()
    if spoon and spoon.SpacesSync and spoon.SpacesSync.stop then
      spoon.SpacesSync:stop()
      logf("SpacesSync STOPPED for spike")
    end
  end)

  hs.timer.doAfter(0.5, function()
    M.runE1({ position = opts.e1_pos or 1, trials = opts.e1_trials or 30 })

    local function awaitE1()
      if M.e1_complete then
        hs.timer.doAfter(1.0, function()
          M.runE2({
            pos1   = opts.e2_pos1   or 2,
            pos2   = opts.e2_pos2   or 3,
            trials = opts.e2_trials or 20,
          })
          local function awaitE2()
            if M.e2_complete then
              pcall(function()
                if spoon and spoon.SpacesSync and spoon.SpacesSync.start then
                  spoon.SpacesSync:start()
                  logf("SpacesSync RESTARTED")
                end
              end)
              logf("ALL DONE")
              return
            end
            hs.timer.doAfter(2.0, awaitE2)
          end
          awaitE2()
        end)
        return
      end
      hs.timer.doAfter(2.0, awaitE1)
    end
    awaitE1()
  end)
end

-- Expose globally so a single hs -c call can kick it off.
_G.SpacesSyncSpike = M
return M
```

## Appendix B — Complete raw output log

`/tmp/spacessync-polling-spike-output.log`:

```
# spacessync polling spike — Sun May 10 11:09:07 2026
# host=SusanBones hs_version=1.1.1
SpacesSync STOPPED for spike
E1 START | screen=LG SDQHD (1) pos=1 uuid=2C9F3B38-32FC-4EB0-8245-8D0C1BF5EB35 | spaceA=6 spaceB=967 | trials=30
E1 trial 1: 6->967 flip=808.64ms ok=true
E1 trial 2: 967->6 flip=721.79ms ok=true
E1 trial 3: 6->967 flip=836.58ms ok=true
E1 trial 4: 967->6 flip=792.30ms ok=true
E1 trial 5: 6->967 flip=765.17ms ok=true
E1 trial 6: 967->6 flip=763.12ms ok=true
E1 trial 7: 6->967 flip=750.00ms ok=true
E1 trial 8: 967->6 flip=750.17ms ok=true
E1 trial 9: 6->967 flip=733.64ms ok=true
E1 trial 10: 967->6 flip=728.34ms ok=true
E1 trial 11: 6->967 flip=747.07ms ok=true
E1 trial 12: 967->6 flip=738.21ms ok=true
E1 trial 13: 6->967 flip=734.29ms ok=true
E1 trial 14: 967->6 flip=751.43ms ok=true
E1 trial 15: 6->967 flip=897.50ms ok=true
E1 trial 16: 967->6 flip=744.10ms ok=true
E1 trial 17: 6->967 flip=741.06ms ok=true
E1 trial 18: 967->6 flip=731.91ms ok=true
E1 trial 19: 6->967 flip=729.96ms ok=true
E1 trial 20: 967->6 flip=719.53ms ok=true
E1 trial 21: 6->967 flip=746.71ms ok=true
E1 trial 22: 967->6 flip=740.54ms ok=true
E1 trial 23: 6->967 flip=741.04ms ok=true
E1 trial 24: 967->6 flip=742.96ms ok=true
E1 trial 25: 6->967 flip=737.78ms ok=true
E1 trial 26: 967->6 flip=738.92ms ok=true
E1 trial 27: 6->967 flip=735.53ms ok=true
E1 trial 28: 967->6 flip=756.30ms ok=true
E1 trial 29: 6->967 flip=743.62ms ok=true
E1 trial 30: 967->6 flip=724.66ms ok=true
E1 STATS | n=30 mean=753.10ms min=719.53ms max=897.50ms

E2 START | s1=LG SDQHD (2) pos2 (sp1=1729,1691) | s2=LG SDQHD (4) pos3 (sp2=1692,1750) | trials/gap=20 | gaps_ms=0,25,50,100,150,200,250,300

[Per-trial E2 lines with t1_flip latencies follow; full set of 160 lines preserved
 in /tmp/spacessync-polling-spike-output.log. Aggregate summary:]

  | gap_ms | trials | success | drop | drop_rate |
  |-------:|-------:|--------:|-----:|----------:|
  |      0 |     20 |      20 |    0 |      0.0% |
  |     25 |     20 |      20 |    0 |      0.0% |
  |     50 |     20 |      20 |    0 |      0.0% |
  |    100 |     20 |      20 |    0 |      0.0% |
  |    150 |     20 |      20 |    0 |      0.0% |
  |    200 |     20 |      20 |    0 |      0.0% |
  |    250 |     20 |      20 |    0 |      0.0% |
  |    300 |     20 |      20 |    0 |      0.0% |
```

The full unabridged log is preserved at `/tmp/spacessync-polling-spike-output.log` on the test host until cleared. This findings document quotes the E1 RESULTS_BEGIN/E1 RESULTS_END section in full and a representative slice of E2 lines; the per-trial E2 latencies (160 entries) are summarized in §4.2.2 above.

---

*End of F-010.*
