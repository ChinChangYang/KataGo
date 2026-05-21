# MLX Tuner Adaptive Scoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the MLX winograd tuner's hardcoded `{trunk, mid, max}` three-slot scoring rotation with a model-adaptive rotation derived from the loaded model's actual 3×3 convolution shape distribution, work-weighted by `count × channels`.

**Architecture:** Two pure helpers (`buildConv3x3Histograms`, `planShapeRotation`) feed shape data through `ModelInfoForTuning` into the score functions, which now loop over a `ShapePlan` list. The shape distribution is computed once at model load and reused for both the existing diagnostic log line and the new score rotation.

**Tech Stack:** C++17, MLX (Apple Silicon), KataGo `core/test.h` assertions, CMake/Ninja build, env-var-gated tests for GPU-touching code.

**Spec:** `docs/superpowers/specs/2026-05-21-mlx-tuner-adaptive-scoring-design.md`

**Predecessor:** `docs/superpowers/plans/2026-05-21-mlx-tuner-shape-diagnostic.md`

---

## File Structure

All changes live in three files. No new files.

- **`cpp/neuralnet/mlxwinotuner.h`** — add `ShapePlan`; add `planShapeRotationForTesting`, `buildConv3x3HistogramsForTesting`, `scorePerShapeForTesting` declarations; replace `midNumChannels`/`maxConvChannels3x3` fields on `ModelInfoForTuning` with two histogram vectors; remove `scoreInputTransformPerSlotForTesting`/`scoreOutputUntransformPerSlotForTesting`.
- **`cpp/neuralnet/mlxwinotuner.cpp`** — implement `planShapeRotation`, `buildConv3x3Histograms`, `scorePerShape`; rewrite `scoreInputTransform`/`scoreOutputUntransform`; refactor `formatConv3x3Distribution` to call `buildConv3x3Histograms`; update `flatSweepInput`/`flatSweepOutput` log format from `trunk_ms=/mid_ms=/max_ms=` to `shape_ms=cN:X,...`; update the 5 gated-test `ModelInfoForTuning mi` construction sites; rename `KATAGO_MLX_WINOTUNER_RUN_PER_SLOT_TEST` → `..._PER_SHAPE_TEST`; add new ungated unit tests for the two new helpers.
- **`cpp/neuralnet/mlxbackend.cpp`** (line 1201) — replace `mid/maxConvChannels3x3` assignments with `buildConv3x3Histograms` call.

---

## Task 1: `planShapeRotation` pure function

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.h:34-40` (add `ShapePlan` struct + declaration)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (add implementation in anonymous namespace; wrapper in `MLXWinogradTuner::` namespace; add ungated tests to `runMLXWinotunerTests()`)

**Background:** `planShapeRotation` is the core selection-and-allocation policy from spec §Selection Rule. It is **pure** — no MLX calls, no I/O. Spec constants:
- `kTotalReps = 20`, `kWarmupReps = 1`, `kMeasureReps = 19`
- `kMaxShapes = 3`, `kWorkFractionFloor = 0.03`, `kRepFloor = 3`

Output invariants: returned vector is **non-empty** (asserts on empty input), sorted descending by `weight`, `Σ measureReps == 19`, `Σ weight == 1.0` (within float tolerance).

- [ ] **Step 1.1: Add `ShapePlan` struct + declaration to header**

In `cpp/neuralnet/mlxwinotuner.h`, immediately after the existing `ModelInfoForTuning` struct definition (around line 40, before the existing `std::string defaultDirectory(...)` declaration), add:

```cpp
  // Per-shape rep allocation produced by planShapeRotation. The tuner loops
  // over a vector<ShapePlan> when scoring a candidate: each entry contributes
  // `weight * median(time over `measureReps` reps at this channel count)` to
  // the total score.
  struct ShapePlan {
    int channels;     // C value to time
    int measureReps;  // number of timing reps (does not include warmup)
    double weight;    // normalized score weight, Σ weights == 1.0
  };

  // Pure, deterministic. Given (channel, count) pairs, returns the planned
  // rotation per spec §Selection Rule:
  //   1. work_i = count_i * channels_i; sort desc by work; take top-3.
  //   2. drop shapes with work < 3% of the post-top3 total work; renormalize.
  //   3. weight_i = work_i / total_work after renormalization.
  //   4. allocate 19 measureReps proportionally; bump any below 3 up to 3,
  //      taking the deficit from the dominant shape; repair rounding so the
  //      dominant absorbs the +/-1 to make Σ measureReps == 19 exactly.
  // Asserts on empty input.
  std::vector<ShapePlan> planShapeRotationForTesting(
      const std::vector<std::pair<int,int>>& histogram);
```

Also ensure `#include <vector>` is present at the top of the header (it is — line 6 imports `<array>`; check that `<vector>` is also transitively present; if not, add `#include <vector>` next to `#include <array>`).

- [ ] **Step 1.2: Add the failing unit tests**

In `cpp/neuralnet/mlxwinotuner.cpp`, inside `void runMLXWinotunerTests()`, immediately after the closing brace of the existing "conv3x3 distribution formatter" test block (the one that ends with `std::cout << "  conv3x3 distribution formatter OK" << std::endl;` around line 982), add a new block:

```cpp
  {
    // planShapeRotation — pure-function tests. Verifies the selection rule
    // (top-3, 3% threshold, 3-rep floor, proportional remainder) directly
    // without any GPU work. Spec §Selection Rule.
    using SP = MLXWinogradTuner::ShapePlan;

    // Case A: single shape — entire budget on that shape, weight = 1.0.
    {
      auto plan = MLXWinogradTuner::planShapeRotationForTesting({{192, 72}});
      testAssert(plan.size() == 1);
      testAssert(plan[0].channels == 192);
      testAssert(plan[0].measureReps == 19);
      testAssert(std::abs(plan[0].weight - 1.0) < 1e-9);
    }

    // Case B: two shapes both above threshold (b18c384nbt-like, after the
    // 22:1 entry has already been dropped by threshold). Expected:
    // work = 192*72, 128*5 = 13824, 640; weights 0.956, 0.044;
    // round(0.956*19)=18, round(0.044*19)=1; floor bumps 1->3; dominant 18-2=16.
    {
      auto plan = MLXWinogradTuner::planShapeRotationForTesting({{192, 72}, {128, 5}});
      testAssert(plan.size() == 2);
      testAssert(plan[0].channels == 192);
      testAssert(plan[1].channels == 128);
      testAssert(plan[0].measureReps == 16);
      testAssert(plan[1].measureReps == 3);
      testAssert(plan[0].measureReps + plan[1].measureReps == 19);
      testAssert(std::abs(plan[0].weight + plan[1].weight - 1.0) < 1e-9);
      testAssert(plan[0].weight > plan[1].weight);
    }

    // Case C: minor shape below 3% threshold — dropped entirely, dominant
    // absorbs all 19 reps. Histogram: 192:72 (work 13824, 95.5%), 22:1 (work 22, 0.15%).
    {
      auto plan = MLXWinogradTuner::planShapeRotationForTesting({{192, 72}, {22, 1}});
      testAssert(plan.size() == 1);
      testAssert(plan[0].channels == 192);
      testAssert(plan[0].measureReps == 19);
      testAssert(std::abs(plan[0].weight - 1.0) < 1e-9);
    }

    // Case D: four shapes — top-3 cut drops the 4th, then threshold drops
    // one more. Input: 384:60, 192:8, 128:5, 64:5. After top-3: drop 64:5.
    // work remaining = 23040, 1536, 640; total 25216; 128's share = 2.54% < 3%
    // -> drop 128. Final: 384 (93.75%) + 192 (6.25%). reps: round(0.9375*19)=18,
    // round(0.0625*19)=1; floor bumps 1->3; dominant 18-2=16.
    {
      auto plan = MLXWinogradTuner::planShapeRotationForTesting(
          {{384, 60}, {192, 8}, {128, 5}, {64, 5}});
      testAssert(plan.size() == 2);
      testAssert(plan[0].channels == 384);
      testAssert(plan[1].channels == 192);
      testAssert(plan[0].measureReps == 16);
      testAssert(plan[1].measureReps == 3);
    }

    // Case E: three shapes all above threshold. Input: 200:10, 100:10, 50:10.
    // work = 2000, 1000, 500; total 3500; shares 57.1%, 28.6%, 14.3% (all >3%).
    // reps: round(0.571*19)=11, round(0.286*19)=5, round(0.143*19)=3.
    // Sum = 19 exactly (no rounding repair needed). All >= floor of 3.
    {
      auto plan = MLXWinogradTuner::planShapeRotationForTesting(
          {{200, 10}, {100, 10}, {50, 10}});
      testAssert(plan.size() == 3);
      testAssert(plan[0].channels == 200);
      testAssert(plan[1].channels == 100);
      testAssert(plan[2].channels == 50);
      int total = plan[0].measureReps + plan[1].measureReps + plan[2].measureReps;
      testAssert(total == 19);
      testAssert(plan[2].measureReps >= 3);
      testAssert(plan[0].measureReps >= plan[1].measureReps);
      testAssert(plan[1].measureReps >= plan[2].measureReps);
    }

    std::cout << "  planShapeRotation OK" << std::endl;
  }
```

