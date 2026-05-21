# MLX Winograd Tuner — Baked-Default Baseline Anchor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-stage baseline measurement to the MLX Winograd flat-sweep log so each sweep prints `baseline_ms` and `delta_pct` alongside the picked winner, giving operators visibility into noise-induced regressions in the on-disk tuner cache.

**Architecture:** Score the SP1 baked default (`MLXWinograd::InputTransform{}` / `OutputUntransform{}` — default-constructed structs already encode the SP1 values) once before each stage's candidate loop using the same `scoreInput/OutputTransform` function the sweep uses. Append `baseline_ms` and `delta_pct` to the stage's existing log line. Always adopt the sweep winner unconditionally; no contract change, no cache-format change. Two gated tests verify the log line shape and that the printed baseline reflects an actual re-score.

**Tech Stack:** C++17, MLX 0.18+ (`mx::fast::metal_kernel`), Metal backend, KataGo's `Logger` + `Global::strprintf`, `<regex>` for log-format verification, existing `runMLXWinotunerTests` harness gated by `KATAGO_MLX_WINOTUNER_RUN_*_TEST` env vars.

**Reference spec:** `docs/superpowers/specs/2026-05-21-mlx-tuner-baseline-anchor-design.md`

---

## File Structure

Single file modified, no new files:

- **Modify** `cpp/neuralnet/mlxwinotuner.cpp` —
  - lines 1-28 (top-of-file includes): add `<regex>` for the new test
  - lines 525-563 (`flatSweepInput`): add baseline measurement + augment log line
  - lines 568-597 (`flatSweepOutput`): symmetric
  - lines ~906 (tail of `runMLXWinotunerTests`): add Test 1 (log-format, gated) and Test 2 (baseline-consistency, gated)

No header changes (`mlxwinotuner.h`, `mlxwinograd.h` unchanged). No CMake changes. No on-disk cache format changes.

---

## Task 1: `flatSweepInput` baseline anchor (test + implementation)

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:1-28` (add `<regex>` include)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:525-563` (`flatSweepInput` body)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:~906` (append Test 1 block to `runMLXWinotunerTests`)

- [ ] **Step 1: Add the `<regex>` include**

Edit `cpp/neuralnet/mlxwinotuner.cpp:1-28`. Add `#include <regex>` immediately after the existing `#include <random>` at line 27, so the includes block becomes:

```cpp
#include "mlx/mlx.h"
#include "mlx/fast.h"
#include <chrono>
#include <random>
#include <regex>
```

- [ ] **Step 2: Add the failing gated log-format test (input stage only)**

Append this block to `runMLXWinotunerTests` immediately before the closing `cout << "MLX Winograd tuner tests passed" << endl;` line (currently around line 908). Indent to match the surrounding test blocks.

```cpp
  {
    // Baseline anchor — Test 1: log-format gated check (input stage).
    // Asserts that flatSweepInput's log line carries the new baseline_ms and
    // delta_pct fields with the documented format. Gated because the synthetic
    // sweep takes a few seconds; opt in with the env var below.
    const char* gate = std::getenv("KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST");
    if(gate != nullptr && std::string(gate) == "1") {
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels    = 64;
      mi.midNumChannels      = 64;
      mi.maxConvChannels3x3  = 64;
      mi.modelVersion        = 11;

      std::string tmpTunerFile = "/tmp/baseline_anchor_log_format.txt";
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
      std::regex inputRe(
          R"(MLX tuner flatSweepInput: considered=[0-9]+ best=tg0=[0-9]+ tg1=[0-9]+ wpt=[0-9]+ vw=[0-9]+ gridOrder=[01] time_ms=[0-9]+\.[0-9]+ baseline_ms=[0-9]+\.[0-9]+ delta_pct=[-+]?[0-9]+\.[0-9]+)");
      testAssert(std::regex_search(log, inputRe));
      std::cout << "  flatSweepInput log-format (gated) OK" << std::endl;

      std::remove(tmpTunerFile.c_str());
    }
  }
```

