# MLX Tuner Shape Diagnostic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two observability log lines to the MLX winograd tuner (conv-3x3 shape distribution at model load; per-slot median timing on flat-sweep winners) so a single tuner run produces enough data to decide between weighting-axis and estimator-axis next steps.

**Architecture:** Two pure-additive log lines, no scoring logic change. Distribution log is computed from `ModelDesc::iterConvLayers` at `mlxbackend.cpp` before the tuner call (so it prints on cache hit too). Per-slot log is computed by a new per-slot scoring variant (`scoreInputTransformPerSlot`/`scoreOutputUntransformPerSlot`) that re-runs the same 20-rep rotation on the winner only, reporting median-of-6 reps per slot. Cost: ~60 ms added to a ~40 s sweep; descriptor walk is microseconds.

**Tech Stack:** C++17, MLX (Apple Silicon backend), KataGo neuralnet pluggable-backend framework, gated test pattern via env vars (`KATAGO_MLX_WINOTUNER_RUN_*`).

**Spec:** `docs/superpowers/specs/2026-05-21-mlx-tuner-shape-diagnostic-design.md`

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `cpp/neuralnet/mlxwinotuner.cpp` | Per-slot scoring primitives, log extensions, distribution formatter, tests | Modify |
| `cpp/neuralnet/mlxwinotuner.h` | Test-only forward decls + public formatter API | Modify |
| `cpp/neuralnet/mlxbackend.cpp` | Wire distribution log into model-load path | Modify |

No new files, no CMake change.

---

## Task 1: Per-slot scoring primitives

Add a new struct `PerSlotTimes` and two anonymous-namespace functions `scoreInputTransformPerSlot` / `scoreOutputUntransformPerSlot` that run the same 20-rep `slot % 10` rotation as the existing scorers but report median-of-6 reps per slot instead of a weighted mean. Expose via `*ForTesting` wrappers for unit tests and downstream tasks.

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.h` — add two test-only forward decls.
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` — add `PerSlotTimes` struct, `medianOf6` helper, two scoring functions, two test-only wrappers, one gated sanity-check test.

- [ ] **Step 1: Add test-only forward decls to `mlxwinotuner.h`**

Open `cpp/neuralnet/mlxwinotuner.h`. After the existing `scoreOutputUntransformForTesting` declaration (currently at lines 77-80), insert:

```cpp
  // Test-only — per-slot median scoring primitives. Same 20-rep rotation
  // as scoreInputTransformForTesting / scoreOutputUntransformForTesting,
  // but reports median-of-6 reps per slot ({trunk, mid, max} in that
  // index order) instead of a single weighted mean. Used by the
  // diagnostic log fields and the gated per-slot consistency test.
  std::array<double,3>
  scoreInputTransformPerSlotForTesting(const MLXWinograd::InputTransform& cfg,
                                       int N, int H, int W,
                                       const ModelInfoForTuning& mi,
                                       bool useFP16);
  std::array<double,3>
  scoreOutputUntransformPerSlotForTesting(const MLXWinograd::OutputUntransform& cfg,
                                          int N, int H, int W,
                                          const ModelInfoForTuning& mi,
                                          bool useFP16);
```

The header already includes `<array>` indirectly via standard headers brought in by the existing test-only wrappers' return type — but to be safe, also add `#include <array>` near the top of the header if it's not already present (search for `#include <array>` first; only add if missing).

- [ ] **Step 2: Write the failing test (sanity check, gated)**