- [ ] **Step 1.3: Verify tests fail (no symbol)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
cmake -G Ninja -DUSE_BACKEND=MLX 2>&1 | tail -3
ninja 2>&1 | tail -20
```

Expected: link error like `undefined reference to MLXWinogradTuner::planShapeRotationForTesting`. If the build succeeds, the tests were added wrong — check the step.

- [ ] **Step 1.4: Implement `planShapeRotation`**

In `cpp/neuralnet/mlxwinotuner.cpp`, inside the existing anonymous namespace (after the existing `medianOf6` helper at line 448 is fine — it's near similarly-pure helpers), add:

```cpp
// Selection-and-allocation policy for the work-weighted shape rotation.
// Pure function. Inputs: list of (channels, occurrence_count) pairs from the
// model's 3x3 conv distribution. Output: vector<ShapePlan> sorted desc by
// weight, with Σ measureReps == 19 and Σ weight ≈ 1.0.
//
// Spec §Selection Rule constants:
static constexpr int    kTotalReps         = 20;
static constexpr int    kWarmupReps        = 1;
static constexpr int    kMeasureReps       = kTotalReps - kWarmupReps;  // 19
static constexpr size_t kMaxShapes         = 3;
static constexpr double kWorkFractionFloor = 0.03;
static constexpr int    kRepFloor          = 3;

static std::vector<MLXWinogradTuner::ShapePlan>
planShapeRotation(const std::vector<std::pair<int,int>>& histogram) {
  // Spec §Degenerate Cases: empty histogram is a model-corruption signal we
  // surface, not silently mask.
  assert(!histogram.empty());

  // Step 1: compute work = count * channels; sort desc by work; take top-K.
  struct Entry { int channels; long long work; };
  std::vector<Entry> entries;
  entries.reserve(histogram.size());
  for(const auto& [c, n] : histogram) {
    if(c <= 0 || n <= 0) continue;
    entries.push_back({c, static_cast<long long>(c) * static_cast<long long>(n)});
  }
  assert(!entries.empty());

  std::sort(entries.begin(), entries.end(),
            [](const Entry& a, const Entry& b) {
              if(a.work != b.work) return a.work > b.work;
              return a.channels > b.channels;  // tie-break: larger C first
            });
  if(entries.size() > kMaxShapes)
    entries.resize(kMaxShapes);

  // Step 2: threshold against post-top-K total work; recompute total.
  long long totalWork = 0;
  for(const auto& e : entries) totalWork += e.work;
  assert(totalWork > 0);
  entries.erase(
      std::remove_if(entries.begin(), entries.end(),
          [totalWork](const Entry& e) {
            return static_cast<double>(e.work) / static_cast<double>(totalWork)
                   < kWorkFractionFloor;
          }),
      entries.end());
  // Dominant survives (it's the largest; if its share < 3% then total<dominant/0.03
  // which is impossible). So entries is non-empty.
  assert(!entries.empty());

  totalWork = 0;
  for(const auto& e : entries) totalWork += e.work;

  // Step 3: normalize weights.
  std::vector<MLXWinogradTuner::ShapePlan> plan;
  plan.reserve(entries.size());
  for(const auto& e : entries) {
    MLXWinogradTuner::ShapePlan sp;
    sp.channels = e.channels;
    sp.weight = static_cast<double>(e.work) / static_cast<double>(totalWork);
    sp.measureReps = 0;  // assigned below
    plan.push_back(sp);
  }

  // Step 4: allocate kMeasureReps with floor.
  if(plan.size() == 1) {
    plan[0].measureReps = kMeasureReps;
    return plan;
  }

  // Tentative round-to-nearest allocation.
  int allocated = 0;
  for(auto& sp : plan) {
    sp.measureReps = static_cast<int>(std::lround(sp.weight * kMeasureReps));
    allocated += sp.measureReps;
  }

  // Floor-bump: any minor shape below kRepFloor gets bumped, deficit out of dominant.
  for(size_t i = 1; i < plan.size(); i++) {
    if(plan[i].measureReps < kRepFloor) {
      int deficit = kRepFloor - plan[i].measureReps;
      plan[i].measureReps += deficit;
      plan[0].measureReps -= deficit;
    }
  }

  // Rounding repair: dominant absorbs +/-1 so Σ == kMeasureReps.
  int sum = 0;
  for(const auto& sp : plan) sum += sp.measureReps;
  plan[0].measureReps += (kMeasureReps - sum);

  // Final invariants. The dominant-underflow assert here will fire only for
  // numShapes > 6 (3*kRepFloor + 1 > kMeasureReps), which is unreachable
  // given kMaxShapes = 3.
  assert(plan[0].measureReps >= kRepFloor);
  int finalSum = 0;
  for(const auto& sp : plan) finalSum += sp.measureReps;
  assert(finalSum == kMeasureReps);

  return plan;
}
```

Then, in `cpp/neuralnet/mlxwinotuner.cpp` in the `MLXWinogradTuner::` namespace (alongside the existing `scoreInputTransformForTesting` definitions near line 861), add the test wrapper:

```cpp
std::vector<MLXWinogradTuner::ShapePlan>
MLXWinogradTuner::planShapeRotationForTesting(
    const std::vector<std::pair<int,int>>& histogram) {
  return planShapeRotation(histogram);
}
```

Also ensure these headers are included at the top of `mlxwinotuner.cpp` (likely already present): `<algorithm>` for `std::sort`/`std::remove_if`, `<cmath>` for `std::lround`, `<cassert>` for `assert`. Verify with a grep; if missing, add to the existing include block.

- [ ] **Step 1.5: Build and run tests**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
./katago runnnlayertests 2>&1 | grep -E "planShapeRotation|conv3x3 distribution|MLX Winograd tuner tests" | head
```