- [ ] **Step 3: Build with MLX backend**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
cmake -G Ninja -DUSE_BACKEND=MLX
ninja
```
Expected: build succeeds. If the existing CMake cache is for a different backend, delete `cpp/CMakeCache.txt` first per the project memory on toolchain-probe cleanliness.

- [ ] **Step 4: Run the gated test to verify it FAILS**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST=1 ./katago runnnlayertests 2>&1 | tail -40
```

Expected: process aborts with `Assertion failed:` referencing the line containing `testAssert(std::regex_search(log, inputRe));`. The regex does not match because `flatSweepInput`'s current log line ends with `time_ms=…` — no `baseline_ms` or `delta_pct` fields yet.

- [ ] **Step 5: Implement baseline measurement + log augmentation in `flatSweepInput`**

Replace the body of `flatSweepInput` at `cpp/neuralnet/mlxwinotuner.cpp:525-563` with:

```cpp
static std::optional<MLXWinograd::InputTransform>
flatSweepInput(int N, int H, int W,
               const MLXWinogradTuner::ModelInfoForTuning& mi,
               bool useFP16, bool full, Logger* logger) {
  using GO = MLXWinograd::GridOrder;
  const int C  = mi.maxConvChannels3x3;
  const int tilesY = (H + 1) / 2;
  const int tilesX = (W + 1) / 2;
  const int Ntiles = N * tilesY * tilesX;

  // Score the SP1 baked default (default-constructed = {tg0=32, tg1=1, wpt=1,
  // vw=1, gridOrder=Cfast}) so the sweep log carries a baseline the operator
  // can compare the winner against. Always adopted-winner; no fallback.
  const double baselineMs =
      scoreInputTransform(MLXWinograd::InputTransform{}, N, H, W, mi, useFP16);

  std::optional<MLXWinograd::InputTransform> best;
  double bestTime = std::numeric_limits<double>::infinity();
  int considered = 0;

  // SP5 Task 4: the output gridOrder check in isValid() is gone (output kernel
  // is Cfast-monomorphic), so the input gridOrder axis can again be searched
  // over both Cfast and Tfast. SP5 Task 6: the global gridOrder field is also
  // gone — input gridOrder stands alone, no cross-stage consistency to enforce.
  for(GO go : {GO::Cfast, GO::Tfast}) {
    auto cands = MLXWinogradTuner::buildInputCandidatesForTesting(full, C, Ntiles, go);
    for(const auto& cand : cands) {
      considered++;
      double t = scoreInputTransform(cand, N, H, W, mi, useFP16);
      if(t < bestTime) { bestTime = t; best = cand; }
    }
  }
  if(logger) {
    std::string deltaStr;
    if(best && baselineMs >= 1e-9) {
      double deltaPct = (bestTime - baselineMs) / baselineMs * 100.0;
      deltaStr = Global::strprintf("%+.1f", deltaPct);
    } else {
      deltaStr = "nan";
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
                  + " delta_pct=" + deltaStr);
  }
  return best;
}
```

- [ ] **Step 6: Rebuild**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
```
Expected: build succeeds.

- [ ] **Step 7: Run the gated test to verify it PASSES**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST=1 ./katago runnnlayertests 2>&1 | tail -40
```

Expected: tail contains `  flatSweepInput log-format (gated) OK` and the run ends with `MLX Winograd tuner tests passed`. Process exit code 0.

- [ ] **Step 8: Run the full layer tests once without the gate to confirm no regression**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago runnnlayertests 2>&1 | tail -20
```

Expected: completes with all existing tests passing and `MLX Winograd tuner tests passed`. The new gated block is skipped (no env var). No new output.

- [ ] **Step 9: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxwinotuner.cpp
git -c user.email=chin.chang.yang@gmail.com commit -m "MLX tuner: baseline_ms / delta_pct in flatSweepInput log line

Score the SP1 baked default (default-constructed InputTransform) once
per sweep so the existing flatSweepInput log line carries baseline_ms
and a signed delta_pct alongside the winner's time_ms. Winner is always
adopted; this is purely operator visibility for noise-induced
regressions in the cache. Gated regex unit test added behind
KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `flatSweepOutput` baseline anchor (test + implementation)

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:~930` (extend the Test 1 block from Task 1 with an output-stage regex)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:568-597` (`flatSweepOutput` body)

- [ ] **Step 1: Extend the gated log-format test to also check the output stage**

Locate the Test 1 block added in Task 1. Find the two lines:

```cpp
      testAssert(std::regex_search(log, inputRe));
      std::cout << "  flatSweepInput log-format (gated) OK" << std::endl;
