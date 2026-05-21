# MLX Winograd Tuner — Baked-Default Baseline Anchor — Design

**Date:** 2026-05-21
**Branch:** feature/mlx-backend
**Status:** Spec — pending plan & implementation

## Goal

Make every MLX Winograd tuner sweep print a line containing the SP1 baked
default's measured time, the picked winner's measured time, and the percentage
delta between them. The sweep continues to adopt the winner unconditionally.
The added line is the operator's tripwire for noise-induced regressions in the
cache; the tuner contract is otherwise unchanged.

**Success criterion:**

After every call to `loadOrAutoTune` that actually runs the sweep (not the
load-from-cache path), the logger has received exactly one extended log line
per stage in this format:

```
MLX tuner flatSweepInput: considered=N best=tg0=A tg1=B wpt=C vw=D gridOrder=G time_ms=W.WWW baseline_ms=Z.ZZZ delta_pct=-X.X
MLX tuner flatSweepOutput: considered=N best=tg0=A tg1=B wpt=C time_ms=W.WWW baseline_ms=Z.ZZZ delta_pct=-X.X
```

The winner saved to disk is byte-identical to what the current sweep would
save. No on-disk cache format change.

## Non-goals

This work is the smallest mitigation that gives the operator visibility into
sweep regressions. The following are deliberately **out of scope** and must
not be introduced by this change:

- No estimator change. `scoreInputTransform` / `scoreOutputUntransform` keep
  the weighted-mean computation over 20 reps.
- No batching of `mx::eval` across reps.
- No shape-weight rebalancing (the three shape slots stay weighted 1.0/1.0/1.0).
- No "refuse-to-update" / regression-rejection policy. The winner is always
  adopted, regardless of `delta_pct` sign or magnitude.
- No `baseline_ms` field added to `MLXWinogradTuneParams` or to the on-disk
  cache format (`MLX_WINO_TUNER_VERSION` stays at 3).
- No new public API on `MLXWinogradTuner`.
- No changes to `flatSweepInput`/`flatSweepOutput` candidate generation,
  validity filters, or candidate scoring order.

## Background

`flatSweepInput` (`cpp/neuralnet/mlxwinotuner.cpp:525-563`) and
`flatSweepOutput` (lines 568-597) currently pick the candidate with the lowest
weighted-mean wall-clock time across 20 reps and log a single line summarizing
the winner. They do not measure or report any reference point.