Expected:
```
  conv3x3 distribution formatter OK
  planShapeRotation OK
MLX Winograd tuner tests passed
```

If any case fails: the error message will print `testAssert failed: <expression>` with the failing line. Fix the implementation (most likely floor-bump or rounding repair).

- [ ] **Step 1.6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp
git commit -m "Add planShapeRotation pure-function for adaptive scoring

Implements spec §Selection Rule: top-3 + 3% threshold + 3-rep floor +
proportional remainder. Pure function, fully tested with 5 ungated
cases including degenerate single-shape, threshold-drop, top-3 cut,
and three-shape balanced allocation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `buildConv3x3Histograms` helper + refactor formatter

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.h:100-117` (add declaration)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:928-939` (extract histogram-build out of `formatConv3x3Distribution`; add new helper; add unit test)

**Background:** Currently `formatConv3x3Distribution(const ModelDesc&)` walks `modelDesc.iterConvLayers` and builds the two histograms inline. We want the histogram-build to be reusable so `mlxbackend.cpp` can call it once per model load and feed both the formatter and the tuner.

**Design note on testability:** `TrunkDesc` has a deleted copy constructor and only stream-based construction (see `cpp/neuralnet/desc.h:236-258`), so synthesizing a `ModelDesc` in a unit test is impractical. To preserve testability, we split the helper:

- **`buildConv3x3HistogramsFromConvs(const std::vector<ConvLayerDesc>&)`** — the pure, fully testable core. `ConvLayerDesc` has a no-arg default constructor (`cpp/neuralnet/desc.h:25`) and is freely constructible.
- **`buildConv3x3Histograms(const ModelDesc&)`** — thin shim that collects layers via `modelDesc.iterConvLayers` into a `std::vector<ConvLayerDesc>` and delegates to the pure core. Not unit-tested in isolation (would require a real model fixture); covered by integration in Task 6.

Only the pure core is exposed `ForTesting`. The shim is exposed but tested only via the integration path.

- [ ] **Step 2.1: Add declarations to header**

In `cpp/neuralnet/mlxwinotuner.h`, immediately after the existing `formatConv3x3Distribution` declaration (around line 117), add:

```cpp
  // Pure core of the conv-3x3 histogram build: filters to 3x3, returns
  // (channels, count) vectors for inputs and outputs. Decoupled from
  // ModelDesc so it can be tested without synthesizing the
  // copy-deleted/stream-constructed ModelDesc hierarchy.
  std::pair<std::vector<std::pair<int,int>>,
            std::vector<std::pair<int,int>>>
  buildConv3x3HistogramsFromConvsForTesting(
      const std::vector<ConvLayerDesc>& convs);

  // ModelDesc shim. Walks modelDesc.iterConvLayers into a vector and
  // delegates to the pure core above. Used by mlxbackend.cpp at model load.
  std::pair<std::vector<std::pair<int,int>>,
            std::vector<std::pair<int,int>>>
  buildConv3x3Histograms(const ModelDesc& modelDesc);
```

Also ensure `cpp/neuralnet/mlxwinotuner.h` has `#include "../neuralnet/desc.h"` or the appropriate forward-include for `ConvLayerDesc` and `ModelDesc`. The current header has `struct ModelDesc;` as a forward declaration (line 12); add `struct ConvLayerDesc;` next to it. The full include for `ConvLayerDesc` only needs to happen in the `.cpp` if the test references concrete fields.

- [ ] **Step 2.2: Write the failing unit test**

In `cpp/neuralnet/mlxwinotuner.cpp`, ensure `#include "../neuralnet/desc.h"` is present at the top (it likely already is via existing usage; check). Then inside `runMLXWinotunerTests()`, immediately after the `planShapeRotation OK` block added in Task 1, add:

```cpp
  {
    // buildConv3x3HistogramsFromConvs — pure-function test on the conv
    // filter+histogram. Constructs ConvLayerDesc instances directly
    // (default-constructible per desc.h:25); does not touch ModelDesc.

    auto makeConv = [](int kY, int kX, int inC, int outC) {
      ConvLayerDesc c;
      c.convYSize  = kY;
      c.convXSize  = kX;
      c.inChannels = inC;
      c.outChannels = outC;
      return c;
    };

    // Four layers: only the two 3x3 layers should contribute.
    std::vector<ConvLayerDesc> convs = {
      makeConv(1, 1, 10, 10),   // 1x1 — filtered out
      makeConv(3, 3, 20, 30),   // contributes input_c[20]++, output_c[30]++
      makeConv(3, 3, 30, 30),   // contributes input_c[30]++, output_c[30]++
      makeConv(5, 5, 40, 40),   // 5x5 — filtered out
    };

    auto [inHist, outHist] =
        MLXWinogradTuner::buildConv3x3HistogramsFromConvsForTesting(convs);

    // Convert to maps for order-independent comparison.
    std::map<int,int> inMap(inHist.begin(), inHist.end());
    std::map<int,int> outMap(outHist.begin(), outHist.end());

    testAssert(inMap.size() == 2);
    testAssert(inMap[20] == 1);
    testAssert(inMap[30] == 1);
    testAssert(inMap.count(10) == 0);  // 1x1 didn't leak through
    testAssert(inMap.count(40) == 0);  // 5x5 didn't leak through

    testAssert(outMap.size() == 1);
    testAssert(outMap[30] == 2);
    testAssert(outMap.count(10) == 0);
    testAssert(outMap.count(40) == 0);

    // Asymmetric 3x3 (e.g. 3x1) must also be filtered — the kernel is
    // strictly square-3.
    std::vector<ConvLayerDesc> asym = { makeConv(3, 1, 16, 16),
                                        makeConv(1, 3, 16, 16),
                                        makeConv(3, 3, 16, 16) };
    auto [inA, outA] =
        MLXWinogradTuner::buildConv3x3HistogramsFromConvsForTesting(asym);
    testAssert(inA.size() == 1 && inA[0].first == 16 && inA[0].second == 1);
    testAssert(outA.size() == 1 && outA[0].first == 16 && outA[0].second == 1);

    // Empty input → empty histograms (no assert; this is just the pure
    // core. The mlxbackend.cpp call site asserts non-empty after a real
    // model walk; see Step 4.2 comment).
    std::vector<ConvLayerDesc> empty;
    auto [inE, outE] =
        MLXWinogradTuner::buildConv3x3HistogramsFromConvsForTesting(empty);
    testAssert(inE.empty());
    testAssert(outE.empty());

    std::cout << "  buildConv3x3HistogramsFromConvs OK" << std::endl;
  }
```