```

Insert immediately after them (before the `std::remove(tmpTunerFile.c_str());` line):

```cpp
      std::regex outputRe(
          R"(MLX tuner flatSweepOutput: considered=[0-9]+ best=tg0=[0-9]+ tg1=[0-9]+ wpt=[0-9]+ time_ms=[0-9]+\.[0-9]+ baseline_ms=[0-9]+\.[0-9]+ delta_pct=[-+]?[0-9]+\.[0-9]+)");
      testAssert(std::regex_search(log, outputRe));
      std::cout << "  flatSweepOutput log-format (gated) OK" << std::endl;
```

- [ ] **Step 2: Rebuild**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
```
Expected: build succeeds.

- [ ] **Step 3: Run the gated test to verify it FAILS on the output regex**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST=1 ./katago runnnlayertests 2>&1 | tail -40
```

Expected: tail contains `  flatSweepInput log-format (gated) OK` (from Task 1) followed by `Assertion failed:` referencing the `testAssert(std::regex_search(log, outputRe));` line. The regex does not match because `flatSweepOutput`'s log line still ends with `time_ms=…` — no `baseline_ms` / `delta_pct`.

- [ ] **Step 4: Implement baseline measurement + log augmentation in `flatSweepOutput`**

Replace the body of `flatSweepOutput` at `cpp/neuralnet/mlxwinotuner.cpp:568-597` with:

```cpp
static std::optional<MLXWinograd::OutputUntransform>
flatSweepOutput(int N, int H, int W,
                const MLXWinogradTuner::ModelInfoForTuning& mi,
                bool useFP16, bool full, Logger* logger) {
  const int outC = mi.midNumChannels;  // output untransform reads from matmul output
  const int Ntiles = N * ((H + 1) / 2) * ((W + 1) / 2);

  // Score the SP1 baked default (default-constructed = {tg0=32, tg1=1, wpt=1})
  // so the sweep log carries a baseline the operator can compare the winner
  // against. Symmetric to flatSweepInput.
  const double baselineMs =
      scoreOutputUntransform(MLXWinograd::OutputUntransform{}, N, H, W, mi, useFP16);

  std::optional<MLXWinograd::OutputUntransform> best;
  double bestTime = std::numeric_limits<double>::infinity();
  int considered = 0;

  // Output kernel is VW=1 monomorphic (SP5 Task 3) and Cfast monomorphic
  // (SP5 Task 4), so neither VW nor gridOrder is searched here.
  auto cands = MLXWinogradTuner::buildOutputCandidatesForTesting(full, outC, Ntiles);
  for(auto cand : cands) {
    considered++;
    double t = scoreOutputUntransform(cand, N, H, W, mi, useFP16);
    if(t < bestTime) { bestTime = t; best = cand; }
  }
  if(logger) {
    std::string deltaStr;
    if(best && baselineMs >= 1e-9) {
      double deltaPct = (bestTime - baselineMs) / baselineMs * 100.0;
      deltaStr = Global::strprintf("%+.1f", deltaPct);
    } else {
      deltaStr = "nan";
    }
    logger->write("MLX tuner flatSweepOutput: considered=" + std::to_string(considered)
                  + (best
                     ? " best=tg0=" + std::to_string(best->tg0)
                       + " tg1=" + std::to_string(best->tg1)
                       + " wpt=" + std::to_string(best->wpt)
                       + " time_ms=" + Global::strprintf("%.3f", bestTime)
                     : " best=none")
                  + " baseline_ms=" + Global::strprintf("%.3f", baselineMs)
                  + " delta_pct=" + deltaStr);
  }
  return best;
}
```

- [ ] **Step 5: Rebuild**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
```
Expected: build succeeds.