Open `cpp/neuralnet/mlxwinotuner.cpp`. Find the closing `}` of the `KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST`-gated test block that ends at approximately line 1070 (the existing "baseline-consistency (gated) OK" test). Immediately after its closing `}` (one closing brace for the inner test block, then we're back inside `runMLXWinotunerTests`), insert this new gated block:

```cpp
  {
    // Per-slot scoring smoke test: verify that scoreInputTransformPerSlot
    // and scoreOutputUntransformPerSlot return three finite positive values
    // each for a default-constructed InputTransform/OutputUntransform on a
    // tiny shape. Gated under the same env var as the other GPU-touching
    // tests; ungated CI shouldn't pay for GPU work.
    const char* gate = std::getenv("KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST");
    if(gate != nullptr && std::string(gate) == "1") {
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels    = 64;
      mi.midNumChannels      = 64;
      mi.maxConvChannels3x3  = 64;
      mi.modelVersion        = 11;

      std::array<double,3> in = MLXWinogradTuner::scoreInputTransformPerSlotForTesting(
          MLXWinograd::InputTransform{}, 1, 19, 19, mi, true);
      for(double v : in) {
        testAssert(std::isfinite(v));
        testAssert(v > 0.0);
        testAssert(v < 1000.0);  // sanity: <1s per call on Apple Silicon
      }

      std::array<double,3> out = MLXWinogradTuner::scoreOutputUntransformPerSlotForTesting(
          MLXWinograd::OutputUntransform{}, 1, 19, 19, mi, true);
      for(double v : out) {
        testAssert(std::isfinite(v));
        testAssert(v > 0.0);
        testAssert(v < 1000.0);
      }
      std::cout << "  per-slot scoring smoke (gated) OK"
                << " in={" << in[0] << "," << in[1] << "," << in[2] << "}"
                << " out={" << out[0] << "," << out[1] << "," << out[2] << "}"
                << std::endl;
    }
  }
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
cmake -G Ninja -DUSE_BACKEND=MLX
ninja
```

Expected: compile error — `scoreInputTransformPerSlotForTesting` and `scoreOutputUntransformPerSlotForTesting` are declared but not defined; linker (or compiler if the header decl is missing) will reject the test references.

- [ ] **Step 4: Add `PerSlotTimes`, `medianOf6`, and the two scoring functions**

In `cpp/neuralnet/mlxwinotuner.cpp`, locate the `scoreOutputUntransform` function definition that ends at approximately line 433 (the line containing `return totalMs / totalWeight;` followed by `}`). Immediately after that closing `}` and **before** the closing `} // namespace` of the anonymous namespace at line 435, insert:

```cpp
// Per-slot timing breakdown for diagnostic logging. Same 20-rep rotation
// as scoreInputTransform but reports median-of-6 reps per slot (no
// weighting). Robust to per-call jitter; used to compare against the
// sweep's weighted-mean estimator in the flat-sweep log lines.
struct PerSlotTimes { double trunkMs; double midMs; double maxMs; };

// 6-element median: upper of two middle values (index 3 of sorted 0..5).
// Deterministic; avoids float averaging. std::nth_element partially sorts
// in O(n).
static double medianOf6(std::array<double,6> a) {
  std::nth_element(a.begin(), a.begin() + 3, a.end());
  return a[3];
}

static PerSlotTimes scoreInputTransformPerSlot(
    const MLXWinograd::InputTransform& cfg,
    int N, int H, int W,
    const MLXWinogradTuner::ModelInfoForTuning& mi,
    bool useFP16) {
  mx::array inTrunk = makeRandomInput(N, H, W, mi.trunkNumChannels,    0xA1A1A1A1u, useFP16);
  mx::array inMid   = makeRandomInput(N, H, W, mi.midNumChannels,      0xB2B2B2B2u, useFP16);
  mx::array inMax   = makeRandomInput(N, H, W, mi.maxConvChannels3x3,  0xC3C3C3C3u, useFP16);
  mx::eval(inTrunk); mx::eval(inMid); mx::eval(inMax);

  std::array<double,6> trunkReps{}, midReps{}, maxReps{};
  int trunkIdx = 0, midIdx = 0, maxIdx = 0;

  const int reps = 20;
  for(int i = 0; i < reps; i++) {
    if(i % 10 == 0) {
      // Warmup — measure but discard (matches scoreInputTransform's weight=0 rep).
      (void)timeOneInputTransform(cfg, inTrunk, mi.trunkNumChannels, useFP16);
      continue;
    }
    int slot;
    switch(i % 10) {
      case 1: case 4: case 7: slot = 0; break;
      case 2: case 5: case 8: slot = 1; break;
      case 3: case 6: case 9: slot = 2; break;
      default: ASSERT_UNREACHABLE; slot = 0; break;
    }
    int channels = (slot == 0) ? mi.trunkNumChannels
                 : (slot == 1) ? mi.midNumChannels
                 :               mi.maxConvChannels3x3;
    const mx::array& inp = (slot == 0) ? inTrunk
                         : (slot == 1) ? inMid
                         :               inMax;
    double ms = timeOneInputTransform(cfg, inp, channels, useFP16);
    if(slot == 0)      trunkReps[trunkIdx++] = ms;
    else if(slot == 1) midReps[midIdx++]     = ms;
    else               maxReps[maxIdx++]     = ms;
  }

  // Defensive: if a slot's median is non-finite (e.g. an aborted measurement
  // producing NaN), clamp to 0 so %.3f doesn't emit "nan" and break the
  // log-format regex consumers downstream.
  auto clamp = [](double x) { return std::isfinite(x) ? x : 0.0; };
  return PerSlotTimes{
    clamp(medianOf6(trunkReps)),
    clamp(medianOf6(midReps)),
    clamp(medianOf6(maxReps))
  };
}

// Symmetric for output untransform — same rotation, median-of-6 per slot.
static PerSlotTimes scoreOutputUntransformPerSlot(
    const MLXWinograd::OutputUntransform& cfg,
    int N, int H, int W,
    const MLXWinogradTuner::ModelInfoForTuning& mi,
    bool useFP16) {
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  mx::array mTrunk = makeRandomMatmulOut(Ntiles, mi.trunkNumChannels,    0xD4D4D4D4u, useFP16);
  mx::array mMid   = makeRandomMatmulOut(Ntiles, mi.midNumChannels,      0xE5E5E5E5u, useFP16);
  mx::array mMax   = makeRandomMatmulOut(Ntiles, mi.maxConvChannels3x3,  0xF6F6F6F6u, useFP16);
  mx::eval(mTrunk); mx::eval(mMid); mx::eval(mMax);

  std::array<double,6> trunkReps{}, midReps{}, maxReps{};
  int trunkIdx = 0, midIdx = 0, maxIdx = 0;

  const int reps = 20;
  for(int i = 0; i < reps; i++) {
    if(i % 10 == 0) {
      (void)timeOneOutputUntransform(cfg, mTrunk, N, H, W, mi.trunkNumChannels, useFP16);
      continue;
    }
    int slot;
    switch(i % 10) {
      case 1: case 4: case 7: slot = 0; break;
      case 2: case 5: case 8: slot = 1; break;
      case 3: case 6: case 9: slot = 2; break;
      default: ASSERT_UNREACHABLE; slot = 0; break;
    }
    int outC = (slot == 0) ? mi.trunkNumChannels
             : (slot == 1) ? mi.midNumChannels
             :               mi.maxConvChannels3x3;
    const mx::array& mIn = (slot == 0) ? mTrunk
                         : (slot == 1) ? mMid
                         :               mMax;
    double ms = timeOneOutputUntransform(cfg, mIn, N, H, W, outC, useFP16);
    if(slot == 0)      trunkReps[trunkIdx++] = ms;
    else if(slot == 1) midReps[midIdx++]     = ms;
    else               maxReps[maxIdx++]     = ms;
  }

  auto clamp = [](double x) { return std::isfinite(x) ? x : 0.0; };
  return PerSlotTimes{
    clamp(medianOf6(trunkReps)),
    clamp(medianOf6(midReps)),
    clamp(medianOf6(maxReps))
  };
}
```

- [ ] **Step 5: Add the test-only wrappers**

In `cpp/neuralnet/mlxwinotuner.cpp`, find the existing `scoreOutputUntransformForTesting` function at approximately lines 718-724. Immediately after its closing `}`, insert:

```cpp
std::array<double,3> MLXWinogradTuner::scoreInputTransformPerSlotForTesting(
    const MLXWinograd::InputTransform& cfg,
    int N, int H, int W,
    const ModelInfoForTuning& mi,
    bool useFP16) {
  PerSlotTimes t = scoreInputTransformPerSlot(cfg, N, H, W, mi, useFP16);
  return {t.trunkMs, t.midMs, t.maxMs};
}

std::array<double,3> MLXWinogradTuner::scoreOutputUntransformPerSlotForTesting(
    const MLXWinograd::OutputUntransform& cfg,
    int N, int H, int W,
    const ModelInfoForTuning& mi,
    bool useFP16) {
  PerSlotTimes t = scoreOutputUntransformPerSlot(cfg, N, H, W, mi, useFP16);
  return {t.trunkMs, t.midMs, t.maxMs};
}
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST=1 ./katago runnnlayertests 2>&1 | grep -A1 "per-slot scoring smoke"
```

Expected: line containing `per-slot scoring smoke (gated) OK in={...} out={...}` with six positive numbers.

Also confirm the ungated path still works (no GPU work expected, just compile + load):

```bash
./katago runnnlayertests 2>&1 | tail -5
```

Expected: prints `MLX Winograd tuner tests passed` (and the other existing test PASS lines), no failure.

- [ ] **Step 7: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp
git commit -m "Add per-slot median scoring primitives to MLX tuner

PerSlotTimes struct + scoreInputTransformPerSlot/scoreOutputUntransformPerSlot
in the anonymous namespace, with test-only ForTesting wrappers exposed via
mlxwinotuner.h. Same 20-rep slot-rotation as the existing scorers; reports
median-of-6 reps per slot instead of a weighted mean. Gated smoke test in
runMLXWinotunerTests confirms the wrappers return three finite positive
values on a synthetic 19x19 C=64 shape.

These primitives are infrastructure for the upcoming per-slot timing
breakdown in flat-sweep log lines (next task).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Per-slot fields in flat-sweep log

Extend `flatSweepInput` and `flatSweepOutput` to re-measure the chosen winner via the per-slot scoring functions and append `trunk_ms`, `mid_ms`, `max_ms` to the existing log line. Extend the gated log-format regex test to require the new fields.

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` — extend `flatSweepInput` (around lines 526-583) and `flatSweepOutput` (around lines 588-634) log statements; extend gated Test 1 regex.

- [ ] **Step 1: Update the failing test (tighten Test 1 regex)**

In `cpp/neuralnet/mlxwinotuner.cpp`, locate the gated log-format test at approximately line 985. Replace the existing input regex line:

```cpp
      std::regex inputRe(
          R"(MLX tuner flatSweepInput: considered=[0-9]+ best=tg0=[0-9]+ tg1=[0-9]+ wpt=[0-9]+ vw=[0-9]+ gridOrder=[01] time_ms=[0-9]+\.[0-9]+ baseline_ms=[0-9]+\.[0-9]+ delta_pct=[-+][0-9]+\.[0-9]+)");
```

with:

```cpp
      // Updated for shape diagnostic: regex now requires the per-slot
      // median fields appended by flatSweepInput.
      std::regex inputRe(
          R"(MLX tuner flatSweepInput: considered=[0-9]+ best=tg0=[0-9]+ tg1=[0-9]+ wpt=[0-9]+ vw=[0-9]+ gridOrder=[01] time_ms=[0-9]+\.[0-9]+ baseline_ms=[0-9]+\.[0-9]+ delta_pct=[-+][0-9]+\.[0-9]+ trunk_ms=[0-9]+\.[0-9]+ mid_ms=[0-9]+\.[0-9]+ max_ms=[0-9]+\.[0-9]+)");
```

Similarly, replace the output regex at approximately line 990:

```cpp
      std::regex outputRe(
          R"(MLX tuner flatSweepOutput: considered=[0-9]+ best=tg0=[0-9]+ tg1=[0-9]+ wpt=[0-9]+ time_ms=[0-9]+\.[0-9]+ baseline_ms=[0-9]+\.[0-9]+ delta_pct=[-+][0-9]+\.[0-9]+)");
```

with:

```cpp
      std::regex outputRe(
          R"(MLX tuner flatSweepOutput: considered=[0-9]+ best=tg0=[0-9]+ tg1=[0-9]+ wpt=[0-9]+ time_ms=[0-9]+\.[0-9]+ baseline_ms=[0-9]+\.[0-9]+ delta_pct=[-+][0-9]+\.[0-9]+ trunk_ms=[0-9]+\.[0-9]+ mid_ms=[0-9]+\.[0-9]+ max_ms=[0-9]+\.[0-9]+)");
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST=1 ./katago runnnlayertests 2>&1 | tail -20
```

Expected: a `testAssert` failure on the regex check (the log lines still end at `delta_pct=...`; they don't yet include the new `trunk_ms / mid_ms / max_ms` suffix).

- [ ] **Step 3: Extend `flatSweepInput`'s log statement**

In `cpp/neuralnet/mlxwinotuner.cpp`, locate `flatSweepInput` at approximately lines 526-583. Find the block beginning `if(logger) {` at approximately line 560. Replace the entire `if(logger) { ... }` block with:

```cpp
  if(logger) {
    std::string deltaStr;
    std::string perSlotStr;
    if(best && baselineMs >= 1e-9) {
      double deltaPct = (bestTime - baselineMs) / baselineMs * 100.0;
      // %+.1f always emits a sign; the gated log-format test regex relies on
      // this (matches [-+], not [-+]?). Don't drop the + flag.
      deltaStr = Global::strprintf("%+.1f", deltaPct);

      // Re-measure the winner with per-slot median timing. ~30 ms extra GPU
      // work per stage; negligible vs the ~40s total sweep wall-time. Fields
      // are diagnostic only — winner selection above used the symmetric
      // weighted-mean score; this is for noise/bias analysis.
      PerSlotTimes ps = scoreInputTransformPerSlot(*best, N, H, W, mi, useFP16);
      perSlotStr = " trunk_ms=" + Global::strprintf("%.3f", ps.trunkMs)
                 + " mid_ms="   + Global::strprintf("%.3f", ps.midMs)
                 + " max_ms="   + Global::strprintf("%.3f", ps.maxMs);
    } else {
      deltaStr = "nan";
      // best=none branch: omit per-slot fields (matches existing degenerate
      // log shape; spec §4 / §Error handling).
      perSlotStr = "";
    }
    logger->write("MLX tuner flatSweepInput: considered=" + std::to_string(considered)
                  + (best
                     ? " best=tg0=" + std::to_string(best->tg0)
                       + " tg1=" + std::to_string(best->tg1)
                       + " wpt=" + std::to_string(best->wpt)
                       + " vw="  + std::to_string(best->vw)
                       + " gridOrder=" + std::to_string((int)best->gridOrder)
                       + " time_ms=" + Global::strprintf("%.3f", bestTime)
                     : " best=none")
                  + " baseline_ms=" + Global::strprintf("%.3f", baselineMs)
                  + " delta_pct=" + deltaStr
                  + perSlotStr);
  }
```

- [ ] **Step 4: Extend `flatSweepOutput`'s log statement**

In the same file, locate `flatSweepOutput` at approximately lines 588-634. Find the `if(logger) {` block at approximately line 613. Replace it with:

```cpp
  if(logger) {
    std::string deltaStr;
    std::string perSlotStr;
    if(best && baselineMs >= 1e-9) {
      double deltaPct = (bestTime - baselineMs) / baselineMs * 100.0;
      // %+.1f always emits a sign; the gated log-format test regex relies on
      // this (matches [-+], not [-+]?). Don't drop the + flag.
      deltaStr = Global::strprintf("%+.1f", deltaPct);

      // Re-measure the winner with per-slot median timing. Symmetric to
      // flatSweepInput. ~30 ms extra GPU work.
      PerSlotTimes ps = scoreOutputUntransformPerSlot(*best, N, H, W, mi, useFP16);
      perSlotStr = " trunk_ms=" + Global::strprintf("%.3f", ps.trunkMs)
                 + " mid_ms="   + Global::strprintf("%.3f", ps.midMs)
                 + " max_ms="   + Global::strprintf("%.3f", ps.maxMs);
    } else {
      deltaStr = "nan";
      perSlotStr = "";
    }
    logger->write("MLX tuner flatSweepOutput: considered=" + std::to_string(considered)
                  + (best
                     ? " best=tg0=" + std::to_string(best->tg0)
                       + " tg1=" + std::to_string(best->tg1)
                       + " wpt=" + std::to_string(best->wpt)
                       + " time_ms=" + Global::strprintf("%.3f", bestTime)
                     : " best=none")
                  + " baseline_ms=" + Global::strprintf("%.3f", baselineMs)
                  + " delta_pct=" + deltaStr
                  + perSlotStr);
  }
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST=1 ./katago runnnlayertests 2>&1 | grep -A1 "log-format"
```

Expected: `flatSweepInput log-format (gated) OK` and `flatSweepOutput log-format (gated) OK` both print.

- [ ] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxwinotuner.cpp
git commit -m "Append per-slot median timings to MLX flat-sweep log lines

Both flatSweepInput and flatSweepOutput now re-measure the chosen winner
via scoreInputTransformPerSlot / scoreOutputUntransformPerSlot and append
trunk_ms / mid_ms / max_ms to the existing log line. ~30 ms overhead per
stage; negligible against the ~40s total sweep wall-time.

The per-slot fields complement the existing time_ms (weighted mean) by
giving a jitter-robust per-slot signal. If the two estimators disagree
by more than typical jitter, that's direct evidence the sweep's mean is
being pulled by outliers — useful diagnostic for the upcoming estimator-
axis decision.

Extends the existing gated log-format regex test to require the new
fields.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Conv-3x3 distribution formatter

Add a pure formatter `formatConv3x3DistributionLine(total, inputC, outputC)` plus a `ModelDesc`-walking wrapper `formatConv3x3Distribution(modelDesc)`. Pure formatter is testable without constructing synthetic ModelDescs (which is awkward due to ConvLayerDesc being non-copyable).

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.h` — add public declarations for both functions.
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` — implement both; add ungated unit tests for the pure formatter.

- [ ] **Step 1: Add forward decls to `mlxwinotuner.h`**

In `cpp/neuralnet/mlxwinotuner.h`, find the `namespace MLXWinogradTuner {` block. After the per-slot `*ForTesting` declarations added in Task 1, but **before** the closing `}` of the namespace (which currently sits at line 81), insert:

```cpp
  // Conv-3x3 shape distribution log: one-line summary of the model's 3x3
  // conv shape mix, computed at model load and printed alongside the tuner
  // log so operators can correlate cached winners with the per-pass shape
  // distribution the cache was tuned for. Pure formatter is exposed for
  // testability; wrapper does the descriptor walk.
  //
  // formatConv3x3DistributionLine: pure function — given pre-computed
  // histograms keyed by channel count, returns the log line. No I/O.
  std::string formatConv3x3DistributionLine(
      int total,
      const std::map<int,int>& inputChannelCounts,
      const std::map<int,int>& outputChannelCounts);

  // formatConv3x3Distribution: walks modelDesc.iterConvLayers, accumulates
  // input/output channel histograms over 3x3 convs only, calls the
  // formatter. Single line; safe to log on every model load.
  std::string formatConv3x3Distribution(const ModelDesc& modelDesc);
```

The header also needs `#include <map>` and `#include <string>` if not present; the latter is almost certainly already included. Search and add only what's missing.

You'll also need to forward-declare `struct ModelDesc;` in the header (it's defined in `desc.h`, and we don't want to drag the full header in). Add this declaration outside the namespace, near the top of the file alongside the existing forward declarations (search for existing `class` or `struct` forward decls; if none, add `struct ModelDesc;` right before the `namespace MLXWinogradTuner {` block).

- [ ] **Step 2: Write the failing test (ungated, pure formatter only)**

In `cpp/neuralnet/mlxwinotuner.cpp`, inside `runMLXWinotunerTests`, at the very start of the function body (immediately after the opening `cout << "Running MLX Winograd tuner tests" << endl;` line), insert this new test block. The exact location: after the `cout` line at approximately line 727 and before the next `{` block.

```cpp
  {
    // Conv-3x3 distribution formatter — pure-function test. Verifies the
    // log-line format directly without any descriptor walk or GPU work.
    // Order convention (spec §3a): pairs sorted descending by invocation
    // count, ties broken by channel count descending.

    // Case A: two distinct shapes, each appearing once. Tie on count, so
    // tie-break by channel count descending: 64 before 32.
    {
      std::map<int,int> inputC  = {{32, 1}, {64, 1}};
      std::map<int,int> outputC = {{32, 1}, {64, 1}};
      std::string line = MLXWinogradTuner::formatConv3x3DistributionLine(2, inputC, outputC);
      testAssert(line.find("MLX tuner conv3x3 distribution:") != std::string::npos);
      testAssert(line.find("total=2") != std::string::npos);
      testAssert(line.find("input_c=64:1,32:1") != std::string::npos);
      testAssert(line.find("output_c=64:1,32:1") != std::string::npos);
    }

    // Case B: asymmetric counts. 384 appears 36 times, 192 once. Sort by
    // count descending, so 384 first regardless of channel-count order.
    {
      std::map<int,int> inputC  = {{384, 36}, {192, 1}};
      std::map<int,int> outputC = {{384, 37}};
      std::string line = MLXWinogradTuner::formatConv3x3DistributionLine(37, inputC, outputC);
      testAssert(line.find("total=37") != std::string::npos);
      testAssert(line.find("input_c=384:36,192:1") != std::string::npos);
      testAssert(line.find("output_c=384:37") != std::string::npos);
    }

    // Case C: empty model — no 3x3 convs. Spec §Error handling: print the
    // line with explicit "{}" markers; don't suppress.
    {
      std::map<int,int> empty;
      std::string line = MLXWinogradTuner::formatConv3x3DistributionLine(0, empty, empty);
      testAssert(line.find("total=0") != std::string::npos);
      testAssert(line.find("input_c={}") != std::string::npos);
      testAssert(line.find("output_c={}") != std::string::npos);
    }
    std::cout << "  conv3x3 distribution formatter OK" << std::endl;
  }
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
```

Expected: link/compile error on `formatConv3x3DistributionLine` (declared but not defined).

- [ ] **Step 4: Implement both formatter functions**

In `cpp/neuralnet/mlxwinotuner.cpp`, find the existing `MLXWinogradTuner::scoreOutputUntransformPerSlotForTesting` definition (added in Task 1, approximately ~30 lines after the original `scoreOutputUntransformForTesting`). Immediately after its closing `}`, insert:

```cpp
std::string MLXWinogradTuner::formatConv3x3DistributionLine(
    int total,
    const std::map<int,int>& inputChannelCounts,
    const std::map<int,int>& outputChannelCounts) {
  // Build a deterministic ordering: pairs sorted descending by invocation
  // count, ties broken by channel count descending. Truncate each histogram
  // to top-10 with a trailing ",..." guard for pathological models.
  auto serialize = [](const std::map<int,int>& counts) -> std::string {
    if(counts.empty()) return "{}";
    std::vector<std::pair<int,int>> pairs(counts.begin(), counts.end());
    std::sort(pairs.begin(), pairs.end(),
              [](const std::pair<int,int>& a, const std::pair<int,int>& b) {
                if(a.second != b.second) return a.second > b.second;
                return a.first > b.first;
              });
    constexpr size_t kMax = 10;
    bool truncated = pairs.size() > kMax;
    if(truncated) pairs.resize(kMax);

    std::string s;
    for(size_t i = 0; i < pairs.size(); i++) {
      if(i > 0) s += ",";
      s += std::to_string(pairs[i].first) + ":" + std::to_string(pairs[i].second);
    }
    if(truncated) s += ",...";
    return s;
  };

  return "MLX tuner conv3x3 distribution: total=" + std::to_string(total)
       + " input_c="  + serialize(inputChannelCounts)
       + " output_c=" + serialize(outputChannelCounts);
}

std::string MLXWinogradTuner::formatConv3x3Distribution(const ModelDesc& modelDesc) {
  std::map<int,int> inputC, outputC;
  int total = 0;
  modelDesc.iterConvLayers([&](const ConvLayerDesc& c) {
    if(c.convXSize == 3 && c.convYSize == 3) {
      total++;
      inputC[c.inChannels]++;
      outputC[c.outChannels]++;
    }
  });
  return formatConv3x3DistributionLine(total, inputC, outputC);
}
```

You'll need `desc.h` included in the .cpp for `ModelDesc` and `ConvLayerDesc` to be in scope. Check the existing `#include` block at the top of `mlxwinotuner.cpp` (currently lines 1-29). If `#include "../neuralnet/desc.h"` is not present, add it alongside the other `../core/*` and `../dataio/*` includes — for example, immediately after the existing `#include "../dataio/homedata.h"` line.

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
./katago runnnlayertests 2>&1 | grep "conv3x3 distribution"
```

Expected: `conv3x3 distribution formatter OK` prints. No `testAssert` failures.

- [ ] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp
git commit -m "Add conv-3x3 shape distribution formatter for MLX tuner

formatConv3x3DistributionLine is a pure function over pre-computed
input/output channel histograms; formatConv3x3Distribution wraps it
with a ModelDesc::iterConvLayers walk filtered to 3x3 convs.

Splitting pure formatter from descriptor walker keeps the unit tests
ungated and ModelDesc-construction-free (ConvLayerDesc is non-copyable,
so building synthetic ModelDescs would need awkward move-construction).
The descriptor walker is exercised end-to-end in the next task when it
gets wired into mlxbackend.cpp.

Ungated tests cover: standard two-shape model, asymmetric counts, and
the empty-model edge case (prints explicit input_c={} output_c={}).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Wire distribution log into model-load path

Call `MLXWinogradTuner::formatConv3x3Distribution(loadedModel.modelDesc)` once at model load, before `loadOrAutoTune`. This is the line operators will see on every load (including cache-hit runs where the tuner short-circuits).

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp` — one line addition before the existing `loadOrAutoTune` call at approximately line 1204.

- [ ] **Step 1: Add the log call in `mlxbackend.cpp`**

In `cpp/neuralnet/mlxbackend.cpp`, locate the existing block in `ComputeHandle::ComputeHandle` around lines 1189-1216 (the `if(mlxWinogradEnabled() && mlxWinotunerEnabled()) { ... }` body). Find the line at approximately 1192:

```cpp
    MLXWinogradTuneParams tuneParams;
    if(mlxWinogradEnabled() && mlxWinotunerEnabled()) {
      MLXWinogradTuner::ModelInfoForTuning mi;
```

Immediately after the opening `{` of the `if(mlxWinogradEnabled() && mlxWinotunerEnabled())` block and **before** the `MLXWinogradTuner::ModelInfoForTuning mi;` line, insert:

```cpp
      // Shape diagnostic: print the model's 3x3 conv shape distribution before
      // calling the tuner so the log carries this signal on every load, including
      // cache-hit runs where loadOrAutoTune short-circuits. Spec §3a.
      if(context->logger) {
        context->logger->write(
            MLXWinogradTuner::formatConv3x3Distribution(loadedModel.modelDesc));
      }
```

So the block reads:

```cpp
    MLXWinogradTuneParams tuneParams;
    if(mlxWinogradEnabled() && mlxWinotunerEnabled()) {
      // Shape diagnostic: print the model's 3x3 conv shape distribution before
      // calling the tuner so the log carries this signal on every load, including
      // cache-hit runs where loadOrAutoTune short-circuits. Spec §3a.
      if(context->logger) {
        context->logger->write(
            MLXWinogradTuner::formatConv3x3Distribution(loadedModel.modelDesc));
      }
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels   = loadedModel.modelDesc.trunk.trunkNumChannels;
      // ... (existing body unchanged) ...
```

- [ ] **Step 2: Build and verify the manual smoke test**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
```

Expected: clean build. The new wrapper is already implemented (Task 3) and the header already exposes it.

Now run a tiny benchmark to verify the log line appears at runtime. Choose a model that's already on disk:

```bash
ls -1 ~/.katago/*.bin.gz 2>/dev/null | head -1
```

If a model is present (e.g. `~/.katago/b18c384nbt-uec-20221121b.bin.gz`), run a 1-thread 10-visit benchmark and grep for the new log line:

```bash
./katago benchmark \
    -model ~/.katago/b18c384nbt-uec-20221121b.bin.gz \
    -config configs/gtp_example.cfg \
    -t 1 -v 10 2>&1 | grep "conv3x3 distribution"
```

Expected: one line like:

```
2026-05-21 ...: MLX tuner conv3x3 distribution: total=<N> input_c=<...> output_c=<...>
```

For b18c384nbt the `total` will be in the 30s–40s range and `input_c` / `output_c` will be dominated by a single channel count (likely 384). If no MLX cache exists yet for this model, the tuner sweep also runs — that's fine; the line should appear regardless. If a cache exists, the line still appears (verifying the cache-hit code path).

If no local model is available, document the expected log shape in the commit message and skip the runtime check.

- [ ] **Step 3: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxbackend.cpp
git commit -m "Log MLX conv-3x3 shape distribution at model load

Calls MLXWinogradTuner::formatConv3x3Distribution once before the tuner
is invoked, so the per-pass 3x3 conv shape mix prints on every model
load — including cache-hit runs where loadOrAutoTune short-circuits.

Verified manually on b18c384nbt (or per the runtime smoke described in
the plan). The line appears alongside the other tuner logs and gives
operators direct visibility into which channel counts the cached winner
was tuned to optimize for.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Per-slot numeric-consistency gated test

Add the spec's Test 2 — a gated check that the in-sweep `trunk_ms` value parsed from a captured log is within 25% of an independently-computed min-of-3-medians reference. Mirrors the existing baseline-anchor numeric test pattern.

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` — append a new gated test block in `runMLXWinotunerTests`.

- [ ] **Step 1: Write the failing test**

In `cpp/neuralnet/mlxwinotuner.cpp`, inside `runMLXWinotunerTests`, find the existing baseline-consistency gated test block (approximately lines 999-1070, ending with `std::remove(tmpTunerFile.c_str()); }`). Immediately after its closing `}`, insert this new gated block:

```cpp
  {
    // Per-slot numeric consistency — Test 2 from the shape-diagnostic spec.
    // Asserts the trunk_ms value printed by flatSweepInput matches an
    // independent min-of-three median-of-six reference within 25% relative
    // error.
    //
    // parsedTrunkMs is a single median-of-6 timing from one
    // scoreInputTransformPerSlot call (run inside loadOrAutoTune on the
    // chosen winner). referenceTrunkMs is the min of three such medians —
    // a denoised lower-bound reference (selection bias makes it ~5-10%
    // lower than a single median, on top of the ~10% per-call noise
    // floor). The 25% budget covers both effects.
    //
    // Coverage scope: input stage only. flatSweepOutput's per-slot fields
    // are format-checked by the log-format test (Task 2 / gate
    // KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST) but not consistency-
    // checked here — symmetric output check is deferred.
    //
    // Gate is new (KATAGO_MLX_WINOTUNER_RUN_PER_SLOT_TEST) and separate
    // from the baseline-anchor gate above; this test runs an additional
    // tuner sweep.
    const char* gate = std::getenv("KATAGO_MLX_WINOTUNER_RUN_PER_SLOT_TEST");
    if(gate != nullptr && std::string(gate) == "1") {
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels    = 64;
      mi.midNumChannels      = 64;
      mi.maxConvChannels3x3  = 64;
      mi.modelVersion        = 11;

      std::string tmpTunerFile = "/tmp/per_slot_consistency.txt";
      std::remove(tmpTunerFile.c_str());

      std::ostringstream captured;
      Logger logger(nullptr, /*logToStdoutDefault=*/false,
                    /*logToStderrDefault=*/false, /*logTimeDefault=*/false,
                    /*logConfigContents=*/false);
      logger.addOStream(captured);

      (void)MLXWinogradTuner::loadOrAutoTune(
          /*tunerFile=*/tmpTunerFile,
          /*homeDataDirOverride=*/"",
          /*gpuName=*/"AppleSilicon",
          /*nnXLen=*/19, /*nnYLen=*/19, /*batchSize=*/1,
          mi,
          /*logger=*/&logger,
          /*full=*/false,
          /*reTune=*/true,
          /*useFP16=*/true);

      const std::string log = captured.str();
      std::smatch m;
      std::regex trunkRe(R"(flatSweepInput:[^\n]*trunk_ms=([0-9]+\.[0-9]+))");
      testAssert(std::regex_search(log, m, trunkRe));
      const double parsedTrunkMs = std::stod(m[1].str());

      double minOf3 = std::numeric_limits<double>::infinity();
      for(int rep = 0; rep < 3; rep++) {
        std::array<double,3> t = MLXWinogradTuner::scoreInputTransformPerSlotForTesting(
            MLXWinograd::InputTransform{}, 1, 19, 19, mi, true);
        if(t[0] < minOf3) minOf3 = t[0];  // index 0 = trunk
      }

      const double relErr = std::abs(parsedTrunkMs - minOf3) / minOf3;
      testAssert(relErr < 0.25);
      std::cout << "  per-slot trunk consistency (gated) OK"
                << " parsed=" << parsedTrunkMs
                << " minOf3=" << minOf3
                << " relErr=" << relErr << std::endl;

      std::remove(tmpTunerFile.c_str());
    }
  }