- [ ] **Step 2.3: Verify test fails (no symbol)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja 2>&1 | tail -5
```

Expected: link error on `buildConv3x3HistogramsForTesting`. If compile error on `ModelDesc` construction, that's a Step-2.2 issue — fix the synthetic-desc code to match the real header.

- [ ] **Step 2.4: Implement `buildConv3x3HistogramsFromConvs`, the ModelDesc shim, and refactor `formatConv3x3Distribution`**

In `cpp/neuralnet/mlxwinotuner.cpp`, replace the existing `formatConv3x3Distribution` implementation at line 928 with the following three functions. The pure core does the filtering; the shim walks the ModelDesc into a vector and delegates; the formatter composes both.

```cpp
// Pure core: filter to 3x3 convs and emit (channels, count) histograms.
// Decoupled from ModelDesc so it's testable without synthesizing the
// copy-deleted ModelDesc hierarchy.
static std::pair<std::vector<std::pair<int,int>>,
                 std::vector<std::pair<int,int>>>
buildConv3x3HistogramsFromConvs(const std::vector<ConvLayerDesc>& convs) {
  std::map<int,int> inputC, outputC;
  for(const auto& c : convs) {
    if(c.convXSize == 3 && c.convYSize == 3) {
      inputC[c.inChannels]++;
      outputC[c.outChannels]++;
    }
  }
  std::vector<std::pair<int,int>> inVec(inputC.begin(), inputC.end());
  std::vector<std::pair<int,int>> outVec(outputC.begin(), outputC.end());
  return {std::move(inVec), std::move(outVec)};
}

std::pair<std::vector<std::pair<int,int>>,
          std::vector<std::pair<int,int>>>
MLXWinogradTuner::buildConv3x3HistogramsFromConvsForTesting(
    const std::vector<ConvLayerDesc>& convs) {
  return buildConv3x3HistogramsFromConvs(convs);
}

// ModelDesc shim. Walks iterConvLayers into a vector and delegates to the
// pure core. Used by mlxbackend.cpp at model load.
std::pair<std::vector<std::pair<int,int>>,
          std::vector<std::pair<int,int>>>
MLXWinogradTuner::buildConv3x3Histograms(const ModelDesc& modelDesc) {
  std::vector<ConvLayerDesc> convs;
  modelDesc.iterConvLayers([&](const ConvLayerDesc& c) { convs.push_back(c); });
  return buildConv3x3HistogramsFromConvs(convs);
}

std::string MLXWinogradTuner::formatConv3x3Distribution(const ModelDesc& modelDesc) {
  // Refactored to share the walker/filter with the tuner; previously
  // built the histograms inline. Walk-once semantics at the call site
  // (mlxbackend.cpp) — that file calls buildConv3x3Histograms once and
  // passes the result to both the tuner and (optionally) the line
  // formatter. This wrapper remains for tests and any caller that only
  // wants the formatted line.
  auto [inVec, outVec] = MLXWinogradTuner::buildConv3x3Histograms(modelDesc);
  std::map<int,int> inMap(inVec.begin(), inVec.end());
  std::map<int,int> outMap(outVec.begin(), outVec.end());
  int total = 0;
  for(const auto& [c, n] : outVec) total += n;  // total = #3x3 convs
  return formatConv3x3DistributionLine(total, inMap, outMap);
}
```

Note the include needed at the top of `mlxwinotuner.cpp` (if not already present): `#include "../neuralnet/desc.h"`. The existing file already uses `ConvLayerDesc` inside the old `formatConv3x3Distribution` lambda, so the include is almost certainly already there — verify with `grep -n "desc.h" cpp/neuralnet/mlxwinotuner.cpp`.

- [ ] **Step 2.5: Build and run tests**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
./katago runnnlayertests 2>&1 | grep -E "buildConv3x3HistogramsFromConvs|conv3x3 distribution|planShapeRotation|MLX Winograd tuner tests"
```

Expected output:
```
  conv3x3 distribution formatter OK
  planShapeRotation OK
  buildConv3x3HistogramsFromConvs OK
MLX Winograd tuner tests passed
```

The existing `conv3x3 distribution formatter OK` test (Cases A/B/C) must still pass — they call `formatConv3x3DistributionLine` directly, which is unchanged.

- [ ] **Step 2.6: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp
git commit -m "Extract buildConv3x3Histograms shared helper

Refactors formatConv3x3Distribution to call a new buildConv3x3Histograms
helper that returns (channels, count) vectors. mlxbackend.cpp will use
this directly at model load to feed both the diagnostic log and the
adaptive tuner with a single descriptor walk.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Extend `ModelInfoForTuning` with histogram fields (additive)

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.h:35-40` (add two histogram-vector fields; keep mid/maxConvChannels3x3 for now)
- Modify: `cpp/neuralnet/mlxbackend.cpp:1201-1210` (call `buildConv3x3Histograms`, populate new fields alongside old ones)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (5 gated-test `mi` construction sites at lines 1151, 1208, 1280, 1360, 1420 — populate new fields with synthetic single-entry histograms)

**Background:** This step adds the new histogram fields **without removing the old `midNumChannels`/`maxConvChannels3x3` fields**. Both are populated at every call site. The scoring code still reads only the old fields. The build stays clean throughout. Task 4 will switch the scorers to read the new fields; Task 5 will remove the old ones.

- [ ] **Step 3.1: Add new fields to `ModelInfoForTuning`**

In `cpp/neuralnet/mlxwinotuner.h`, replace lines 35-40 (the existing struct) with:

```cpp
  struct ModelInfoForTuning {
    int trunkNumChannels;
    int midNumChannels;
    int maxConvChannels3x3;
    int modelVersion;
    // Adaptive-scoring inputs (spec §ModelInfoForTuning Final Form). Both
    // fields are (channel_count, occurrence_count) lists for 3x3 convs of
    // the loaded model; populated by mlxbackend.cpp at load time via
    // buildConv3x3Histograms. Unsorted; planShapeRotation owns selection.
    std::vector<std::pair<int,int>> conv3x3InputHistogram;
    std::vector<std::pair<int,int>> conv3x3OutputHistogram;
  };
```

(`midNumChannels` and `maxConvChannels3x3` are intentionally kept here through Task 4 and removed in Task 5.)

- [ ] **Step 3.2: Populate in mlxbackend.cpp**

Read `cpp/neuralnet/mlxbackend.cpp` lines 1190-1220 to confirm the context. The current code (around line 1201) is:

```cpp
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels   = loadedModel.modelDesc.trunk.trunkNumChannels;
      mi.midNumChannels     = loadedModel.modelDesc.trunk.midNumChannels;
      mi.maxConvChannels3x3 = std::max({
          loadedModel.modelDesc.trunk.trunkNumChannels,
          loadedModel.modelDesc.trunk.midNumChannels,
          ...
      });
      mi.modelVersion = loadedModel.modelDesc.version;
```

(Use Read to confirm exact lines and the `...` content before editing.) Add the histogram-populate calls **immediately before** the `loadOrAutoTune` call (and immediately after the existing `mi.modelVersion = ...` assignment):

```cpp
      // Adaptive-scoring inputs: compute the 3x3 conv distribution once at
      // load time and pass it to the tuner. The existing distribution log
      // call (immediately below if present) can be refactored to use the
      // already-computed `inHist`/`outHist` to avoid a second walk.
      auto [inHist, outHist] =
          MLXWinogradTuner::buildConv3x3Histograms(loadedModel.modelDesc);
      mi.conv3x3InputHistogram  = std::move(inHist);
      mi.conv3x3OutputHistogram = std::move(outHist);
```

- [ ] **Step 3.3: Populate in the 5 gated-test mi-construction sites**

