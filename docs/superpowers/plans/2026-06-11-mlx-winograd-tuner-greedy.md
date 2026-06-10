# MLX Winograd Tuner — Greedy Coordinate Descent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the MLX/GPU Winograd autotuner's exhaustive coarse grid sweep with a sensitivity-ordered greedy coordinate descent so a cache-miss / Re-tune returns fast enough that the iPad Loading screen is < 15 s, at ≤5% transform-time loss.

**Architecture:** A pure, header-only coordinate-descent core (`greedysearch.h`, no MLX deps, unit-tested via standalone `clang++`) drives the search over the existing coarse axes; `mlxwinotuner.cpp` supplies a GPU scorer callback and a baked, measurement-derived axis order. A DEBUG launch-arg harness (`MLXTuneExperimentView`) auto-runs a Re-tune headlessly and dumps timing + per-candidate scores to stderr, captured via `devicectl --console`, so all measurement is hands-free.

**Tech Stack:** C++20 (MLX backend), SwiftUI (iOS app), `xcodebuild` + `xcrun devicectl` (device build/install/launch/console), reference spec `docs/superpowers/specs/2026-06-11-mlx-winograd-tuner-greedy-design.md`.

---

## Reference facts (the implementer should not re-derive these)

- The tuner is in `cpp/neuralnet/mlxwinotuner.cpp`. The coarse sweep is `flatSweepInput` / `flatSweepOutput`; both seed best-so-far with the baked default and call `scoreInputTransform` / `scoreOutputUntransform` (median-of-7). `loadOrAutoTune` calls both, then saves.
- Coarse value sets (in `mlxwinotuner.cpp`): input `tg0{16,32,64,128}`, `tg1{1,2,4,8}`, `wpt{1,2,4}`, `vw{1,2,4}`, `gridOrder{Cfast,Tfast}`; output `tg0{16,32,64,128}`, `tg1{1,2,4,8}`, `wpt{1,2,4}`. `MLXWinograd::GridOrder::Cfast` and `::Tfast` are the enum; `InputTransform{tg0,tg1,wpt,vw,gridOrder}`, `OutputUntransform{tg0,tg1,wpt}` (defaults `{32,1,1,1,Cfast}` / `{32,1,1}`).
- Validity: `isInputCandidateValid(tg0,tg1,wpt,vw,go,C,Ntiles)` (Tfast ⇒ vw==1; Cfast ⇒ vw divides C; tg0*tg1<=1024) and `isOutputCandidateValid(tg0,tg1,wpt,outC,Ntiles)` — both are `static` in the anonymous namespace of `mlxwinotuner.cpp`.
- The cross-net memo + `[MLX-TUNE] ... total=… ms` per-stage line already exist (uncommitted) in `mlxbackend.cpp` / `mlxwinotuner.cpp`. The `full=true` path stays exhaustive throughout.
- New `.swift` files must be registered in `project.pbxproj` (no synchronized groups) — use the `xcodeproj` Ruby gem (app target `KataGo Anytime`). Header-only `.h` added under `cpp/` needs no pbxproj change (it's `#include`d, not compiled separately).
- App bundle id: `chinchangyang.KataGo-iOS.tw`. iPad devicectl id: `0092D269-B259-5B37-ADC8-D27397B902FF`.

---

## Task 1: Pure greedy coordinate-descent core + standalone unit tests

**Files:**
- Create: `cpp/neuralnet/greedysearch.h`
- Test: `cpp/neuralnet/greedysearch_test.cpp` (standalone, not in any Xcode target)

- [ ] **Step 1: Write the failing test**

Create `cpp/neuralnet/greedysearch_test.cpp`:

```cpp
// Standalone unit test for the pure greedy coordinate-descent core.
// Build & run (no Xcode needed):
//   clang++ -std=c++20 -I cpp cpp/neuralnet/greedysearch_test.cpp -o /tmp/greedysearch_test && /tmp/greedysearch_test
#include "neuralnet/greedysearch.h"
#include <cassert>
#include <cstdio>
#include <vector>
#include <cmath>

using std::vector;

static int failures = 0;
#define CHECK(cond) do { if(!(cond)) { std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); failures++; } } while(0)

int main() {
  // Axes: 3 axes of sizes 4,4,3. Separable score with a planted optimum at
  // indices (3,0,2): score = |i0-3| + |i1-0| + |i2-2|. Coordinate descent on a
  // separable convex score must reach the exact optimum (score 0).
  {
    vector<int> sizes = {4,4,3};
    vector<int> order = {0,1,2};
    vector<int> seed  = {0,0,0};
    int target0=3, target1=0, target2=2;
    auto score = [&](const vector<int>& idx)->double {
      return std::abs(idx[0]-target0) + std::abs(idx[1]-target1) + std::abs(idx[2]-target2);
    };
    GreedySearch::Result r = GreedySearch::coordinateDescent(sizes, order, seed, score, 3);
    CHECK(r.indices == (vector<int>{3,0,2}));
    CHECK(r.score == 0.0);
    CHECK(r.evaluated >= 1);
  }

  // Invalid combos (score +inf) are never selected and never crash.
  {
    vector<int> sizes = {3,3};
    vector<int> order = {0,1};
    vector<int> seed  = {0,0};
    auto score = [&](const vector<int>& idx)->double {
      if(idx[0]==2 && idx[1]==2) return std::numeric_limits<double>::infinity(); // forbidden
      return (idx[0]==2 ? 0.0 : 1.0) + (idx[1]==2 ? 0.0 : 1.0); // wants (2,2) but it's invalid
    };
    GreedySearch::Result r = GreedySearch::coordinateDescent(sizes, order, seed, score, 3);
    CHECK(!(r.indices[0]==2 && r.indices[1]==2));
    CHECK(std::isfinite(r.score));
  }

  // Deterministic: identical inputs → identical result.
  {
    vector<int> sizes = {4,3,2};
    vector<int> order = {2,0,1};
    vector<int> seed  = {1,1,0};
    auto score = [&](const vector<int>& idx)->double { return (idx[0]-2)*(idx[0]-2) + idx[1] + (1-idx[2]); };
    GreedySearch::Result a = GreedySearch::coordinateDescent(sizes, order, seed, score, 3);
    GreedySearch::Result b = GreedySearch::coordinateDescent(sizes, order, seed, score, 3);
    CHECK(a.indices == b.indices);
    CHECK(a.score == b.score);
  }

  // Constant score → no axis improves → returns the seed; evaluations bounded.
  {
    vector<int> sizes = {4,4,3};
    vector<int> order = {0,1,2};
    vector<int> seed  = {2,3,1};
    auto score = [&](const vector<int>&)->double { return 7.0; };
    GreedySearch::Result r = GreedySearch::coordinateDescent(sizes, order, seed, score, 3);
    CHECK(r.indices == seed);
    // 1 seed eval + one pass of (sizes-1) probes, then a no-change pass stops it.
    CHECK(r.evaluated <= 1 + 3*((4-1)+(4-1)+(3-1)));
  }

  if(failures==0) std::printf("ALL GREEDY TESTS PASSED\n");
  return failures==0 ? 0 : 1;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `clang++ -std=c++20 -I cpp cpp/neuralnet/greedysearch_test.cpp -o /tmp/greedysearch_test`
Expected: FAIL — `fatal error: 'neuralnet/greedysearch.h' file not found`.

- [ ] **Step 3: Write the minimal implementation**

Create `cpp/neuralnet/greedysearch.h`:

```cpp
#ifndef NEURALNET_GREEDYSEARCH_H_
#define NEURALNET_GREEDYSEARCH_H_

// Pure, header-only greedy coordinate descent over discrete axes. No MLX/Metal
// dependency, so it is unit-tested standalone. Axes are index-based: each axis
// has a fixed number of candidate value-indices [0, size); the caller maps an
// index assignment to a concrete config inside its score callback. Lower score
// is better; the callback returns +inf for an invalid assignment.

#include <cassert>
#include <functional>
#include <limits>
#include <vector>

namespace GreedySearch {

struct Result {
  std::vector<int> indices;  // best value-index per axis
  double score;              // its score
  int evaluated;             // number of scoreFn calls (instrumentation/tests)
};

// axisSizes[a]  = number of candidate values for axis a.
// order         = axis indices, highest-sensitivity first (a permutation of [0,nAxes)).
// seedIndices   = starting index per axis; MUST score finite (it is the always-valid floor).
// scoreFn(idx)  = lower is better; return +inf for invalid assignments.
// maxPasses     = pass cap; descent also stops early on a no-change pass.
inline Result coordinateDescent(
    const std::vector<int>& axisSizes,
    const std::vector<int>& order,
    const std::vector<int>& seedIndices,
    const std::function<double(const std::vector<int>&)>& scoreFn,
    int maxPasses) {
  const size_t nAxes = axisSizes.size();
  assert(seedIndices.size() == nAxes);
  assert(order.size() == nAxes);

  std::vector<int> best = seedIndices;
  double bestScore = scoreFn(best);
  int evaluated = 1;

  for(int pass = 0; pass < maxPasses; pass++) {
    bool changed = false;
    for(int axis : order) {
      const int curVal = best[axis];
      int bestVal = curVal;
      for(int v = 0; v < axisSizes[axis]; v++) {
        if(v == curVal) continue;  // current value's score is already bestScore
        std::vector<int> trial = best;
        trial[axis] = v;
        const double s = scoreFn(trial);
        evaluated++;
        if(s < bestScore) { bestScore = s; bestVal = v; }
      }
      if(bestVal != curVal) { best[axis] = bestVal; changed = true; }
    }
    if(!changed) break;
  }
  return Result{best, bestScore, evaluated};
}

}  // namespace GreedySearch

#endif  // NEURALNET_GREEDYSEARCH_H_
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `clang++ -std=c++20 -I cpp cpp/neuralnet/greedysearch_test.cpp -o /tmp/greedysearch_test && /tmp/greedysearch_test`
Expected: `ALL GREEDY TESTS PASSED`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add cpp/neuralnet/greedysearch.h cpp/neuralnet/greedysearch_test.cpp
git commit -m "feat(mlx): pure greedy coordinate-descent core + standalone tests"
```

---

## Task 2: Instrumentation — `considered=N` + compile-gated study dump

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (the `[MLX-TUNE]` line in `loadOrAutoTune`; the candidate scoring loops in `flatSweepInput`/`flatSweepOutput`)

Goal: (a) the permanent `[MLX-TUNE]` line reports candidate counts, and (b) under `-DMLX_TUNE_STUDY` each scored candidate's axis values + score are dumped to stderr (for the sensitivity study and the 5% acceptance check). `flatSweepInput`/`flatSweepOutput` already track `considered`; thread it out.

- [ ] **Step 1: Make the sweeps return their candidate count**

In `mlxwinotuner.cpp`, change `flatSweepInput` and `flatSweepOutput` to also report `considered` via an out-param. Update their signatures (both are `static`, only called from `loadOrAutoTune`):

```cpp
// add a trailing `int* consideredOut` to both signatures, e.g.:
static std::optional<MLXWinograd::InputTransform>
flatSweepInput(int N, int H, int W,
               const MLXWinogradTuner::ModelInfoForTuning& mi,
               bool useFP16, bool full, Logger* logger, int* consideredOut);
```

At the end of each function, before `return best;`, add: `if(consideredOut) *consideredOut = considered;`

- [ ] **Step 2: Emit the study dump per candidate (compile-gated)**

Inside each candidate loop in `flatSweepInput`, immediately after a successful `t = scoreInputTransform(...)` (i.e. not the `catch`), add:

```cpp
#ifdef MLX_TUNE_STUDY
      std::fprintf(stderr,
                   "[MLX-STUDY] in full=%d go=%d tg0=%d tg1=%d wpt=%d vw=%d score=%.4f\n",
                   full ? 1 : 0, (int)cand.gridOrder, cand.tg0, cand.tg1, cand.wpt, cand.vw, t);
#endif
```

And in `flatSweepOutput`, after its successful `t = scoreOutputUntransform(...)`:

```cpp
#ifdef MLX_TUNE_STUDY
      std::fprintf(stderr,
                   "[MLX-STUDY] out full=%d tg0=%d tg1=%d wpt=%d score=%.4f\n",
                   full ? 1 : 0, cand.tg0, cand.tg1, cand.wpt, t);
#endif
```

(`<cstdio>` is already included in `mlxwinotuner.cpp`.)

- [ ] **Step 3: Extend the `[MLX-TUNE]` line with candidate counts**

In `loadOrAutoTune`, declare two ints and pass them to the sweeps, then include them in the existing `[MLX-TUNE]` `fprintf`:

```cpp
  int consideredIn = 0, consideredOut = 0;
  auto t0 = std::chrono::steady_clock::now();
  auto bestIn  = flatSweepInput (batchSize, nnYLen, nnXLen, modelInfo, useFP16, full, logger, &consideredIn);
  auto tMid = std::chrono::steady_clock::now();
  auto bestOut = flatSweepOutput(batchSize, nnYLen, nnXLen, modelInfo, useFP16, full, logger, &consideredOut);
  auto t1 = std::chrono::steady_clock::now();
```

Update the existing `[MLX-TUNE]` `fprintf` format/args to append:
`" consideredIn=%d consideredOut=%d"` with `consideredIn, consideredOut`.

- [ ] **Step 4: Build to verify it compiles (macOS, default — no study flag)**

Run:
```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug 2>&1 | grep -iE "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.cpp
git commit -m "feat(mlx): tuner candidate-count line + MLX_TUNE_STUDY per-candidate dump"
```

---

## Task 3: Hands-free measurement harness `MLXTuneExperimentView`

**Files:**
- Create: `ios/KataGo iOS/KataGo iOS/MLXTuneExperimentView.swift`
- Modify: `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift` (root routing)
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (register the new file)

Goal: launching with `--mlx-tune-experiment` (DEBUG only) shows a view that, on appear, forces MLX/GPU + Re-tune for the built-in net and runs `runGtp` headlessly, so the tuner fires during init and logs to stderr — captured via `devicectl --console`, no taps.

- [ ] **Step 1: Create the harness view**

Create `ios/KataGo iOS/KataGo iOS/MLXTuneExperimentView.swift`:

```swift
//
//  MLXTuneExperimentView.swift
//  KataGo Anytime
//
//  DEBUG-only measurement harness. Activated by the launch argument
//  `--mlx-tune-experiment`. On appear it forces the built-in net onto MLX/GPU
//  with Re-tune and starts the engine headlessly, so the Winograd autotuner
//  runs during init and prints `[MLX-TUNE]` / `[MLX-STUDY]` lines to stderr
//  (captured via `devicectl process launch --console`). No user interaction.
//
#if DEBUG
import SwiftUI
import KataGoInterface

struct MLXTuneExperimentView: View {
    static let launchArg = "--mlx-tune-experiment"

    @State private var status = "starting…"
    @State private var started = false

    var body: some View {
        VStack(spacing: 12) {
            Text("MLX Tune Experiment").font(.headline)
            Text(status).font(.system(.body, design: .monospaced)).multilineTextAlignment(.center)
            ProgressView()
        }
        .padding()
        .onAppear { runOnce() }
    }

    private func runOnce() {
        guard !started else { return }
        started = true

        let model = NeuralNetworkModel.allCases.first { $0.builtIn } ?? NeuralNetworkModel.allCases[0]
        guard let modelPath = Bundle.main.path(forResource: "default_model", ofType: "bin.gz") else {
            status = "ERROR: built-in model not found"
            FileHandle.standardError.write(Data("[MLX-TUNE] ERROR: built-in model not found\n".utf8))
            return
        }

        FileHandle.standardError.write(Data("[MLX-TUNE] experiment: forcing MLX/GPU + reTune for \(model.title)\n".utf8))
        status = "tuning \(model.title) on MLX/GPU (Re-tune)…\nwatch stderr for [MLX-TUNE]/[MLX-STUDY]"

        let thread = Thread {
            // Force the GPU backend (device 0) + a fresh tune, bypassing the UI/UserDefaults.
            KataGoHelper.runGtp(modelPath: modelPath,
                                metalDeviceToUse: 0,
                                maxBoardSizeForNNBuffer: model.nnLen,
                                requireExactNNLen: false,
                                tunerFull: false,
                                reTune: true)
        }
        thread.stackSize = 4096 * 256
        thread.start()
    }
}
#endif
```

- [ ] **Step 2: Route the app root to the harness when the arg is present**

In `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`, wrap the existing root view so the harness wins under the launch arg. Find the `WindowGroup { … }` body and change its content to:

```swift
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(MLXTuneExperimentView.launchArg) {
                MLXTuneExperimentView()
            } else {
                rootContentView   // <- whatever the existing root view expression was
            }
            #else
            rootContentView       // <- same existing root view expression
            #endif
        }
