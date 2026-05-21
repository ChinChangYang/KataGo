# MLX Tuner Shape Diagnostic — Design

**Date:** 2026-05-21
**Branch:** feature/mlx-backend
**Status:** Spec — pending plan & implementation

## Goal

Add two observability log lines to the MLX winograd tuner so we can characterize, on every tuner run, what shape distribution the model actually exercises and how the chosen winner's measured time decomposes across the three tuned slots. The data these lines expose is what we need to make a defensible call between weighting-axis and estimator-axis changes in a subsequent iteration.

**Success criterion:** After one tuner run on `b18c384nbt-uec-20221121b.bin.gz`, the log contains both new lines, and a human reading them can answer:

1. What is the per-pass 3x3 conv shape distribution for this model?
2. Are the three current slots (`trunk`, `mid`, `max`) actually distinct shapes for this model, or do they collapse?
3. For the chosen winner, does each slot measure ~the same time, or are some slots much slower than others?
4. Does the sweep's `time_ms` (weighted mean) line up with per-slot medians, or is one being pulled by outliers?

## Non-goals

- No scoring-function logic change. The 20-rep `slot % 10` rotation, symmetric weights, and weighted-mean estimator all stay identical.
- No asymmetric weighting, no `min-of-K`, no `trimmed-mean`, no new shape-rotation. Those are explicit future options the diagnostic data will inform.
- No tuner cache schema change. Existing `~/.katago/mlxwinotuning/*.txt` files continue to load and short-circuit the sweep.
- No CMake change. No new translation unit, no new header.
- No `ModelInfoForTuning` API change. The static distribution log lives outside the tuner and does not flow through that struct.
- No CLI/flag additions.

## Background

The MLX winograd tuner currently runs a `slot % 10` rotation over three channel-count slots: `trunk` (= `trunkNumChannels`), `mid` (= `midNumChannels`), and `max` (= `maxConvChannels3x3 = max(trunk, mid, regular, gpool)`). After a single-rep warmup, it weights all three slots equally (6 reps each, weight 1.0) and returns the arithmetic mean as the candidate score.

In practice, for almost all KataGo models — including the b18c384nbt validation target — `maxConvChannels3x3 == trunkNumChannels`, so the `max` slot duplicates the `trunk` slot in channel count. Today's symmetric weighting then effectively gives 12 reps to the trunk shape and 6 to the mid shape, which is neither principled (no bias justification) nor stated as intent in the code.

OpenCL's tuner uses asymmetric weights `1.0 / 1.0 / 0.2 / 0.2 / 1.0` across five structurally-distinct shapes, but the MLX three-slot scheme doesn't have a clean structural analogue — the OpenCL "max" is a different shape (`max→max`), while MLX's "max" reuses input dims and only varies channel count.

We don't yet know whether the right next step is reweighting, deduplicating shapes, switching estimators, or adding shapes. This diagnostic gives us the data to decide.

## Architecture

Two log additions, in two files, behind no flags. Both always print on every model load.

### Component 1 — Conv-3x3 shape distribution log

**Location:** `cpp/neuralnet/mlxbackend.cpp`, immediately before the existing `MLXWinogradTuner::loadOrAutoTune` call.

**Function:** Walk `loadedModel.modelDesc.iterConvLayers(...)`, accumulate two `std::map<int,int>` histograms — one keyed by `inChannels` for 3x3 convs, one keyed by `outChannels` for 3x3 convs — and emit one log line via the existing logger:

```
MLX tuner conv3x3 distribution: total=<N> input_c=<c1:n1,c2:n2,...> output_c=<c1:n1,c2:n2,...>
```

- `total` = number of 3x3 `ConvLayerDesc` instances visited.
- Pairs sorted **descending by invocation count, ties broken by channel count descending**. Deterministic order makes log diffs and test regexes simple.
- Each conv counted exactly once (one per-pass invocation).
- 1x1 (and any other non-3x3) convs are excluded — Winograd only applies to 3x3 in this codebase.

**Why before `loadOrAutoTune`:** This line should print on every model load, including cache-hit runs where the tuner short-circuits without sweeping. Putting it inside the tuner would suppress it on cache hit, defeating the goal of correlating cached winners with their shape distribution.