Use grep to locate the five sites:
```bash
grep -n "ModelInfoForTuning mi;" /Users/chinchangyang/Code/KataGo-MLX/cpp/neuralnet/mlxwinotuner.cpp
```

At each site (lines 1151, 1208, 1280, 1360, 1420 in the current file), immediately after the `mi.maxConvChannels3x3 = 64;` line (the last of the existing field assignments for each site), add:

```cpp
      // Synthetic single-shape histogram for the toy C=64 test model.
      mi.conv3x3InputHistogram  = {{64, 1}};
      mi.conv3x3OutputHistogram = {{64, 1}};
```

This makes each test's tuner see a degenerate single-shape model. Each `mi.modelVersion = ...;` line (if any in these sites) stays unchanged.

- [ ] **Step 3.4: Build clean (no behavior change)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja 2>&1 | tail -5
./katago runnnlayertests 2>&1 | tail -3
./katago runtests 2>&1 | tail -3
```

Expected: clean build; `runnnlayertests` still reports `MLX Winograd tuner tests passed`; `runtests` reports `All tests passed`. No behavior change because nothing reads the new fields yet.

- [ ] **Step 3.5: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp cpp/neuralnet/mlxbackend.cpp
git commit -m "Add histogram fields to ModelInfoForTuning (additive)

Extends ModelInfoForTuning with conv3x3InputHistogram and
conv3x3OutputHistogram vectors, populated at the one production call
site (mlxbackend.cpp) and the five gated-test sites. The existing
mid/maxConvChannels3x3 fields are kept until Task 5; scoring code is
not yet rewired (Task 4 does that). No behavior change in this commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Rewrite scoring functions + log format + per-shape diagnostic

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:349-433` (rewrite `scoreInputTransform` / `scoreOutputUntransform`)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:450-561` (replace `scoreInputTransformPerSlot` / `scoreOutputUntransformPerSlot` with `scorePerShape` variants)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:653-724` (`flatSweepInput`: replace `mi.maxConvChannels3x3` for candidate enumeration with max-of-input-histogram; update log format)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:729-785` (`flatSweepOutput`: replace `mi.midNumChannels` with max-of-output-histogram; update log format)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (LOG_FORMAT_TEST + SWEEP_TEST regex updates; PER_SLOT_TEST body update)
- Modify: `cpp/neuralnet/mlxwinotuner.h` (add `scorePerShapeForTesting` declarations)

**Background:** This is the central rewrite. After this task: scoring uses `planShapeRotation` over the histogram fields; log format becomes `shape_ms=cN:X,...`; per-slot diagnostic becomes per-shape. The old `mid/maxConvChannels3x3` fields are still present but no longer read by anything in this file.

- [ ] **Step 4.1: Add per-shape diagnostic declarations to header**

In `cpp/neuralnet/mlxwinotuner.h`, **replace** the existing `scoreInputTransformPerSlotForTesting` and `scoreOutputUntransformPerSlotForTesting` declarations (lines 85-99) with:

```cpp
  // Per-shape median timing for diagnostic logging. Same rotation as the
  // scoring functions, but reports median per planned shape instead of a
  // single weighted score. One entry per shape in planShapeRotation's
  // output, in the same order (dominant first). Used by the flat-sweep
  // log "shape_ms=" field and the gated per-shape consistency test.
  std::vector<std::pair<int,double>>
  scoreInputTransformPerShapeForTesting(const MLXWinograd::InputTransform& cfg,
                                        int N, int H, int W,
                                        const ModelInfoForTuning& mi,
                                        bool useFP16);
  std::vector<std::pair<int,double>>
  scoreOutputUntransformPerShapeForTesting(const MLXWinograd::OutputUntransform& cfg,
                                           int N, int H, int W,
                                           const ModelInfoForTuning& mi,
                                           bool useFP16);
```

- [ ] **Step 4.2: Rewrite `scoreInputTransform`**

In `cpp/neuralnet/mlxwinotuner.cpp`, **replace** the `scoreInputTransform` function body (lines 349-388) with:

```cpp
// Score one input-transform candidate. Adaptive rotation over the model's
// actual 3x3 conv input-channel distribution: planShapeRotation produces a
// list of (channels, measureReps, weight) entries; per shape we time
// `measureReps + 1` reps (1 warmup discarded for the dominant only) and
// take the median, weighted into the final score by `weight`.
static double scoreInputTransform(const MLXWinograd::InputTransform& cfg,
                                  int N, int H, int W,
                                  const MLXWinogradTuner::ModelInfoForTuning& mi,
                                  bool useFP16) {
  auto plan = planShapeRotation(mi.conv3x3InputHistogram);
  assert(!plan.empty());

  // Pre-build one random input array per planned shape. Warmup is one extra
  // measurement on the dominant (plan[0]) that is discarded.
  std::vector<mx::array> inputs;
  inputs.reserve(plan.size());
  uint32_t seed = 0xA1A1A1A1u;
  for(const auto& sp : plan) {
    inputs.push_back(makeRandomInput(N, H, W, sp.channels, seed, useFP16));
    mx::eval(inputs.back());
    seed = seed * 1664525u + 1013904223u;  // distinct seed per shape
  }

  // Warmup: 1 rep on dominant, discarded.
  (void)timeOneInputTransform(cfg, inputs[0], plan[0].channels, useFP16);

  double score = 0.0;
  for(size_t i = 0; i < plan.size(); i++) {
    std::vector<double> samples;
    samples.reserve(plan[i].measureReps);
    for(int r = 0; r < plan[i].measureReps; r++) {
      double ms = timeOneInputTransform(cfg, inputs[i], plan[i].channels, useFP16);
      samples.push_back(ms);
    }
    // Median (upper of two middles for even sizes; identical to nth_element
    // at index size/2). Spec §Score formula.
    std::nth_element(samples.begin(),
                     samples.begin() + samples.size() / 2,
                     samples.end());
    double median = samples[samples.size() / 2];
    if(!std::isfinite(median)) median = 0.0;  // defensive — never emit nan
    score += plan[i].weight * median;
  }
  return score;
}
```

- [ ] **Step 4.3: Rewrite `scoreOutputUntransform`**

In `cpp/neuralnet/mlxwinotuner.cpp`, **replace** `scoreOutputUntransform` function body (lines 391-433) with:

```cpp
// Score one output-untransform candidate. Symmetric to scoreInputTransform:
// adaptive rotation over the model's 3x3 conv output-channel distribution.
static double scoreOutputUntransform(const MLXWinograd::OutputUntransform& cfg,
                                     int N, int H, int W,
                                     const MLXWinogradTuner::ModelInfoForTuning& mi,
                                     bool useFP16) {
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  auto plan = planShapeRotation(mi.conv3x3OutputHistogram);
  assert(!plan.empty());

  std::vector<mx::array> matmulOuts;
  matmulOuts.reserve(plan.size());
  uint32_t seed = 0xD4D4D4D4u;
  for(const auto& sp : plan) {
    matmulOuts.push_back(makeRandomMatmulOut(Ntiles, sp.channels, seed, useFP16));
    mx::eval(matmulOuts.back());
    seed = seed * 1664525u + 1013904223u;
  }

  // Warmup: 1 rep on dominant, discarded.
  (void)timeOneOutputUntransform(cfg, matmulOuts[0], N, H, W,
                                 plan[0].channels, useFP16);

  double score = 0.0;
  for(size_t i = 0; i < plan.size(); i++) {
    std::vector<double> samples;
    samples.reserve(plan[i].measureReps);
    for(int r = 0; r < plan[i].measureReps; r++) {
      double ms = timeOneOutputUntransform(cfg, matmulOuts[i], N, H, W,
                                           plan[i].channels, useFP16);
      samples.push_back(ms);
    }
    std::nth_element(samples.begin(),
                     samples.begin() + samples.size() / 2,
                     samples.end());
    double median = samples[samples.size() / 2];
    if(!std::isfinite(median)) median = 0.0;
    score += plan[i].weight * median;
  }
  return score;
}
```

- [ ] **Step 4.4: Replace per-slot helpers with per-shape helpers**

In `cpp/neuralnet/mlxwinotuner.cpp`, **delete** the entire block lines 436-561 (the `PerSlotTimes` struct, `medianOf6`, `scoreInputTransformPerSlot`, `scoreOutputUntransformPerSlot`) and **replace** with:

```cpp
// Per-shape median timing for diagnostic logging. Same rotation/plan as the
// scoring functions; reports one (channels, median_ms) entry per planned
// shape instead of a single weighted score. Used by the flat-sweep log's
// "shape_ms=" field and the gated per-shape consistency test.

