# MLX Tuner Adaptive Scoring — Design

**Date:** 2026-05-21
**Branch:** `feature/mlx-backend`
**Predecessor:** `docs/superpowers/specs/2026-05-21-mlx-tuner-shape-diagnostic-design.md`
**Status:** Approved, ready for implementation plan

## Goal

Replace the MLX winograd tuner's hardcoded `{trunk, mid, max}` three-slot
scoring rotation with a model-adaptive rotation derived from the actual
3×3 convolution shape distribution of the loaded model, weighted by total
work (count × channels).

## Motivation

The diagnostic feature shipped in commits `49e6dccb..67fe303a` revealed
that the existing scoring is miscalibrated for nested-bottleneck models.

For `b18c384nbt` (the recommended model):

| Slot | C | Forward-pass calls | Weight in current score |
|---|---|---|---|
| trunk | 384 | 1 / 78 (1.3%) | ~33% |
| mid | 192 | 72 / 78 (92%) | ~33% |
| max | 384 (= trunk) | duplicate | ~33% |

The dominant 3×3 conv runs at C=192 (mid channels, due to nested
bottleneck) but only receives ~33% of the score weight, while the C=384
shape that runs once per forward pass receives ~67%. The "max" slot
duplicates trunk for any model where `max(trunk, mid, regular, gpool) ==
trunk`, which is the common case.

The goal is to score candidates by how well they fit the model's actual
workload, not by a fixed three-slot abstraction.

## Non-Goals

- **No cache schema change.** Existing cache files remain valid for their
  recorded `(gpuName, nnXLen, nnYLen, trunkNumChannels, modelVersion,
  useFP16)` keys. Adaptive scoring changes which config wins per key, not
  how keys are looked up.
- **No new precision modes or kernel changes.** Pure scoring policy
  update. The Winograd kernels themselves are unchanged.
- **No tuner-budget increase.** Total rep budget stays at 20 (same as
  today and same as OpenCL).
- **No removal of the shape-distribution log line.** The diagnostic log
  added in `ad7eddec` continues to emit unchanged.

## Architecture

```
ModelDesc (at model load)
   │
   ▼
[A] buildConv3x3Histograms(modelDesc)
       → (inputHist, outputHist)
       Walks ModelDesc::iterConvLayers, filters to 3×3, builds
       std::map<channel,count>-equivalent vectors. Replaces
       the per-call walk inside formatConv3x3Distribution
       (which now calls this helper).
   │
   ▼
[B] ModelInfoForTuning carries both histograms to loadOrAutoTune
   │
   ▼
[C] planShapeRotation(histogram) → vector<ShapePlan>
       Pure function. Applies top-3 cap, 3%-work threshold,
       3-rep floor, proportional remainder. Returns a list of
       (channel, measureReps, weight) entries with sum(reps)==19
       and sum(weight)==1.0.
   │
   ▼
[D] scoreInputTransform / scoreOutputUntransform
       Loop over the ShapePlan list, time each shape `reps`
       times (median), contribute `weight × median` to score.
   │
   ▼
weighted score (ms) → tuner picks min
```

**Unit responsibilities:**
- `buildConv3x3Histograms` — descriptor walk + histogram build. Owns the
  "what shapes does this model use" question. Reused by the existing
  distribution-log formatter to avoid parallel walks.
- `planShapeRotation` — pure policy function. Selection threshold, floor,
  rounding all live here in one place. Trivially unit-testable with no
  MLX dependencies.
- `scoreInputTransform` / `scoreOutputUntransform` — thin loops over the
  plan. No policy, no magic numbers, just timing.

## Data Flow

`cpp/neuralnet/mlxbackend.cpp` (production call site):
```cpp
MLXWinogradTuner::ModelInfoForTuning mi;
mi.trunkNumChannels = loadedModel.modelDesc.trunk.trunkNumChannels;
mi.modelVersion     = loadedModel.modelDesc.modelVersion;
auto [inHist, outHist] =
    MLXWinogradTuner::buildConv3x3Histograms(loadedModel.modelDesc);
mi.conv3x3InputHistogram  = std::move(inHist);
mi.conv3x3OutputHistogram = std::move(outHist);
// (Existing distribution log call continues to work — it now reads
// the same histogram via the shared helper.)
```

## ModelInfoForTuning — Final Form

```cpp
struct ModelInfoForTuning {
  int trunkNumChannels;   // unchanged — cache file key
  int modelVersion;       // unchanged — cache file key
  // Replaces: midNumChannels, maxConvChannels3x3.
  // (C_channels, occurrence_count). Unsorted; planShapeRotation owns
  // selection and ordering.
  std::vector<std::pair<int,int>> conv3x3InputHistogram;
  std::vector<std::pair<int,int>> conv3x3OutputHistogram;
};
```