```

Replace `rootContentView` with the exact view the file currently constructs inside `WindowGroup` (e.g. `ContentView()` / `GameSplitView()` / `ModelRunnerView()` — use what is actually there; do not change it otherwise).

- [ ] **Step 3: Register the new Swift file in the Xcode project**

Run (requires the `xcodeproj` gem; `gem install xcodeproj` if missing):

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = project.targets.find { |t| t.name == "KataGo Anytime" }
group = project.main_group.find_subpath("KataGo iOS", true)
path = "KataGo iOS/MLXTuneExperimentView.swift"
unless group.files.any? { |f| f.path == "MLXTuneExperimentView.swift" }
  ref = group.new_reference("MLXTuneExperimentView.swift")
  target.add_file_references([ref])
  project.save
  puts "added MLXTuneExperimentView.swift"
else
  puts "already present"
end
'
```
Expected: `added MLXTuneExperimentView.swift`.

- [ ] **Step 4: Build (iOS Simulator) to verify it compiles and links**

Run:
```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -iE "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/MLXTuneExperimentView.swift" "ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(mlx): DEBUG launch-arg harness MLXTuneExperimentView for hands-free tuner measurement"
```

---

## Task 4: MEASUREMENT CHECKPOINT — baseline + derive the sensitivity order

No code. Build a **study** build (exhaustive sweep, with the per-candidate dump), run it hands-free on the iPad, and derive the axis order.