static std::vector<std::pair<int,double>>
scoreInputTransformPerShape(const MLXWinograd::InputTransform& cfg,
                            int N, int H, int W,
                            const MLXWinogradTuner::ModelInfoForTuning& mi,
                            bool useFP16) {
  auto plan = planShapeRotation(mi.conv3x3InputHistogram);
  assert(!plan.empty());

  std::vector<mx::array> inputs;
  inputs.reserve(plan.size());
  uint32_t seed = 0xA1A1A1A1u;
  for(const auto& sp : plan) {
    inputs.push_back(makeRandomInput(N, H, W, sp.channels, seed, useFP16));
    mx::eval(inputs.back());
    seed = seed * 1664525u + 1013904223u;
  }
  (void)timeOneInputTransform(cfg, inputs[0], plan[0].channels, useFP16);

  std::vector<std::pair<int,double>> out;
  out.reserve(plan.size());
  for(size_t i = 0; i < plan.size(); i++) {
    std::vector<double> samples;
    samples.reserve(plan[i].measureReps);
    for(int r = 0; r < plan[i].measureReps; r++) {
      samples.push_back(
          timeOneInputTransform(cfg, inputs[i], plan[i].channels, useFP16));
    }
    std::nth_element(samples.begin(),
                     samples.begin() + samples.size() / 2,
                     samples.end());
    double median = samples[samples.size() / 2];
    if(!std::isfinite(median)) median = 0.0;
    out.emplace_back(plan[i].channels, median);
  }
  return out;
}

static std::vector<std::pair<int,double>>
scoreOutputUntransformPerShape(const MLXWinograd::OutputUntransform& cfg,
                               int N, int H, int W,
                               const MLXWinogradTuner::ModelInfoForTuning& mi,
                               bool useFP16) {
  int Ntiles = N * ((H + 1) / 2) * ((W + 1) / 2);

  auto plan = planShapeRotation(mi.conv3x3OutputHistogram);
  assert(!plan.empty());

  std::vector<mx::array> matmulOuts;
  matmulOuts.reserve(plan.size());
  uint32_t seed = 0xD4D4D4D4u;
  for(const auto& sp : plan) {
    matmulOuts.push_back(makeRandomMatmulOut(Ntiles, sp.channels, seed, useFP16));
    mx::eval(matmulOuts.back());
    seed = seed * 1664525u + 1013904223u;
  }
  (void)timeOneOutputUntransform(cfg, matmulOuts[0], N, H, W,
                                 plan[0].channels, useFP16);

  std::vector<std::pair<int,double>> out;
  out.reserve(plan.size());
  for(size_t i = 0; i < plan.size(); i++) {
    std::vector<double> samples;
    samples.reserve(plan[i].measureReps);
    for(int r = 0; r < plan[i].measureReps; r++) {
      samples.push_back(
          timeOneOutputUntransform(cfg, matmulOuts[i], N, H, W,
                                   plan[i].channels, useFP16));
    }
    std::nth_element(samples.begin(),
                     samples.begin() + samples.size() / 2,
                     samples.end());
    double median = samples[samples.size() / 2];
    if(!std::isfinite(median)) median = 0.0;
    out.emplace_back(plan[i].channels, median);
  }
  return out;
}
```

And **replace** the test-wrapper definitions for the old per-slot helpers (lines 877-893) with:

```cpp
std::vector<std::pair<int,double>>
MLXWinogradTuner::scoreInputTransformPerShapeForTesting(
    const MLXWinograd::InputTransform& cfg,
    int N, int H, int W,
    const ModelInfoForTuning& mi,
    bool useFP16) {
  return scoreInputTransformPerShape(cfg, N, H, W, mi, useFP16);
}

std::vector<std::pair<int,double>>
MLXWinogradTuner::scoreOutputUntransformPerShapeForTesting(
    const MLXWinograd::OutputUntransform& cfg,
    int N, int H, int W,
    const ModelInfoForTuning& mi,
    bool useFP16) {
  return scoreOutputUntransformPerShape(cfg, N, H, W, mi, useFP16);
}
```

- [ ] **Step 4.5: Update `flatSweepInput`: candidate-enumeration C + log format**

In `cpp/neuralnet/mlxwinotuner.cpp` `flatSweepInput`, change line 658 from:

```cpp
  const int C  = mi.maxConvChannels3x3;
```

to:

```cpp
  // Candidate enumeration's vw-divisibility filter uses C as the most
  // restrictive channel count the kernel will encounter. Use the max of the
  // model's actual 3x3 input distribution; equivalent to the old
  // maxConvChannels3x3 for typical models.
  int C = 0;
  for(const auto& [ch, n] : mi.conv3x3InputHistogram) C = std::max(C, ch);
  assert(C > 0);
```

Then **replace** the per-slot log construction (lines 689-708) — specifically the `perSlotStr = ...` block — with:

```cpp
      // Per-shape median timing on the winner — diagnostic only; winner
      // selection above used the weighted score from scoreInputTransform.
      auto perShape = scoreInputTransformPerShape(*best, N, H, W, mi, useFP16);
      perSlotStr = " shape_ms=";
      for(size_t i = 0; i < perShape.size(); i++) {
        if(i > 0) perSlotStr += ",";
        perSlotStr += "c" + std::to_string(perShape[i].first)
                    + ":" + Global::strprintf("%.3f", perShape[i].second);
      }
```

(The variable is still named `perSlotStr` for minimal diff; rename to `perShapeStr` if you prefer — both are fine, just be consistent if you change it.)

- [ ] **Step 4.6: Update `flatSweepOutput`: candidate-enumeration C + log format**

In `cpp/neuralnet/mlxwinotuner.cpp` `flatSweepOutput`, change line 733 from:

```cpp
  const int outC = mi.midNumChannels;  // output untransform reads from matmul output
```

to:

```cpp
  // Output-untransform candidate enumeration doesn't filter on outC
  // (isOutputCandidateValid ignores it — VW=1 monomorphic), but we still
  // pass a representative value. Use the max of the model's actual 3x3
  // output distribution.
  int outC = 0;
  for(const auto& [ch, n] : mi.conv3x3OutputHistogram) outC = std::max(outC, ch);
  assert(outC > 0);