## Selection Rule and Rep Allocation

**Constants:**
| Symbol | Value | Meaning |
|---|---|---|
| `kTotalReps` | 20 | Total per-candidate timing budget (same as today) |
| `kWarmupReps` | 1 | Discarded warmup on dominant shape |
| `kMaxShapes` | 3 | Top-K cap |
| `kWorkFractionFloor` | 0.03 | Drop shapes with < 3% of total work |
| `kRepFloor` | 3 | Minimum reps per included shape |
| `kMeasureReps` | 19 | `kTotalReps − kWarmupReps` |

**Algorithm (`planShapeRotation`):**

1. For each `(C_i, count_i)` in the input histogram, compute
   `work_i = count_i × C_i`. Both kernels are linear in C, so work is the
   natural proxy for time contribution per shape.
2. Sort descending by `work_i`. Take top `kMaxShapes`.
3. Compute `total_work = Σ work_i` over the taken slice. Drop any shape
   with `work_i / total_work < kWorkFractionFloor`. Recompute `total_work`
   over what remains.
4. Normalize: `weight_i = work_i / total_work`. These are the
   score-averaging weights — `score = Σ weight_i × median_time_i`.
5. Allocate `kMeasureReps` reps:
   - If only one shape remains: assign all 19 measure reps to it.
   - Otherwise: tentatively `reps_i = round(weight_i × kMeasureReps)`.
     Bump any shape with `reps_i < kRepFloor` up to `kRepFloor`, taking
     the deficit out of the dominant shape's count. If the dominant ends
     up below `kRepFloor`, assert (this happens only for > 6 shapes,
     which is capped out by `kMaxShapes`).
   - Repair rounding: adjust dominant by `±1` so `Σ reps_i ==
     kMeasureReps` exactly.
6. Warmup: 1 extra rep on the dominant shape (highest weight). Not
   counted in any sum.

**Worked examples:**

| Histogram | After top-3 + threshold | Weights | Reps |
|---|---|---|---|
| `192:72, 128:5, 22:1` (b18c384nbt input) | drops `22:1` (0.15% work) | `192: 0.956, 128: 0.044` | `192: 16, 128: 3` |
| `192:72` (uniform / non-bottleneck) | same | `192: 1.0` | `192: 19` |
| `384:60, 192:8, 128:5, 64:5` | top-3 cuts 64, threshold drops 128 (2.5%) | `384: 0.938, 192: 0.062` | `384: 16, 192: 3` |

**Score formula:**

```
score = Σ_i weight_i × median(time_i_1, ..., time_i_{reps_i})
```

Per-shape median (not mean) — consistent with the median-of-6 choice in
the diagnostic feature. Robust to per-call jitter without needing more
reps.

## Degenerate Cases

- **Empty histogram** — `assert(false)` at the mlxbackend.cpp call site
  (every KataGo model has at least one 3×3 conv; an empty histogram
  indicates model-load corruption, which we surface rather than mask).
- **Single shape, count=1** — valid plan: 1 shape, 19 reps, weight=1.0.
  Covers the gated-test toy-model case (C=64 throughout).
- **All shapes below threshold individually but > threshold after top-3
  cut** — by construction this can't happen: the threshold is applied to
  the top-3 slice's total work, and at least the dominant shape is always
  ≥ 1/3 of that slice.

## Log Format Changes

Two log lines emitted by `mlxwinotuner.cpp`:

1. **Distribution at model load** (added in `ad7eddec`). Unchanged format:
   `MLX tuner conv3x3 distribution: total=N input_c=... output_c=...`

2. **`flatSweepInput:` / `flatSweepOutput:`** — currently emits per-slot
   medians as `... trunk_ms=X mid_ms=Y max_ms=Z`. New format:
   `... shape_ms=c192:X,c128:Y` (one entry per planned shape, dominant
   first, comma-separated, channel prefix `c` to disambiguate from other
   numeric fields). Preserves the same diagnostic value in a
   shape-correct form.

## API Surface (mlxwinotuner.h)