**Why `mlxbackend.cpp` and not the tuner:** The full `ModelDesc` is locally available at the call site. Passing it through `ModelInfoForTuning` for a single log line would be unnecessary coupling. The tuner stays unaware of descriptor topology.

**Cost:** Single descriptor walk at load time, ~40 convs for b18c384nbt — microseconds. Negligible.

### Component 2 — Per-slot timing breakdown in flat-sweep log

**Location:** `cpp/neuralnet/mlxwinotuner.cpp`, inside the existing `flatSweepInput` and `flatSweepOutput` free functions, after the winner has been selected and before the existing log line is emitted.

**Function:** Add two new anonymous-namespace free functions:

```cpp
struct PerSlotTimes { double trunkMs; double midMs; double maxMs; };

static PerSlotTimes scoreInputTransformPerSlot(
    const MLXWinograd::InputTransform& cfg,
    int N, int H, int W,
    const MLXWinogradTuner::ModelInfoForTuning& mi,
    bool useFP16);

static PerSlotTimes scoreOutputUntransformPerSlot(
    const MLXWinograd::OutputUntransform& cfg,
    int N, int H, int W,
    const MLXWinogradTuner::ModelInfoForTuning& mi,
    bool useFP16);
```

Each variant runs the **same 20-rep `slot % 10` rotation with warmup at rep 0** as the existing `scoreInputTransform`/`scoreOutputUntransform`, but instead of accumulating a single weighted mean it stores the 6 non-warmup reps per slot in a fixed-size `std::array<double, 6>` and returns the **median of each slot's 6 reps as `trunkMs / midMs / maxMs`**.

The 6-element median is the **upper of the two middle values after partial sort** (i.e. element at index 3 of a sorted 6-element array, 0-indexed). This is deterministic, avoids float averaging, and matches the standard "median of an even-length sample" convention used in robust-statistic libraries.

**Estimator choice (median, not mean):** The diagnostic purpose is to characterize the underlying truth per slot, robust to per-call jitter. The sweep's `time_ms` already shows the (noise-sensitive) weighted mean; the per-slot fields should add a complementary, jitter-robust signal — not duplicate the sweep's estimator. If `time_ms` and the per-slot medians disagree by more than typical jitter (~5–10%), that disagreement is direct evidence the sweep's estimator is being pulled by upward outliers, which immediately motivates an estimator-axis change in a future iteration.

**Why re-measure after sweep, not instrument the sweep:** The sweep evaluates ~1600 candidates for `flatSweepInput` and ~400 for `flatSweepOutput`. Adding per-slot bookkeeping to every candidate complicates the hot path and is wasted work — we only need the per-slot breakdown for the *winner*. One extra ~30 ms call per stage is negligible against the ~38 s total sweep wall-time observed empirically on b18c384nbt.

### Log format — full

**Input stage line (extended):**
```
MLX tuner flatSweepInput: considered=<N> best=<tg0=… tg1=… wpt=… vw=… gridOrder=…> time_ms=<X> baseline_ms=<Y> delta_pct=<Z> trunk_ms=<A> mid_ms=<B> max_ms=<C>
```

**Output stage line (extended):**
```
MLX tuner flatSweepOutput: considered=<N> best=<tg0=… tg1=… wpt=…> time_ms=<X> baseline_ms=<Y> delta_pct=<Z> trunk_ms=<A> mid_ms=<B> max_ms=<C>
```

- `trunk_ms / mid_ms / max_ms` formatted with `%.3f`, matching existing `time_ms` / `baseline_ms` precision.
- All three slot fields always emitted on the success path.
- If the sweep finds no candidate (existing `best=none` branch): per-slot fields are **omitted entirely**, log line stays in today's `best=none` shape. No NaN strings.

**Defensive handling — NaN/inf in a slot median:** Treat as `0.000` in the log so `%.3f` doesn't emit `"nan"` and break the format regex. Not expected to occur in practice; this is purely a guard.

## Data flow