```

Then **replace** the per-slot log construction in `flatSweepOutput` (lines 756-772) with:

```cpp
      auto perShape = scoreOutputUntransformPerShape(*best, N, H, W, mi, useFP16);
      perSlotStr = " shape_ms=";
      for(size_t i = 0; i < perShape.size(); i++) {
        if(i > 0) perSlotStr += ",";
        perSlotStr += "c" + std::to_string(perShape[i].first)
                    + ":" + Global::strprintf("%.3f", perShape[i].second);
      }
```

- [ ] **Step 4.7: Update LOG_FORMAT_TEST and SWEEP_TEST regexes**

The gated tests parse the log line using `std::regex`. Find every regex that mentions `trunk_ms`, `mid_ms`, or `max_ms` in `cpp/neuralnet/mlxwinotuner.cpp`:

```bash
grep -n "trunk_ms\|mid_ms\|max_ms" /Users/chinchangyang/Code/KataGo-MLX/cpp/neuralnet/mlxwinotuner.cpp
```

For each match in a regex literal, change the regex from (example):
```cpp
R"(trunk_ms=[0-9]+\.[0-9]+ mid_ms=[0-9]+\.[0-9]+ max_ms=[0-9]+\.[0-9]+)"
```
to:
```cpp
R"(shape_ms=c[0-9]+:[0-9]+\.[0-9]+(?:,c[0-9]+:[0-9]+\.[0-9]+)*)"
```

This matches one or more `cNNN:F.FFF` entries comma-separated, which is the new format. The regex is anchor-free (ECMAScript default) so it's safe to use with `std::regex_search`.

For any non-regex test that captures `trunk_ms=([0-9.]+)` to parse a numeric value (e.g. the PER_SLOT_TEST at line ~1358 that captures `trunk_ms` from the log to compare against `scoreInputTransformPerSlotForTesting`):

The existing regex like `R"(flatSweepInput:[^\n]*trunk_ms=([0-9]+\.[0-9]+))"` should become `R"(flatSweepInput:[^\n]*shape_ms=c[0-9]+:([0-9]+\.[0-9]+))"` — captures the first (dominant) shape's median.

- [ ] **Step 4.8: Update PER_SLOT_TEST body (rename comes in Task 5)**

The PER_SLOT_TEST block (around line 1352-1414 — confirm with grep on `KATAGO_MLX_WINOTUNER_RUN_PER_SLOT_TEST`) currently calls `scoreInputTransformPerSlotForTesting(...)` three times and takes `min` of `t[0]` (the trunk-slot median). After Task 4 these symbols don't exist.

Replace those calls with:

```cpp
        // Per-shape consistency: parse the dominant shape's median from
        // the flatSweepInput log line (which used scoreInputTransformPerShape
        // on the winner) and compare against scoreInputTransformPerShapeForTesting
        // on the default InputTransform. Cross-config (winner vs default)
        // so a wide relErr bound (<0.50) is appropriate; see spec §Testing.
        std::vector<std::pair<int,double>> r1 =
            MLXWinogradTuner::scoreInputTransformPerShapeForTesting(
                MLXWinograd::InputTransform{}, 1, 19, 19, mi, true);
        std::vector<std::pair<int,double>> r2 =
            MLXWinogradTuner::scoreInputTransformPerShapeForTesting(
                MLXWinograd::InputTransform{}, 1, 19, 19, mi, true);
        std::vector<std::pair<int,double>> r3 =
            MLXWinogradTuner::scoreInputTransformPerShapeForTesting(
                MLXWinograd::InputTransform{}, 1, 19, 19, mi, true);
        testAssert(!r1.empty() && !r2.empty() && !r3.empty());
        // Each result has the same shapes in the same order; take the
        // dominant (index 0) per-shape median across the 3 runs.
        double minOf3 = std::min({r1[0].second, r2[0].second, r3[0].second});
```

The downstream relErr computation (`relErr = fabs(parsedTrunkMs - minOf3) / minOf3`) and assert (`testAssert(relErr < 0.50)`) stay the same — the variable `parsedTrunkMs` is now misnamed (it's the dominant-shape median), but renaming is cosmetic; the spec keeps the 0.50 bound for the same reason.

- [ ] **Step 4.9: Build and run all tests**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
./katago runnnlayertests 2>&1 | tail -10
./katago runtests 2>&1 | tail -3
```

Expected:
- Clean build.
- `runnnlayertests` shows all previously-passing tests still pass: `conv3x3 distribution formatter OK`, `planShapeRotation OK`, `buildConv3x3Histograms OK`, and the `MLX Winograd tuner tests passed` summary.
- `runtests` reports `All tests passed`.

Optional smoke test (gated):
```bash
KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST=1 ./katago runnnlayertests 2>&1 | tail -20
```
Expected: passes; log line shows `shape_ms=c64:X.XXX` (single shape, since histogram is `{{64,1}}`).

- [ ] **Step 4.10: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp
git commit -m "Rewrite MLX tuner scoring to adaptive per-shape rotation

Replaces the hardcoded {trunk, mid, max} 20-rep slot rotation in
scoreInputTransform/scoreOutputUntransform with planShapeRotation over
the model's actual 3x3 conv channel distribution. Per-slot diagnostic
helpers become per-shape. Flat-sweep log format changes from
'trunk_ms=X mid_ms=Y max_ms=Z' to 'shape_ms=cNNN:X,...' and gated test
regexes are updated to match. mid/maxConvChannels3x3 fields are no
longer read by anything in this file but remain in the struct (removed
in Task 5).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Cleanup — remove dead fields, rename gate, drop unused symbols

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.h` (remove `midNumChannels`, `maxConvChannels3x3` from struct)
- Modify: `cpp/neuralnet/mlxbackend.cpp` (remove the assignments for those fields)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (remove the field assignments in 5 gated-test sites; rename `KATAGO_MLX_WINOTUNER_RUN_PER_SLOT_TEST` env var → `..._PER_SHAPE_TEST`; remove any leftover dead symbols referencing `mid/max`)

- [ ] **Step 5.1: Remove fields from struct**

In `cpp/neuralnet/mlxwinotuner.h`, change the struct to:

```cpp
  struct ModelInfoForTuning {
    int trunkNumChannels;   // cache file key
    int modelVersion;       // cache file key
    std::vector<std::pair<int,int>> conv3x3InputHistogram;
    std::vector<std::pair<int,int>> conv3x3OutputHistogram;
  };
```

- [ ] **Step 5.2: Remove field assignments in mlxbackend.cpp**

In `cpp/neuralnet/mlxbackend.cpp` line 1201 area, **delete** the `mi.midNumChannels = ...` line and the `mi.maxConvChannels3x3 = std::max({...})` block (typically 5-10 lines including the `std::max` initializer list). Verify the remaining mi setup is:

```cpp
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels   = loadedModel.modelDesc.trunk.trunkNumChannels;
      mi.modelVersion       = loadedModel.modelDesc.version;
      auto [inHist, outHist] =
          MLXWinogradTuner::buildConv3x3Histograms(loadedModel.modelDesc);
      mi.conv3x3InputHistogram  = std::move(inHist);
      mi.conv3x3OutputHistogram = std::move(outHist);