```

- [ ] **Step 2: Run the test with the gate set**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
KATAGO_MLX_WINOTUNER_RUN_PER_SLOT_TEST=1 ./katago runnnlayertests 2>&1 | grep -A1 "per-slot trunk consistency"
```

Expected: `per-slot trunk consistency (gated) OK parsed=... minOf3=... relErr=...` with `relErr < 0.25`. The exact values depend on host noise; the assertion passing is what matters.

- [ ] **Step 3: Verify the ungated path is unaffected**

```bash
./katago runnnlayertests 2>&1 | tail -10
```

Expected: `MLX Winograd tuner tests passed` prints; the new gated block silently no-ops (env var unset). No `testAssert` failures.

- [ ] **Step 4: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxwinotuner.cpp
git commit -m "Add per-slot numeric-consistency gated test for MLX tuner

New gate KATAGO_MLX_WINOTUNER_RUN_PER_SLOT_TEST. Parses trunk_ms from
the captured flatSweepInput log and asserts it lies within 25% of an
independently-computed min-of-3-medians reference. Mirrors the existing
baseline-anchor consistency test pattern (commit 72364c4e).

Coverage is input-stage trunk slot only. Output-stage and other slots
are format-validated by the log-format test but not consistency-checked
here; symmetric checks are deferred.