**Public for testing:**
```cpp
struct ShapePlan { int channels; int measureReps; double weight; };

// Pure, deterministic. Core selection/allocation policy.
std::vector<ShapePlan> planShapeRotationForTesting(
    const std::vector<std::pair<int,int>>& histogram);

// Histogram builder; replaces the walk inside the existing
// formatConv3x3Distribution which now calls this.
std::pair<std::vector<std::pair<int,int>>,
          std::vector<std::pair<int,int>>>
buildConv3x3HistogramsForTesting(const ModelDesc& modelDesc);

// Per-shape median timing (replaces per-slot version).
// Returns one entry per shape in the plan.
std::vector<std::pair<int,double>>
scorePerShapeForTesting(const MLXWinograd::InputTransform& cfg,
                        int N, int H, int W,
                        const ModelInfoForTuning& mi,
                        bool useFP16);
```

**Removed:**
- `scoreInputTransformPerSlotForTesting` (returned `std::array<double,3>`)
- `scoreOutputUntransformPerSlotForTesting`
- `ModelInfoForTuning::midNumChannels`
- `ModelInfoForTuning::maxConvChannels3x3`

**Kept (unchanged signatures):**
- `scoreInputTransformForTesting`
- `scoreOutputUntransformForTesting`
- `formatConv3x3Distribution` / `formatConv3x3DistributionLine`
- `loadOrAutoTune`

## Testing

**New ungated unit tests** (in `mlxwinotuner.cpp` test block, same style
as existing `formatConv3x3DistributionLine` tests):

1. `planShapeRotation` — five cases:
   - Empty histogram → assert fires
   - Single shape → 1 entry, 19 reps, weight=1.0
   - Two shapes, both above threshold → both kept, proportional + floor
   - Two shapes, minor below threshold → minor dropped
   - Four shapes → top-3 cut, then threshold

2. `buildConv3x3Histograms` — synthetic `ModelDesc` with a mix of
   1×1, 3×3, and 5×5 convs at different channel counts. Verify only 3×3
   contributes and counts match.

**Updated gated tests:**

| Test (env var) | Change |
|---|---|
| `KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST` | Update regex to match new `shape_ms=cNNN:X,...` format |
| `KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST` | Update regex to match new format |
| `KATAGO_MLX_WINOTUNER_RUN_PER_SLOT_TEST` | Rename → `..._RUN_PER_SHAPE_TEST`. Replace per-slot consistency check with: parse `shape_ms=` field from `flatSweepInput:` log line, compare against `scorePerShapeForTesting` on a uniform-histogram model (C=64). Cross-config bound stays at `relErr < 0.50` (winner-vs-default + noise budget, same reasoning as the prior test) |

**Validation required before merge** (per `.claude/MLX_Validation.md`):
- `./katago runnnlayertests` — "MLX Winograd tuner tests passed"
- `./katago runtests` — full suite
- `testgpuerror` against `cpp/eigen_reference_b18.json` — winrate error
  should stay within current tolerances (~10⁻⁴%); this change affects
  which config wins, not the math
- `benchmark` vs Metal at 8 threads, 800 visits, `b18c384nbt` — primary
  signal that the new scoring picks a better candidate. Target: ≥ current
  499 v/s MLX FP16 baseline; a regression below ~470 v/s is a red flag
  warranting investigation

## Risks

1. **The new scoring picks a worse candidate.** Mitigation: if the
   benchmark regresses meaningfully, the per-shape log fields will show
   *which* shape's measurement diverged from prediction, narrowing the
   investigation. The pure `planShapeRotation` function makes it easy to
   manually verify the chosen weights are sensible for the model.

2. **`buildConv3x3Histograms` walks layers differently than the existing
   formatter, producing divergent counts.** Mitigation: refactor the
   formatter to call the new helper, eliminating the parallel
   implementation. Single source of truth.

3. **Floor-bump logic produces over-allocated reps for some edge case.**
   Mitigation: the algorithm is bounded by `kMaxShapes = 3` and the
   `assert` for `> 6 shapes` is unreachable; unit tests exhaust the
   three-shape configurations exhaustively.

4. **`ModelInfoForTuning` API change breaks an external caller.**
   Mitigation: grep confirms the struct has exactly one production call
   site (`mlxbackend.cpp`) and three test sites (`mlxwinotuner.cpp` gated
   tests). All updated as part of this change. The struct is in our
   own namespace and not exported via any public header consumed
   downstream.

## Out of Scope (Future Work)

- Tuning the constants (`kWorkFractionFloor`, `kRepFloor`,
  `kMaxShapes`). Defaults chosen by inspection; if benchmarks show
  candidate-selection volatility, these become candidates for tuning.
- Supporting non-3×3 conv tuning. The Winograd kernels handle only 3×3;
  no current need.
- Recording the histogram in the cache file for diagnostic replay. The
  load-time log line already captures it; the cache file format stays
  minimal.