```

- [ ] **Step 5.3: Remove field assignments in 5 gated-test sites**

In each of the five `ModelInfoForTuning mi;` blocks in `cpp/neuralnet/mlxwinotuner.cpp` (use `grep -n "ModelInfoForTuning mi;"`), **delete** the two lines:

```cpp
      mi.midNumChannels      = 64;
      mi.maxConvChannels3x3  = 64;
```

The remaining setup for each site should now be:

```cpp
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels    = 64;
      mi.modelVersion        = ...;  // unchanged
      mi.conv3x3InputHistogram  = {{64, 1}};
      mi.conv3x3OutputHistogram = {{64, 1}};
```

- [ ] **Step 5.4: Rename env-var gate**

Replace all occurrences of `KATAGO_MLX_WINOTUNER_RUN_PER_SLOT_TEST` with `KATAGO_MLX_WINOTUNER_RUN_PER_SHAPE_TEST` in `cpp/neuralnet/mlxwinotuner.cpp`:

```bash
grep -n "KATAGO_MLX_WINOTUNER_RUN_PER_SLOT_TEST" /Users/chinchangyang/Code/KataGo-MLX/cpp/neuralnet/mlxwinotuner.cpp
```

For each match (the `std::getenv` call and any comments referencing the gate), update to `_PER_SHAPE_TEST`.

- [ ] **Step 5.5: Verify no dead symbols remain**

```bash
grep -n "midNumChannels\|maxConvChannels3x3\|scoreInputTransformPerSlot\|scoreOutputUntransformPerSlot\|PerSlotTimes\|trunk_ms\|mid_ms\|max_ms" /Users/chinchangyang/Code/KataGo-MLX/cpp/neuralnet/mlxwinotuner.h /Users/chinchangyang/Code/KataGo-MLX/cpp/neuralnet/mlxwinotuner.cpp /Users/chinchangyang/Code/KataGo-MLX/cpp/neuralnet/mlxbackend.cpp
```

Expected: **no matches**. If any remain, they're stale leftovers — clean them up in this commit.

- [ ] **Step 5.6: Build clean and run tests**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
./katago runnnlayertests 2>&1 | tail -10
./katago runtests 2>&1 | tail -3
```

Expected: clean build; both test commands report passing.

- [ ] **Step 5.7: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp cpp/neuralnet/mlxbackend.cpp
git commit -m "Remove deprecated mid/maxConvChannels3x3 from ModelInfoForTuning

Cleans up dead fields and the per-slot diagnostic symbols replaced in
Task 4. Renames KATAGO_MLX_WINOTUNER_RUN_PER_SLOT_TEST to
KATAGO_MLX_WINOTUNER_RUN_PER_SHAPE_TEST. ModelInfoForTuning now carries
only the four fields the tuner actually reads.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: End-to-end validation

**Files:** none modified. This task verifies the implementation against the spec's success criteria (§Testing → Validation required before merge).

- [ ] **Step 6.1: Full test suite**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
./katago runnnlayertests 2>&1 | tee /tmp/sp_runnnlayertests.log | tail -20
./katago runtests 2>&1 | tee /tmp/sp_runtests.log | tail -5
```

Expected: `runnnlayertests` ends with `MLX Winograd tuner tests passed` and `Done`; `runtests` ends with `All tests passed`. If either fails, abort and fix before merging.

- [ ] **Step 6.2: Gated regression**

```bash
KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST=1 \
KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST=1 \
KATAGO_MLX_WINOTUNER_RUN_PER_SHAPE_TEST=1 \
  ./katago runnnlayertests 2>&1 | tail -30
```

Expected: all three gated tests pass. Output should include the new log format `shape_ms=c64:X.XXX`.

- [ ] **Step 6.3: Cross-backend correctness vs Eigen reference**

Reference file `cpp/eigen_reference_b18.json` should already exist from prior validation (see `.claude/MLX_Validation.md`).

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model ~/.katago/b18c384nbt-uec-20221121b.bin.gz \
  -config configs/gtp_example.cfg \
  -reference-file eigen_reference_b18.json 2>&1 | tail -40
```

Expected (per CLAUDE.md targets and prior snapshot):
- `winrateError` avg ≤ ~0.001%, max ≤ ~0.1%
- `scoreMeanError` avg ≤ ~0.001, max ≤ ~0.01

If errors are dramatically larger than the prior snapshot (≥10× regression), abort — adaptive scoring changed *which* configs win, but the kernel math is unchanged, so error should be statistically equivalent. Significant divergence indicates a real correctness regression in the rewrite.

If the reference file is missing, see `.claude/MLX_Validation.md` § "Generate the Eigen reference" — it's an ~hours-long one-time CPU job; do not block on it if it doesn't exist locally.

- [ ] **Step 6.4: Throughput benchmark vs prior baseline**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago benchmark -model ~/.katago/b18c384nbt-uec-20221121b.bin.gz \
  -config configs/gtp_example.cfg -t 8 -v 800 2>&1 | tail -20
```

Expected: visits/s ≥ ~470 (current baseline is 499 v/s MLX FP16; ~5% noise budget; spec target is no regression below ~470 v/s). A meaningful regression here is the primary signal that the adaptive scoring picked a worse candidate — flag for investigation rather than silently merging.

If benchmark shows a clear improvement, update `.claude/MLX_Validation.md` snapshot with the new numbers (date 2026-05-21) and the reproduction command. Do **not** commit this file (it's claude-local, untracked).

- [ ] **Step 6.5: Final commit (validation notes)**

If validation passes cleanly, no further code commit is needed; the previous task commits cover the implementation.

If `.claude/MLX_Validation.md` was updated in step 6.4, that file is untracked and intentionally not committed (per its own header).

If validation flagged a regression and a fix was needed, commit the fix with a message referencing the regression and the spec:

```bash
git commit -m "Fix <issue> in adaptive scoring

Caught by Task 6 validation: <description>. Spec
docs/superpowers/specs/2026-05-21-mlx-tuner-adaptive-scoring-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Plan Self-Review Checklist

After completing all tasks, verify:

- **Spec §Selection Rule:** implemented in Task 1's `planShapeRotation`. Constants match (`kMaxShapes=3`, `kWorkFractionFloor=0.03`, `kRepFloor=3`).
- **Spec §ModelInfoForTuning Final Form:** struct ends up with exactly four fields (Task 5). No `midNumChannels` or `maxConvChannels3x3`.
- **Spec §Log Format Changes:** `shape_ms=cN:X,...` format implemented in Task 4 (steps 4.5 and 4.6); regexes updated (step 4.7).
- **Spec §API Surface:** header has `ShapePlan`, `planShapeRotationForTesting`, `buildConv3x3HistogramsFromConvsForTesting`, `buildConv3x3Histograms`, `scoreInputTransformPerShapeForTesting`, `scoreOutputUntransformPerShapeForTesting`. Old `_PerSlotForTesting` symbols deleted.
- **Spec §Testing:** five `planShapeRotation` ungated cases (Task 1); `buildConv3x3Histograms` ungated test (Task 2); LOG_FORMAT / SWEEP / PER_SHAPE gated tests updated and renamed (Tasks 4-5); end-to-end validation (Task 6).
- **Spec §Degenerate Cases:** empty histogram asserts at the `planShapeRotation` entry point (Task 1, step 1.4). Single-shape histogram → full budget on the one shape (Task 1, case A).