> **RESULTS (recorded 2026-06-11, iPad mini 6 / A15, built-in b18c384, 37×37, fp16):**
> `[MLX-TUNE] sweep full=0 c=384 x37 y37 input=13791ms output=5037ms total=18828ms consideredIn=192 consideredOut=48`.
> Baseline exhaustive coarse sweep = **18.8 s for one net** (the memo already dedupes the human net) — this is the >15 s bottleneck. **Sync-bound confirmed:** 1,536 input evals / 13,791 ms ≈ **9 ms/eval** (≈13 ms/eval output) for microsecond kernels ⇒ ~100% dispatch overhead. Derived orders baked into Task 5: input `{3,1,0,2}` (joint(gridOrder,vw) ≫ tg1 > tg0 > wpt), output `{0,1,2}` (tg0 > tg1 > wpt). Hand-tracing greedy on the dump: input winner ≈1.302 vs global min ≈1.299 (**0.3%**), output ≈0.93 vs min 0.92 (**~1%**) — the 5% gate should pass with room.

- [ ] **Step 1: Build for device with the study flag**

Run (injects `-DMLX_TUNE_STUDY` into the C++ compile):
```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'generic/platform=iOS' -configuration Debug OTHER_CPLUSPLUSFLAGS='$(inherited) -DMLX_TUNE_STUDY' 2>&1 | grep -iE "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
```
Expected: `** BUILD SUCCEEDED **`. Note the `.app` path printed under `Debug-iphoneos/`.