Closes the shape-diagnostic spec.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## End-to-end validation (manual, post-merge)

After all five tasks are committed, perform one full smoke test on the production b18 model. Per `.claude/MLX_Validation.md`, this is a touch on the MLX hot path (mlxwinotuner.cpp), so a quick `runnnlayertests` is the floor; full Eigen cross-validation is unnecessary because no scoring or kernel logic changed.

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp

# Force a fresh sweep so the per-slot fields and distribution log both print.
trash ~/.katago/mlxwinotuning/tunemlxwino3_gpuAppleSilicon_x19_y19_c384_mv11_fp16.txt 2>/dev/null

# Build + run benchmark; capture full tuner log.
ninja
./katago benchmark \
    -model ~/.katago/b18c384nbt-uec-20221121b.bin.gz \
    -config configs/gtp_example.cfg \
    -t 1 -v 10 2>&1 | grep -E "MLX tuner (conv3x3|flat|flatSweep)"
```

Expected output (numbers illustrative, exact values host-dependent):

```
MLX tuner conv3x3 distribution: total=37 input_c=384:... output_c=384:...
MLX tuner flatSweepInput: considered=1600 best=... time_ms=... baseline_ms=... delta_pct=... trunk_ms=... mid_ms=... max_ms=...
MLX tuner flatSweepOutput: considered=400 best=... time_ms=... baseline_ms=... delta_pct=... trunk_ms=... mid_ms=... max_ms=...
MLX tuner flat sweep complete in ... ms
```

If all four lines appear with well-formed fields, the diagnostic is live. Capture the values for analysis; they are the inputs to the next iteration's design decision (weighting vs estimator).