- [ ] **Step 6: Run the gated test to verify it PASSES**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST=1 ./katago runnnlayertests 2>&1 | tail -40
```

Expected: tail contains both `  flatSweepInput log-format (gated) OK` and `  flatSweepOutput log-format (gated) OK`. The run ends with `MLX Winograd tuner tests passed`. Process exit code 0.

- [ ] **Step 7: Confirm no regression in the ungated run**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago runnnlayertests 2>&1 | tail -20
```

Expected: completes with all existing tests passing and `MLX Winograd tuner tests passed`. Exit code 0.

- [ ] **Step 8: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxwinotuner.cpp
git -c user.email=chin.chang.yang@gmail.com commit -m "MLX tuner: baseline_ms / delta_pct in flatSweepOutput log line

Symmetric to the flatSweepInput change. Score the SP1 baked default
(default-constructed OutputUntransform) once per sweep and emit the
same baseline_ms / delta_pct fields. Gated regex test extended.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Gated baseline-consistency check (Test 2)

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:~906` (append a new gated block to `runMLXWinotunerTests` reusing `KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST`)

This task verifies that the `baseline_ms` value printed in the log reflects an actual `scoreInputTransform` of the default-constructed `InputTransform{}` — guarding against e.g. an off-by-one in the format string, a stale cached value, or a `%.3f` decimal-precision parse mismatch. Independent of Test 1 (which only checks format shape).

- [ ] **Step 1: Add the failing gated baseline-consistency test**

Append this block to `runMLXWinotunerTests` immediately before the closing `cout << "MLX Winograd tuner tests passed" << endl;` line (after both Task 1's and the existing SP5 Task 10 gated blocks).

```cpp
  {
    // Baseline anchor — Test 2: baseline-consistency gated check.
    // Asserts that the baseline_ms value printed by flatSweepInput
    // matches an independent re-score of the default-constructed
    // InputTransform within a 25% noise budget (~2.5x the empirical
    // ~10% per-sample noise floor). Shares the SP5 Task 10 gate.
    const char* gate = std::getenv("KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST");
    if(gate != nullptr && std::string(gate) == "1") {
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels    = 64;
      mi.midNumChannels      = 64;
      mi.maxConvChannels3x3  = 64;
      mi.modelVersion        = 11;

      std::string tmpTunerFile = "/tmp/baseline_anchor_consistency.txt";
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
      std::regex baselineRe(R"(flatSweepInput:[^\n]*baseline_ms=([0-9]+\.[0-9]+))");
      testAssert(std::regex_search(log, m, baselineRe));
      const double parsedBaseline = std::stod(m[1].str());

      double minOf3 = std::numeric_limits<double>::infinity();
      for(int rep = 0; rep < 3; rep++) {
        double t = MLXWinogradTuner::scoreInputTransformForTesting(
            MLXWinograd::InputTransform{}, 1, 19, 19, mi, true);
        if(t < minOf3) minOf3 = t;
      }

      const double relErr = std::abs(parsedBaseline - minOf3) / minOf3;
      testAssert(relErr < 0.25);
      std::cout << "  baseline-consistency (gated) OK"
                << " parsed=" << parsedBaseline
                << " minOf3=" << minOf3
                << " relErr=" << relErr << std::endl;

      std::remove(tmpTunerFile.c_str());
    }
  }
```

- [ ] **Step 2: Rebuild**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
```
Expected: build succeeds.

- [ ] **Step 3: Run the gated test to verify it PASSES**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST=1 ./katago runnnlayertests 2>&1 | tail -40
```

Expected: tail contains `  SP5 flat-sweep convergence (gated) OK …` (the existing test) and then `  baseline-consistency (gated) OK parsed=… minOf3=… relErr=0.0XX`. The run ends with `MLX Winograd tuner tests passed`. Process exit code 0.

(This test should pass directly on first run because Task 1 and Task 2 have already made the log line emit a real `baseline_ms` value, and the implementation re-scores the same default-constructed `InputTransform{}` that this test re-scores independently. The 25% tolerance absorbs the ~10% per-sample noise floor.)

- [ ] **Step 4: Confirm no regression in the ungated run**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago runnnlayertests 2>&1 | tail -20
```