- [ ] **Step 2: Install and launch the harness with console capture**

```bash
APP="ios/KataGo iOS/DerivedData/KataGo Anytime/Build/Products/Debug-iphoneos/KataGo Anytime.app"
xcrun devicectl device install app --device 0092D269-B259-5B37-ADC8-D27397B902FF "$APP"
xcrun devicectl device process launch --terminate-existing --console \
  --device 0092D269-B259-5B37-ADC8-D27397B902FF \
  chinchangyang.KataGo-iOS.tw --mlx-tune-experiment 2>&1 | tee /tmp/mlx-study-baseline.log
```
(Device must be unlocked. Let it run until `[MLX-TUNE] sweep … total=… ms` appears, then Ctrl-C.)

- [ ] **Step 3: Confirm the diagnosis and derive the order**

```bash
grep -E "\[MLX-TUNE\]|\[MLX-STUDY\]" /tmp/mlx-study-baseline.log | head -80
```
Expected: a `[MLX-TUNE] sweep … input=…ms output=…ms total=…ms consideredIn=… consideredOut=…` line (confirms the tuner's share of the >15 s), plus `[MLX-STUDY] in …` / `[MLX-STUDY] out …` lines for every candidate.

Derive sensitivity from the dump (one-factor-at-a-time from the default `tg0=32,tg1=1,wpt=1,vw=1,go=Cfast`): for each axis, take the range of `score` across that axis's values while the others equal the default, and rank axes by range, descending. Record the resulting order for **input** (over `{go,tg0,tg1,wpt,vw}`) and **output** (over `{tg0,tg1,wpt}`). These rankings are the constants baked in Task 5.

- [ ] **Step 4: Record the derived order in the plan**

Edit this file: under Task 5, replace the `HYPOTHESIS` order constants with the measured ones, and note the baseline `total=… ms` for before/after comparison. Commit the note:
```bash
git add docs/superpowers/plans/2026-06-11-mlx-winograd-tuner-greedy.md
git commit -m "docs(mlx): record measured tuner baseline + sensitivity order"
```

---

## Task 5: Wire greedy into the coarse path via a `useGreedy` parameter

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (include `greedysearch.h`; add `bool useGreedy` to `flatSweepInput`/`flatSweepOutput`; greedy branch ASSIGNS to the existing `best`/`considered`; `loadOrAutoTune` passes `useGreedy = !full`)

**Design note — two orthogonal knobs.** `full` selects the *value-set breadth* (coarse vs wide); a new `useGreedy` selects the *search strategy* (greedy vs exhaustive). Production coarse = `full=false, useGreedy=true`; operator wide = `full=true, useGreedy=false`; the Task 6 acceptance reference = `full=false, useGreedy=false` (coarse exhaustive). The greedy branch **assigns** the function's existing `best`/`bestTime`/`considered` and falls through to the existing logger + `return` — it does NOT re-declare them or return early.

- [ ] **Step 1: Include + add `useGreedy` to `flatSweepInput` and branch its loop**

At the top of `mlxwinotuner.cpp` add `#include "../neuralnet/greedysearch.h"`.

Change the `flatSweepInput` signature to insert `bool useGreedy` after `full` (it already gained `int* consideredOut` in Task 2):

```cpp
static std::optional<MLXWinograd::InputTransform>
flatSweepInput(int N, int H, int W,
               const MLXWinogradTuner::ModelInfoForTuning& mi,
               bool useFP16, bool full, bool useGreedy, Logger* logger, int* consideredOut);
```

Wrap the existing exhaustive `for(GO go : {GO::Cfast, GO::Tfast}) { … }` loop in `if(useGreedy) { …greedy… } else { …the existing loop, unchanged… }`. The greedy branch reuses the existing coarse value functions (DRY) and **assigns** `best`/`bestTime`/`considered`:

```cpp
  if(useGreedy) {
    // Sensitivity-ordered greedy coordinate descent over the coarse axes.
    // Axis 0: tg0, 1: tg1, 2: wpt, 3: (gridOrder,vw) joint — encoding the joint
    // axis makes the Tfast->vw=1 coupling a matter of enumeration, not rejection.
    const std::vector<int>& tg0v = inputTg0Values(false);
    const std::vector<int>& tg1v = inputTg1Values(false);
    const std::vector<int>& wptv = wptValues(false);
    const std::vector<int>& vwv  = vwValues();
    struct GoVw { MLXWinograd::GridOrder go; int vw; };
    std::vector<GoVw> goVw;
    for(int vw : vwv) goVw.push_back({MLXWinograd::GridOrder::Cfast, vw});
    goVw.push_back({MLXWinograd::GridOrder::Tfast, 1});

    const std::vector<int> axisSizes = {(int)tg0v.size(), (int)tg1v.size(), (int)wptv.size(), (int)goVw.size()};
    // Sensitivity order — MEASURED on A15 (Task 4): the joint (gridOrder,vw) axis
    // dominates (Cfast/vw1≈1.37 vs Tfast≈9.9, vw4≈3.75), then tg1>tg0>wpt (all
    // ~1-4%, the broad plateau). axis order: joint(3), tg1(1), tg0(0), wpt(2).
    const std::vector<int> order = {3, 1, 0, 2};
    // Seed = baked default {tg0=32,tg1=1,wpt=1,(Cfast,1)} as indices, given the
    // coarse sets {16,32,64,128}/{1,2,4,8}/{1,2,4}/goVw[0]=(Cfast,1).
    const std::vector<int> seed = {1, 0, 0, 0};

    auto decode = [&](const std::vector<int>& idx) {
      return MLXWinograd::InputTransform{ tg0v[idx[0]], tg1v[idx[1]], wptv[idx[2]],
                                          goVw[idx[3]].vw, goVw[idx[3]].go };
    };
    auto scoreFn = [&](const std::vector<int>& idx) -> double {
      MLXWinograd::InputTransform cand = decode(idx);
      if(!isInputCandidateValid(cand.tg0, cand.tg1, cand.wpt, cand.vw, cand.gridOrder, C, Ntiles))
        return std::numeric_limits<double>::infinity();
      double t;
      try { t = scoreInputTransform(cand, N, H, W, mi, useFP16, full); }
      catch(const std::exception&) { return std::numeric_limits<double>::infinity(); }
#ifdef MLX_TUNE_STUDY
      std::fprintf(stderr, "[MLX-STUDY] in full=%d go=%d tg0=%d tg1=%d wpt=%d vw=%d score=%.4f\n",
                   full ? 1 : 0, (int)cand.gridOrder, cand.tg0, cand.tg1, cand.wpt, cand.vw, t);
#endif
      return t;
    };

    GreedySearch::Result gr = GreedySearch::coordinateDescent(axisSizes, order, seed, scoreFn, /*maxPasses=*/3);
    best = decode(gr.indices);   // assign the EXISTING `best` (do not re-declare)
    bestTime = gr.score;         // keep the existing logger's delta meaningful
    considered = gr.evaluated;   // assign the EXISTING `considered`
  } else {
    for(GO go : {GO::Cfast, GO::Tfast}) {
      // ...the existing exhaustive loop body, unchanged...
    }
  }
```

The existing post-loop logger block and the Task 2 tail (`if(consideredOut) *consideredOut = considered; return best;`) run for both branches. `C`, `Ntiles`, `N`, `H`, `W`, `mi`, `useFP16`, `best`, `bestTime`, `considered` are all already declared above the loop in `flatSweepInput`.

- [ ] **Step 2: Add `useGreedy` to `flatSweepOutput` and branch its loop**

Change the `flatSweepOutput` signature the same way (insert `bool useGreedy` after `full`), wrap its existing `for(auto cand : cands) { … }` loop in `if(useGreedy){…}else{…the existing loop…}`, and assign the existing `best`/`bestTime`/`considered`:

```cpp
  if(useGreedy) {
    const std::vector<int>& tg0v = outputTg0Values(false);
    const std::vector<int>& tg1v = outputTg1Values(false);
    const std::vector<int>& wptv = wptValues(false);
    const std::vector<int> axisSizes = {(int)tg0v.size(), (int)tg1v.size(), (int)wptv.size()};
    // Sensitivity order — MEASURED on A15 (Task 4): tg0(6%) > tg1(2%) > wpt(1.8%),
    // all on a narrow plateau. axis order: tg0(0), tg1(1), wpt(2).
    const std::vector<int> order = {0, 1, 2};
    const std::vector<int> seed  = {1, 0, 0};  // {tg0=32,tg1=1,wpt=1}

    auto scoreFn = [&](const std::vector<int>& idx) -> double {
      MLXWinograd::OutputUntransform cand{ tg0v[idx[0]], tg1v[idx[1]], wptv[idx[2]] };
      if(!isOutputCandidateValid(cand.tg0, cand.tg1, cand.wpt, outC, Ntiles))
        return std::numeric_limits<double>::infinity();
      double t;
      try { t = scoreOutputUntransform(cand, N, H, W, mi, useFP16, full); }
      catch(const std::exception&) { return std::numeric_limits<double>::infinity(); }
#ifdef MLX_TUNE_STUDY
      std::fprintf(stderr, "[MLX-STUDY] out full=%d tg0=%d tg1=%d wpt=%d score=%.4f\n",
                   full ? 1 : 0, cand.tg0, cand.tg1, cand.wpt, t);
#endif
      return t;
    };

    GreedySearch::Result gr = GreedySearch::coordinateDescent(axisSizes, order, seed, scoreFn, /*maxPasses=*/3);
    best = MLXWinograd::OutputUntransform{ tg0v[gr.indices[0]], tg1v[gr.indices[1]], wptv[gr.indices[2]] };
    bestTime = gr.score;
    considered = gr.evaluated;
  } else {
    for(auto cand : cands) {
      // ...the existing exhaustive loop body, unchanged...
    }
  }
```

Note: keep the existing `auto cands = MLXWinogradTuner::buildOutputCandidatesForTesting(full, outC, Ntiles);` line — the `else` branch still uses `cands`. The greedy branch ignores it.

- [ ] **Step 3: Pass `useGreedy = !full` from `loadOrAutoTune`**

In `loadOrAutoTune`, update the two normal sweep calls to thread the new arg (coarse ⇒ greedy, wide ⇒ exhaustive):

```cpp
  auto bestIn  = flatSweepInput (batchSize, nnYLen, nnXLen, modelInfo, useFP16, full, /*useGreedy=*/!full, logger, &consideredIn);
  auto tMid = std::chrono::steady_clock::now();
  auto bestOut = flatSweepOutput(batchSize, nnYLen, nnXLen, modelInfo, useFP16, full, /*useGreedy=*/!full, logger, &consideredOut);
```

- [ ] **Step 4: Build (macOS, no study flag) to verify it compiles**

Run:
```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug 2>&1 | grep -iE "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Re-run the greedy core unit tests (still green)**

Run: `clang++ -std=c++20 -I cpp cpp/neuralnet/greedysearch_test.cpp -o /tmp/greedysearch_test && /tmp/greedysearch_test`
Expected: `ALL GREEDY TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.cpp
git commit -m "feat(mlx): greedy coordinate-descent on the coarse tuner path via useGreedy (full stays exhaustive)"
```

---

## Task 6: Acceptance — greedy winner within 5% of the coarse-exhaustive winner

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (compile-gated `MLX_TUNE_STUDY` acceptance block in `loadOrAutoTune`)

Under the study flag, after the normal greedy coarse sweep produces `result`, ALSO run the **coarse exhaustive** search (`full=false, useGreedy=false`) — the same value sets, exhaustively — and compare winners. This isolates "greedy vs coarse-exhaustive" from the separate "coarse vs wide" question (the coarse breadth is already accepted). Dev-only.

- [ ] **Step 1: Add the acceptance block**

In `loadOrAutoTune`, immediately after `result` is assembled and validated (before `save`), add:

```cpp
#ifdef MLX_TUNE_STUDY
  if(!full) {
    // Coarse EXHAUSTIVE reference (same coarse value sets as greedy, but full
    // search) — apples-to-apples with the greedy winner. Dev-only.
    int exIn = 0, exOut = 0;
    auto exBestIn  = flatSweepInput (batchSize, nnYLen, nnXLen, modelInfo, useFP16, /*full=*/false, /*useGreedy=*/false, nullptr, &exIn);
    auto exBestOut = flatSweepOutput(batchSize, nnYLen, nnXLen, modelInfo, useFP16, /*full=*/false, /*useGreedy=*/false, nullptr, &exOut);
    double greedyInMs  = scoreInputTransformForTesting (result.inputTransform,    batchSize, nnYLen, nnXLen, modelInfo, useFP16);
    double greedyOutMs = scoreOutputUntransformForTesting(result.outputUntransform, batchSize, nnYLen, nnXLen, modelInfo, useFP16);
    double exInMs  = exBestIn  ? scoreInputTransformForTesting (*exBestIn,  batchSize, nnYLen, nnXLen, modelInfo, useFP16) : 0.0;
    double exOutMs = exBestOut ? scoreOutputUntransformForTesting(*exBestOut, batchSize, nnYLen, nnXLen, modelInfo, useFP16) : 0.0;
    double gT = greedyInMs + greedyOutMs, eT = exInMs + exOutMs;
    double deltaPct = (eT > 1e-9) ? (gT - eT) / eT * 100.0 : 0.0;
    std::fprintf(stderr,
      "[MLX-ACCEPT] greedy_ms=%.4f coarse_exhaustive_ms=%.4f delta_pct=%+.1f within5=%d\n",
      gT, eT, deltaPct, (deltaPct <= 5.0) ? 1 : 0);
  }
#endif
```

(`scoreInputTransformForTesting`/`scoreOutputUntransformForTesting` are the public scorers in `mlxwinotuner.h`; with the default `full=true` they still measure the same shape/precision, so the two winners' numbers are directly comparable.)

- [ ] **Step 2: Build for device with the study flag**

Run:
```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'generic/platform=iOS' -configuration Debug OTHER_CPLUSPLUSFLAGS='$(inherited) -DMLX_TUNE_STUDY' 2>&1 | grep -iE "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.cpp
git commit -m "test(mlx): MLX_TUNE_STUDY acceptance — greedy vs coarse-exhaustive within 5%"
```

---

## Task 7: MEASUREMENT CHECKPOINT — validate speed + quality on the iPad

No code. Run the study build on the iPad and confirm the three success conditions.

> **RESULTS (recorded 2026-06-11, iPad mini 6 / A15):**
> - Study build (greedy + acceptance):
>   `[MLX-TUNE] sweep ... input=1532ms output=2725ms total=4256ms consideredIn=34 consideredOut=25`
>   `[MLX-ACCEPT] greedy_ms=2.2714 coarse_exhaustive_ms=2.2657 delta_pct=+0.3 within5=1`
> - Normal build (production, gated study OFF):
>   `[MLX-TUNE] sweep ... input=1593ms output=1917ms total=3510ms consideredIn=34 consideredOut=17`; **0** `[MLX-STUDY]`/`[MLX-ACCEPT]` lines (gating confirmed).
>
> **Verdict:** tuner **18.8 s → 3.5 s** production (≈5.4×; vs ~37 s for the original two-net exhaustive), `consideredIn` 192→34 / `consideredOut` 48→17, and greedy is **+0.3%** vs the coarse-exhaustive optimum (`within5=1`) — minimal performance loss. The auto-tuner (the dominant slice of the >15 s Loading screen) is now ~3.5 s, so the whole Loading screen is comfortably under 15 s.

- [ ] **Step 1: Install + launch the harness (study build from Task 6)**

```bash
APP="ios/KataGo iOS/DerivedData/KataGo Anytime/Build/Products/Debug-iphoneos/KataGo Anytime.app"
xcrun devicectl device install app --device 0092D269-B259-5B37-ADC8-D27397B902FF "$APP"
xcrun devicectl device process launch --terminate-existing --console \
  --device 0092D269-B259-5B37-ADC8-D27397B902FF \
  chinchangyang.KataGo-iOS.tw --mlx-tune-experiment 2>&1 | tee /tmp/mlx-study-greedy.log
```
(Unlock the device first. Ctrl-C after the `[MLX-ACCEPT]` line appears.)

- [ ] **Step 2: Check the three conditions**

```bash
grep -E "\[MLX-TUNE\]|\[MLX-ACCEPT\]" /tmp/mlx-study-greedy.log
```
Expected:
- `[MLX-TUNE] … consideredIn≈12–23 consideredOut≈9–17 …` (greedy shrank the search vs ~240/~72),
- the greedy `total=… ms` is a large drop from Task 4's baseline,
- `[MLX-ACCEPT] … within5=1`.

If `within5=0`: the greedy winner is off-plateau on this chip. Remediation (in order): (a) confirm the Task 5 axis `order` matches Task 4's measured ranking; (b) raise `maxPasses` to 4; (c) if still failing, fall back to Approach B (batched reps) from the spec for the offending stage. Re-run this checkpoint.

- [ ] **Step 3: Confirm the Loading screen budget (normal build)**

Build a **non-study** device build (drop `OTHER_CPLUSPLUSFLAGS`), install, and launch WITHOUT the experiment arg; trigger a Re-tune through the UI (or relaunch the harness for the tuner time) and confirm the Loading screen is < 15 s and the `[MLX-TUNE] total` is well under it. Record the number in the plan.

- [ ] **Step 4: Commit the recorded results**

```bash
git add docs/superpowers/plans/2026-06-11-mlx-winograd-tuner-greedy.md
git commit -m "docs(mlx): record greedy tuner results (speed + within5 + loading<15s)"
```

---

## Task 8: Finalize instrumentation & clean up

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (keep `[MLX-TUNE]`, keep `[MLX-STUDY]`/`[MLX-ACCEPT]` behind `MLX_TUNE_STUDY`)
- Keep: `cpp/neuralnet/greedysearch_test.cpp` (standalone TDD asset)

- [ ] **Step 1: Confirm gating**

Verify (by reading) that `[MLX-STUDY]` and `[MLX-ACCEPT]` are entirely inside `#ifdef MLX_TUNE_STUDY` (absent from normal builds), and the single `[MLX-TUNE]` summary line is unconditional (permanent, low-noise). No change if already so.

- [ ] **Step 2: Full three-platform build sanity (normal, no study flag)**

Run macOS + iOS Simulator builds (visionOS sim runtime may be absent — skip if so):
```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug 2>&1 | grep -iE "error:|BUILD (SUCCEEDED|FAILED)" | tail -3
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -iE "error:|BUILD (SUCCEEDED|FAILED)" | tail -3
```
Expected: both `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Re-run the greedy core unit tests**

Run: `clang++ -std=c++20 -I cpp cpp/neuralnet/greedysearch_test.cpp -o /tmp/greedysearch_test && /tmp/greedysearch_test`
Expected: `ALL GREEDY TESTS PASSED`.

- [ ] **Step 4: Final commit**

```bash
git add -A cpp/neuralnet/mlxwinotuner.cpp
git commit -m "chore(mlx): finalize greedy tuner instrumentation gating" || echo "nothing to finalize"
```

---

## Done criteria

- Greedy core unit tests pass standalone.
- Normal macOS + iOS-sim Debug builds green; `full=true` path unchanged.
- On the iPad: greedy `consideredIn≈12–23` (vs ~240), tuner `total` a large drop vs baseline, `[MLX-ACCEPT] within5=1`, and the **Loading screen < 15 s**.
- `[MLX-STUDY]`/`[MLX-ACCEPT]` gated behind `MLX_TUNE_STUDY`; `[MLX-TUNE]` permanent.