```
./katago <subcommand using MLX>
  └─ NeuralNet::loadModel / similar
      └─ load ModelDesc from .bin.gz
          ├─ NEW: walk modelDesc.iterConvLayers, build input_c / output_c histograms
          ├─ NEW: log "MLX tuner conv3x3 distribution: ..."  [mlxbackend.cpp]
          └─ MLXWinogradTuner::loadOrAutoTune
              ├─ cache hit?
              │   └─ return cached params (no sweep; no per-slot log)
              └─ cache miss → sweep:
                  ├─ flatSweepInput
                  │   ├─ measure baseline (existing)
                  │   ├─ iterate candidates, scoreInputTransform (existing)
                  │   ├─ NEW: scoreInputTransformPerSlot(winnerCfg, ...) → PerSlotTimes
                  │   └─ log "MLX tuner flatSweepInput: … time_ms=… baseline_ms=… delta_pct=… trunk_ms=… mid_ms=… max_ms=…"
                  └─ flatSweepOutput (symmetric)
              └─ persist cache (existing)
```

On cache hit, only the conv3x3 distribution line prints. This is intentional and useful: it lets operators correlate a cached winner with the shape distribution of the model that produced the cache, without paying for a re-sweep.

## Log ordering on a fresh sweep

```
... loading model ...
MLX tuner conv3x3 distribution: total=37 input_c=384:36,22:1 output_c=384:37
... entering tuner ...
MLX tuner flatSweepInput: considered=1600 best=tg0=64 tg1=16 wpt=1 vw=2 gridOrder=0 time_ms=0.155 baseline_ms=0.281 delta_pct=-45.0 trunk_ms=0.150 mid_ms=0.160 max_ms=0.155
MLX tuner flatSweepOutput: considered=400 best=tg0=192 tg1=2 wpt=2 time_ms=0.170 baseline_ms=0.195 delta_pct=-12.8 trunk_ms=0.165 mid_ms=0.175 max_ms=0.170
MLX tuner flat sweep complete in 38683 ms
```

Numbers are illustrative — actual values depend on the model and host.

## Error handling

| Scenario | Behavior |
|---|---|
| Model has no 3x3 convs | Distribution line prints `total=0 input_c={} output_c={}`. Tuner runs normally. No abort. |
| Pathological model with >10 distinct channel counts | Distribution truncates each histogram to top-10 with trailing `,...` indicator. Realistic models have ≤5 distinct shapes; this is a guard. |
| Per-slot re-measurement throws | Exception propagates as today's sweep-internal exceptions do. No new catch block. |
| Per-slot returns NaN or inf | Treated as `0.000` in the log to keep `%.3f` output well-formed. Defensive; not expected. |
| `best=none` (sweep finds no candidate) | Per-slot fields omitted entirely. Existing `best=none` log shape preserved. |

## Testing

Three tests in `runMLXWinotunerTests` (and one supporting test for the static log helper). Pattern matches the existing baseline-anchor test gating.

### Test 1 — Log format regex (extends existing gate `KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST`)

Extend the existing input/output log regexes to require the new `trunk_ms / mid_ms / max_ms` suffix:

```cpp
std::regex inputRe(
    R"(MLX tuner flatSweepInput: considered=[0-9]+ best=tg0=[0-9]+ tg1=[0-9]+ wpt=[0-9]+ vw=[0-9]+ gridOrder=[01] time_ms=[0-9]+\.[0-9]+ baseline_ms=[0-9]+\.[0-9]+ delta_pct=[-+][0-9]+\.[0-9]+ trunk_ms=[0-9]+\.[0-9]+ mid_ms=[0-9]+\.[0-9]+ max_ms=[0-9]+\.[0-9]+)");
testAssert(std::regex_search(log, inputRe));

std::regex outputRe(
    R"(MLX tuner flatSweepOutput: considered=[0-9]+ best=tg0=[0-9]+ tg1=[0-9]+ wpt=[0-9]+ time_ms=[0-9]+\.[0-9]+ baseline_ms=[0-9]+\.[0-9]+ delta_pct=[-+][0-9]+\.[0-9]+ trunk_ms=[0-9]+\.[0-9]+ mid_ms=[0-9]+\.[0-9]+ max_ms=[0-9]+\.[0-9]+)");
testAssert(std::regex_search(log, outputRe));
```

### Test 2 — Per-slot numeric consistency (new gate `KATAGO_MLX_WINOTUNER_RUN_PER_SLOT_TEST`)