Prior analysis (see `.claude/MLX_Validation.md` and the OpenCL-tuner comparison
work captured in the project's internal review notes) showed that the
per-sample wall-clock noise floor sits at ~10% — confirmed by the gated
convergence test at `cpp/neuralnet/mlxwinotuner.cpp:898`, which uses min-of-5
denoising on both the baked default and the tuned winner and still allows a
10% slack. Without a baseline measurement in every sweep, a sweep that
returns a winner slower than the baked default (possible at the noise floor)
is silently written to the cache and persists until the next re-tune.

The SP1 baked default is already encoded as the struct default-member-init
values in `cpp/neuralnet/mlxwinograd.h:16-27`:

```cpp
struct InputTransform {
  int tg0 = 32;
  int tg1 = 1;
  int wpt = 1;
  int vw  = 1;
  GridOrder gridOrder = GridOrder::Cfast;
};
struct OutputUntransform {
  int tg0 = 32;
  int tg1 = 1;
  int wpt = 1;
};
```

Default-construction (`MLXWinograd::InputTransform{}`,
`MLXWinograd::OutputUntransform{}`) yields the SP1 baseline. No new named
constant is required.

## Architecture

Two surgical edits, both inside the existing `static` functions in
`cpp/neuralnet/mlxwinotuner.cpp`. No header changes, no new TUs, no new
public API. The existing log line in each function is rewritten to include
three additional trailing fields; an additional `score*` call is added
immediately before the candidate loop in each function.

### Change 1 — `flatSweepInput`

Before the `for(GO go : {GO::Cfast, GO::Tfast})` loop at line 543, score the
baseline:

```cpp
const double baselineMs =
    scoreInputTransform(MLXWinograd::InputTransform{}, N, H, W, mi, useFP16);
```

After the loop, when assembling the existing log line (lines 551-561), append
`baseline_ms` and `delta_pct` to the trailing format. Delta is computed as
`(bestTime - baselineMs) / baselineMs * 100.0` and is rendered with one
decimal place, signed (negative = winner faster than baseline). The
`baseline_ms` field is rendered with three decimal places to match the
existing `time_ms` precision.

If `best` is `nullopt` (the existing "no valid candidate" defensive branch),
the baseline fields are still emitted, so the log line remains parseable:

```
MLX tuner flatSweepInput: considered=0 best=none baseline_ms=0.412 delta_pct=nan
```

`delta_pct=nan` is the explicit signal that no winner was selected. The
caller throws on `nullopt` immediately after (line 645-646), so this log
state is observable only via tee'd stderr in the moments before process exit.

### Change 2 — `flatSweepOutput`

Symmetric to Change 1. Before the candidate loop at line 581, score:

```cpp
const double baselineMs =
    scoreOutputUntransform(MLXWinograd::OutputUntransform{}, N, H, W, mi, useFP16);
```

Augment the log line (lines 587-595) with the same `baseline_ms` and
`delta_pct` fields, using the same precision and sign convention.

### Log format — exact specification

Sample lines (filled in for a hypothetical sweep result):

```
MLX tuner flatSweepInput: considered=2160 best=tg0=32 tg1=4 wpt=2 vw=2 gridOrder=0 time_ms=0.298 baseline_ms=0.412 delta_pct=-27.7
MLX tuner flatSweepOutput: considered=480 best=tg0=64 tg1=2 wpt=1 time_ms=0.211 baseline_ms=0.305 delta_pct=-30.8
```

Field order is fixed: `considered=…` first, then the existing `best=…` block,
then `time_ms`, then `baseline_ms`, then `delta_pct`. Order is part of the
contract because the unit test (see Testing) regex-matches positions.

Sign convention is `delta_pct = (winner − baseline) / baseline × 100`. A
negative value means the sweep beat the baseline. The operator looks for
positive values as regressions.

## Cost

One additional 20-rep score per stage per re-tuning sweep. With the existing
per-rep cost of roughly 0.3-0.6 ms and 19 weighted reps, each added score is
~10-15 ms of GPU+CPU work. Across both stages, the sweep gains <30 ms of
wall-clock — three orders of magnitude smaller than the existing multi-second
sweep. The added cost is not gated by `full` mode.

## Data flow

```
loadOrAutoTune (mlxwinotuner.cpp:601-660)
  └─ cache miss / reTune=true
      ├─ flatSweepInput (mlxwinotuner.cpp:525-563)
      │   ├─ scoreInputTransform(InputTransform{}, ...)      ← NEW: baseline measurement
      │   ├─ candidate sweep loop (unchanged)
      │   ├─ pick best (unchanged)
      │   └─ log line with baseline_ms + delta_pct           ← AUGMENTED
      ├─ flatSweepOutput (mlxwinotuner.cpp:568-597)
      │   ├─ scoreOutputUntransform(OutputUntransform{}, …)  ← NEW
      │   ├─ candidate sweep loop (unchanged)
      │   ├─ pick best (unchanged)
      │   └─ log line with baseline_ms + delta_pct           ← AUGMENTED
      └─ save to cache (unchanged)
```

## Error handling

- Baseline scoring uses the same kernel-dispatch machinery as candidate
  scoring. If it throws, the exception propagates out of `flatSweepInput` /
  `flatSweepOutput` and out of `loadOrAutoTune` — same behavior as if a
  candidate scoring throws today.
- If `best` is `nullopt` (no valid candidate), `delta_pct` is rendered as
  `nan` and the function still returns `nullopt`. The caller's existing
  `throw StringError("flat sweep returned no valid candidate")` (line 645-646)
  fires unchanged.
- `baselineMs == 0.0` is impossible in practice (kernel dispatch + eval always
  takes nonzero time), but is guarded against: if `baselineMs < 1e-9`,
  `delta_pct` is rendered as `nan` to avoid division by zero.

## Testing

Two additions to `runMLXWinotunerTests` in `cpp/neuralnet/mlxwinotuner.cpp`,
appended after the existing gated convergence test (current end of the
function, ~line 906). Existing tests are not modified.

### Test 1 — Log-format unit check (always-on)

Wires a logging-capture `Logger` (KataGo's `Logger` class supports
`setLogToStdout(false)` + a custom output sink), runs a minimal sweep on the
SP5 Task 10 synthetic model (`mi.trunkNumChannels = mi.midNumChannels =
mi.maxConvChannels3x3 = 64`, `nnXLen = nnYLen = 19`, `batchSize = 1`,
`useFP16 = true`, `full = false`, `reTune = true`), then regex-matches the
captured log against:

```regex
MLX tuner flatSweepInput: considered=[0-9]+ best=tg0=[0-9]+ tg1=[0-9]+ wpt=[0-9]+ vw=[0-9]+ gridOrder=[01] time_ms=[0-9]+\.[0-9]+ baseline_ms=[0-9]+\.[0-9]+ delta_pct=-?[0-9]+\.[0-9]+
```

and the symmetric pattern for `flatSweepOutput`. Asserts both matches
succeed. Runtime: bounded by the same sweep cost the existing gated
convergence test pays (~1-2 s), so this test is **always on** only if the
synthetic-sweep cost is acceptable for unconditional `runnnlayertests`. If
it's not (decision deferred to plan-writing), this test is gated behind
`KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST`.

The plan task that adds the test will measure the synthetic-sweep cost and
decide gated vs always-on based on it. The criterion for "acceptable
always-on" is: synthetic sweep completes in under 3 seconds on the project's
reference machine (Apple Silicon M-series, exact SKU recorded in
`.claude/MLX_Validation.md`). If it exceeds 3 seconds, the test is gated.

### Test 2 — Baseline-consistency check (gated)

Gated behind the existing `KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST` env var so it
shares the gated convergence test's opt-in cost. After the existing gated
test finishes, run `scoreInputTransform(MLXWinograd::InputTransform{}, ...)`
three times, take the min, and assert that the value parsed from the most
recent `baseline_ms` log field is within 25% of the min-of-3 reference. The
25% slack accommodates the ~10% noise floor and one or two outlier samples.

The assertion confirms that the baseline log field reflects an actual
`scoreInputTransform` of the default-constructed `InputTransform{}` — not,
e.g., a stale cached value, an off-by-one in the format string, or a
double-decimal-point parse error.

### What stays green

- `runtests` — all unit tests pass unchanged.
- `runnnlayertests` — all existing MLX Winograd and tuner subtests pass
  unchanged. The gated convergence test (lines 852-906) is untouched.
- `testgpuerror` cross-backend validation — unaffected (the tuner runs before
  any inference, and its log lines have no effect on inference correctness).

## Risks and mitigations

| Risk | Mitigation |
|------|-----------|
| Baseline scoring is noisy (same ~10% per-sweep variance as candidate scoring), so `delta_pct` itself is noisy at the ±10% level. | Documented in the log line: a single sweep's `delta_pct` carries the same noise floor as the winner pick. Operator interpretation: only sustained positive deltas across runs are signal. Future work (mitigations 1-3 from the brainstorming discussion) would tighten this. |
| The log line gets longer and may exceed terminal width on narrow consoles. | The format mirrors existing key=value style and stays under 160 chars in the typical case. KataGo logs already exceed this in several places. No mitigation needed. |
| `delta_pct` rendering ambiguity (locale-dependent decimal separator). | Use `Global::strprintf("%+.1f", delta)` — C locale by default in KataGo. The `+` flag ensures the sign is always shown. |
| Future estimator change could cause baseline and winner to use different estimators (apples-to-oranges). | Both go through `scoreInputTransform`/`scoreOutputUntransform`. Any future estimator change applies to both calls automatically because they share the function body. |
| Test 1 noise: if the synthetic sweep's `delta_pct` rendering ever happens to be exactly `0.0`, regex `-?[0-9]+\.[0-9]+` still matches (the `-?` is optional). | The regex is correct as written. |
| `baseline_ms == 0.0` divide-by-zero. | Explicit guard: if `baselineMs < 1e-9`, render `delta_pct=nan`. |

## Out of scope / future work

The four mitigations from the brainstorming discussion that were *not* picked
remain candidates for future specs:

- **Estimator change: mean → min-of-K** in `scoreInputTransform` /
  `scoreOutputUntransform`. Largest single-component impact on per-sweep
  winner-pick stability.
- **Batch N back-to-back dispatches per timed region** in `timeOneInputTransform`
  / `timeOneOutputUntransform`. Directly amortizes CPU-side `mx::eval`
  overhead.
- **Asymmetric shape weights** (trunk=mid=1.0, max=0.2) matching OpenCL's
  minor-shape weighting in `scoreInputTransform` / `scoreOutputUntransform`.
- **Refuse-and-fall-back policy** layered on top of the baseline anchor this
  spec adds. Would change the tuner contract.

Each of these is independently designable. None depend on this spec's
completion, but they all benefit from the visibility this spec adds — once
the log line ships, operators can characterize the noise floor empirically
before deciding which mitigation gives the most leverage on their workload.