Expected: all existing tests pass; new gated blocks skipped; exit code 0.

- [ ] **Step 5: Run both gates together once to confirm they coexist**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST=1 \
KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST=1 \
./katago runnnlayertests 2>&1 | tail -40
```

Expected: tail contains `  flatSweepInput log-format (gated) OK`, `  flatSweepOutput log-format (gated) OK`, `  SP5 flat-sweep convergence (gated) OK …`, and `  baseline-consistency (gated) OK …`. Exit code 0.

- [ ] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxwinotuner.cpp
git -c user.email=chin.chang.yang@gmail.com commit -m "MLX tuner: gated baseline-consistency check

Adds Test 2 from the baseline-anchor spec: after the sweep, re-scores
the default-constructed InputTransform 3 times, takes the min, and
asserts the parsed baseline_ms log field is within 25% of that. Guards
against off-by-ones in the format string and stale-cache parse errors.
Gated behind the existing KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST so it
shares the SP5 Task 10 opt-in cost.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

### Spec coverage

Each spec requirement maps to a task:

| Spec requirement | Task |
|---|---|
| Success criterion: extended log line per stage after every re-tune | Task 1 (input), Task 2 (output) |
| Architecture Change 1 — `flatSweepInput` baseline + log augmentation | Task 1, Step 5 |
| Architecture Change 2 — `flatSweepOutput` baseline + log augmentation | Task 2, Step 4 |
| Log format: field order `considered`, `best=…`, `time_ms`, `baseline_ms`, `delta_pct` | Task 1, Step 5 + Task 2, Step 4 (code matches format exactly) |
| `delta_pct=nan` when no winner or `baselineMs<1e-9` | Task 1, Step 5 (`if(best && baselineMs >= 1e-9) …` branch); same in Task 2 |
| Sign convention: negative = winner faster | Task 1, Step 5 (`(bestTime − baselineMs)/baselineMs × 100`, rendered `%+.1f`) |
| Cost <30 ms added | Implicit — one extra `score*` call per stage. Measured indirectly via Task 1 Step 7 / Task 2 Step 6. |
| Test 1 — log-format regex unit check (gated) | Task 1 (input) + Task 2 (extends to output) |
| Test 2 — baseline-consistency gated check | Task 3 |
| No on-disk cache format change | No task touches `MLXWinogradTuneParams::save`/`load` or `MLX_WINO_TUNER_VERSION` |
| No public API change | No task touches `mlxwinotuner.h` |
| All existing tests stay green | Task 1 Step 8, Task 2 Step 7, Task 3 Step 4 (ungated runs) |

Non-goals listed in the spec (estimator change, batching, shape weights, refuse-and-fall-back, persistence of `baseline_ms`, public-API additions) — confirmed not introduced by any task.

### Placeholder scan

No "TBD", "TODO", "implement later", or "Similar to Task N" in any task. Every step contains either complete code, an exact command, or an exact verification criterion.

### Type consistency

- `baselineMs` (type `double`) defined consistently in `flatSweepInput` (Task 1 Step 5) and `flatSweepOutput` (Task 2 Step 4).
- `deltaStr` (type `std::string`) constructed identically in both functions.
- `MLXWinograd::InputTransform{}` and `MLXWinograd::OutputUntransform{}` — confirmed default-constructed via the struct definitions at `cpp/neuralnet/mlxwinograd.h:16-27`.
- `MLXWinogradTuner::scoreInputTransformForTesting` (Test 2) — namespace-qualified free function declared at `cpp/neuralnet/mlxwinotuner.h:73`.
- `Logger::addOStream(std::ostream&)` (both tests) — signature confirmed at `cpp/core/logger.h:32`.
- `Global::strprintf` (both impls) — usage matches existing patterns at lines 559, 593, 643 of the current file.
- Regex format-string field order in tests matches the construction order in implementations: `considered=` → `best=tg0= tg1= wpt= [vw= gridOrder=] time_ms=` → `baseline_ms=` → `delta_pct=`.