After running a flat sweep on a tiny synthetic shape (same shape as the existing flat-sweep test), parse `trunk_ms` from the captured log via regex. Then independently compute a denoised reference: invoke `scoreInputTransformPerSlotForTesting(MLXWinograd::InputTransform{}, ...)` three times, take the **minimum of the three returned `trunkMs` values**. Assert:

```cpp
const double relErr = std::abs(parsedTrunkMs - referenceTrunkMs) / referenceTrunkMs;
testAssert(relErr < 0.25);
```

This mirrors the existing baseline-anchor numeric test pattern (commit `72364c4e`): each call internally produces a median-of-6 measurement per slot; min-of-three medians is a robust lower-bound reference that strips upward jitter outliers. The loose 0.25 bound tolerates the residual mean-vs-min asymmetry plus small-shape noise, and the comparison is structurally min-of-3-medians vs single-median — not apples-to-apples on point estimators, but a sanity check that the in-sweep per-slot value lives in the same neighborhood as the denoised reference.

Gated because it requires GPU work; ungated CI shouldn't pay this cost.

### Test 3 — Static distribution log format (no gate, fast, no GPU)

Construct a synthetic `ModelDesc` with two 3x3 convs (one `inChannels=32, outChannels=32`; one `inChannels=64, outChannels=64`) and one 1x1 conv (which must be excluded). Call a refactored helper that emits the distribution log string (rather than the logger directly — for testability). Assert via regex:

- `total=2` matches.
- Both `input_c=…` and `output_c=…` fields are present.
- For this synthetic model, `input_c=32:1,64:1` or `input_c=64:1,32:1` (depending on which sort tie-break activates — both are valid since counts are tied).
- The 1x1 conv's channel counts do not appear.

Pattern: refactor the format step into a pure function `formatConv3x3Distribution(const ModelDesc&)` returning a `std::string`. Logger code calls the formatter and then `logger->write(...)`. Tests call the formatter directly.

### Test 4 — Empty model edge case (no gate)

Construct a `ModelDesc` with no 3x3 convs (only 1x1). Call the formatter. Assert the output is exactly:

```
MLX tuner conv3x3 distribution: total=0 input_c={} output_c={}
```

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Per-slot 6-rep median is noisier than the sweep's 18-rep weighted mean → operators may misinterpret per-slot fields as "ground truth" when they're noisier than `time_ms`. | Document in `MLX_Validation.md`'s "When to re-run" snapshot, and in the spec, that per-slot fields are a *diagnostic* signal, not a winner-selection signal. Spec is explicit: `time_ms` drove the pick. |
| Per-slot re-measurement adds ~60 ms to sweep wall-time (~40 s total → 40.06 s). | Negligible; documented but not mitigated. |
| `iterConvLayers` over `ModelDesc` is a virtual-call traversal — minor overhead at load time. | Load-time cost is in tens of microseconds for typical models; same order as a single file `read`. No mitigation needed. |
| Pathological models with hundreds of distinct channel counts could blow up the log line length. | Hard truncate each histogram to top-10 entries with `,...` trailing indicator. |
| Cache-hit runs print only the distribution line (no per-slot fields) → operators may expect them. | Document log ordering explicitly in this spec and in the implementation plan. |
| `%.3f` on a NaN slot median would print `"nan"` and break the format regex. | Defensive guard: clamp NaN/inf to `0.000` before formatting. |

## Out of scope / future work

After this diagnostic ships and we have one full tuner run with the new logs on b18c384nbt (and ideally one other model), the data informs the next iteration. Candidate follow-ups, all explicitly out of scope here:

- **Asymmetric weights** (the original ask): trunk=1.0, mid=1.0, max=0.2 — defensible only if data shows `max` slot is structurally distinct from trunk for the model being tuned.
- **Deduplicate slots:** at score time, detect `maxConvChannels3x3 == trunkNumChannels` and drop slot 2, reallocating reps. Defensible if data shows slots 0 and 2 collapse for typical models.
- **Single-shape rotation:** test only the dominant shape (typically C=trunk). Defensible if shape distribution is >90% one shape.
- **Estimator change:** replace weighted-mean with median-of-K or trimmed-mean across reps. Defensible if data shows `time_ms` and per-slot medians disagree by >10% for stable shapes.
- **Frequency-derived weights:** weight slots proportional to per-pass invocation count from the model descriptor. Most principled, largest scope.

Each of these is a separate spec.
