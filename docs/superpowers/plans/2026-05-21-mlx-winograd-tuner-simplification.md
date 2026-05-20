# SP5 — MLX Winograd Tuner Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete three SP4 search axes that empirical measurement proved insensitive (`matmulOrient`, output `gridOrder`, output `vw`), flatten the hierarchical search to a single per-stage sweep, and bump the tuner cache schema to v3.

**Architecture:** Bottom-up ordering: add the new flat sweep first (parallel to SP4's Joint-A/B/refine), then switch the driver, then delete the dead kernel template branches and C++ types one axis at a time, then bump the cache schema. Each task leaves the code compiling and tests passing. The data model and kernel templates collapse together to avoid mid-tree states where a saved cache field has no corresponding kernel template arg.

**Tech Stack:** C++17, MLX (Apple Silicon Metal kernels), CMake/Ninja. Reference design: `docs/superpowers/specs/2026-05-21-mlx-winograd-tuner-simplification-design.md`.

---

## File map

| File | Role | SP5 changes |
|---|---|---|
| `cpp/neuralnet/mlxwinograd.h` | Kernel sources, `winogradConv2d`, `makeWinogradWeights`, enums | Delete `MatmulOrient` enum, `kWinoOutputSource`'s VW>1 paths + Tfast branch, `makeWinogradWeights` orient parameter, `winogradConv2d` matmulOrient parameter |
| `cpp/neuralnet/mlxwinotuner.h` | Tuner public API, `MLXWinogradTuneParams` struct | Drop global `gridOrder` and `matmulOrient` fields, drop output `vw`/`gridOrder` fields, delete test-only Joint-A/B exposures |
| `cpp/neuralnet/mlxwinotuner.cpp` | Tuner implementation | Bump `MLX_WINO_TUNER_VERSION=3`, rewrite save/load/isValid for v3 schema, replace Joint-A/B/refine with flat sweep, delete `kJointPassACollapseThreshold` and `timeOneEndToEnd` |
| `cpp/neuralnet/mlxbackend.cpp` | KataGo NN backend layer | Drop `matmulOrient` field on `ConvLayer`, drop `MatmulOrient orient` threading through Residual/Trunk/PolicyHead/ValueHead, drop `tuneParams.matmulOrient` read in `Model::Model`, drop `-or` segment from `makeCacheKey` |
| `cpp/tests/testnn.cpp` | Layer + tuner unit tests | Delete tests of dropped axes; add v3 roundtrip, isValid, output-monomorphic, flat-sweep convergence tests |
| `cpp/tools/bench_sp4_acceptance.sh` | SP4 acceptance gate | Delete |
| `cpp/tools/bench_sp5_acceptance.sh` | SP5 acceptance gate | Create — three sub-gates: paired-t perf parity vs SP4, cold-start wall-time, accuracy via testgpuerror |

---

## Task 1: Add flat per-stage sweep functions (no wiring)

**Goal:** Land the new search algorithm side-by-side with the existing Joint-A/B/refine code. No behavior change yet.

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (add two new static functions, before `loadOrAutoTune`)
- Modify: `cpp/tests/testnn.cpp` (add forward decl + smoke test for the new functions)

- [ ] **Step 1: Find a good insertion point in `mlxwinotuner.cpp`**

Run: `grep -n "^MLXWinogradTuneParams MLXWinogradTuner::loadOrAutoTune" cpp/neuralnet/mlxwinotuner.cpp`
Expected: one line number — call this `INSERT_LINE`. The new functions go immediately above it.

- [ ] **Step 2: Add the flat-sweep input-stage helper**

Insert the following (anonymous namespace) above `loadOrAutoTune`:

```cpp
namespace {

// Flat sweep over (tg0, tg1, wpt, vw, gridOrder) for the input transform.
// Replaces SP4's Joint-A/B/refine cascade. Returns the best (lowest-time)
// candidate that passes isInputCandidateValid; nullopt if no candidate is
// valid (defensive — should not happen for a real model).
static std::optional<MLXWinograd::InputTransform>
flatSweepInput(int N, int H, int W,
               const MLXWinogradTuner::ModelInfoForTuning& mi,
               bool useFP16, bool full, Logger* logger) {
  using GO = MLXWinograd::GridOrder;
  const int C  = mi.maxConvChannels3x3;
  const int tilesY = (H + 1) / 2;
  const int tilesX = (W + 1) / 2;
  const int Ntiles = N * tilesY * tilesX;

  std::optional<MLXWinograd::InputTransform> best;
  double bestTime = std::numeric_limits<double>::infinity();
  int considered = 0, valid = 0;

  for(GO go : {GO::Cfast, GO::Tfast}) {
    auto cands = MLXWinogradTuner::buildInputCandidatesForTesting(full, C, Ntiles, go);
    for(const auto& cand : cands) {
      considered++;
      if(!isInputCandidateValid(cand, C, Ntiles)) continue;
      valid++;
      double t = scoreInputTransform(cand, N, H, W, mi, useFP16);
      if(t < bestTime) { bestTime = t; best = cand; }
    }
  }
  if(logger) {
    logger->write("MLX tuner flatSweepInput: considered=" + std::to_string(considered)
                  + " valid=" + std::to_string(valid)
                  + (best
                     ? " best=tg0=" + std::to_string(best->tg0)
                       + " tg1=" + std::to_string(best->tg1)
                       + " wpt=" + std::to_string(best->wpt)
                       + " vw="  + std::to_string(best->vw)
                       + " gridOrder=" + std::to_string((int)best->gridOrder)
                       + " time_ms=" + Global::strprintf("%.3f", bestTime)
                     : " best=none"));
  }
  return best;
}

// Flat sweep over (tg0, tg1, wpt) for the output untransform. Output VW
// and gridOrder are not searched in SP5 (kernel will hardcode them in
// Tasks 3-4).
static std::optional<MLXWinograd::OutputUntransform>
flatSweepOutput(int N, int H, int W,
                const MLXWinogradTuner::ModelInfoForTuning& mi,
                bool useFP16, bool full, Logger* logger) {
  using GO = MLXWinograd::GridOrder;
  const int outC = mi.midNumChannels;  // output untransform reads from matmul output
  const int Ntiles = N * ((H + 1) / 2) * ((W + 1) / 2);

  std::optional<MLXWinograd::OutputUntransform> best;
  double bestTime = std::numeric_limits<double>::infinity();
  int considered = 0, valid = 0;

  // Iterate only Cfast (Task 4 will drop the output gridOrder axis entirely).
  // We pin gridOrder=Cfast and vw=1 here to match the post-SP5 kernel monomorph.
  auto cands = MLXWinogradTuner::buildOutputCandidatesForTesting(full, outC, Ntiles, GO::Cfast);
  for(auto cand : cands) {
    cand.vw = 1;
    cand.gridOrder = GO::Cfast;
    considered++;
    if(!isOutputCandidateValid(cand, outC, Ntiles)) continue;
    valid++;
    double t = scoreOutputUntransform(cand, N, H, W, mi, useFP16);
    if(t < bestTime) { bestTime = t; best = cand; }
  }
  if(logger) {
    logger->write("MLX tuner flatSweepOutput: considered=" + std::to_string(considered)
                  + " valid=" + std::to_string(valid)
                  + (best
                     ? " best=tg0=" + std::to_string(best->tg0)
                       + " tg1=" + std::to_string(best->tg1)
                       + " wpt=" + std::to_string(best->wpt)
                       + " time_ms=" + Global::strprintf("%.3f", bestTime)
                     : " best=none"));
  }
  return best;
}

} // anonymous namespace
```

Notes:
- `isInputCandidateValid`, `isOutputCandidateValid`, `scoreInputTransform`, `scoreOutputUntransform` already exist in this file as static helpers — confirm via `grep -n "static bool isInputCandidateValid\|static double scoreInputTransform" cpp/neuralnet/mlxwinotuner.cpp`. If they're in a different anonymous namespace, hoist the new functions adjacent to them.
- Include `<optional>` and `<limits>` at the top if not already present.

- [ ] **Step 3: Add the headers `<optional>` and `<limits>` if missing**

Run: `grep -n "^#include <optional>\|^#include <limits>" cpp/neuralnet/mlxwinotuner.cpp`
If either is absent, add it to the existing block of `<cmath>`/`<fstream>` includes near the top.

- [ ] **Step 4: Build to confirm no behavior change**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
```
Expected: build succeeds with two unused-function warnings (the new helpers are declared `static` and not yet called). If `-Werror` is on, mark them `[[maybe_unused]]` temporarily.

- [ ] **Step 5: Run existing unit tests**

Run: `./katago runnnlayertests`
Expected: PASS (no logic changed).

- [ ] **Step 6: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.cpp
git commit -m "SP5 Task 1: Add flat per-stage sweep functions (not yet wired)

Adds flatSweepInput and flatSweepOutput as the SP5 replacement for the
SP4 Joint-A/B/refine cascade. Not called yet — Task 2 wires them into
loadOrAutoTune.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Wire loadOrAutoTune to flat sweep; delete Joint-A/B/refine

**Goal:** Switch the production tune driver to the flat sweep. Delete the SP4 hierarchical helpers since nothing references them anymore.

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (rewrite `loadOrAutoTune` body, delete Joint-A/B/refine helpers, delete `kJointPassACollapseThreshold`, delete `timeOneEndToEnd`)
- Modify: `cpp/neuralnet/mlxwinotuner.h` (delete `jointPassA_InputForTesting`, `jointPassA_OutputForTesting`, `WptVwScoreForTesting` if no other caller — keep `scoreInputTransformForTesting`/`scoreOutputUntransformForTesting` and `buildInputCandidatesForTesting`/`buildOutputCandidatesForTesting`)
- Modify: `cpp/tests/testnn.cpp` (delete the Joint-A top-3 sort test, Joint-A/B Input/Output tests, SP4 bad-seed convergence test)

- [ ] **Step 1: Find the SP4 hierarchical code blocks to delete**

Run:
```bash
grep -n "jointPassA_\|jointPassB_\|refineInput\|refineOutput\|kJointPassACollapseThreshold\|timeOneEndToEnd" cpp/neuralnet/mlxwinotuner.cpp
```
Expected: a long list of function definitions, calls within `loadOrAutoTune`, and the test-only exposures. All will be deleted.

- [ ] **Step 2: Rewrite `loadOrAutoTune` body**

Locate the function and replace the SP4 4-way outer wrapper + Joint-A/B/refine body with:

```cpp
MLXWinogradTuneParams MLXWinogradTuner::loadOrAutoTune(
    std::string tunerFile,
    const std::string& homeDataDirOverride,
    const std::string& gpuName,
    int nnXLen, int nnYLen, int batchSize,
    ModelInfoForTuning modelInfo,
    Logger* logger,
    bool full,
    bool reTune,
    bool useFP16,
    const MLXWinogradTuneParams* seedOverride
) {
  // Cache load path: if the file exists, validates, and reTune is false, use it.
  if(!reTune && !tunerFile.empty() && FileUtils::exists(tunerFile)) {
    try {
      MLXWinogradTuneParams loaded = MLXWinogradTuneParams::load(tunerFile);
      if(loaded.isValid()) {
        if(logger)
          logger->write("Loaded MLX Winograd tuning parameters from " + tunerFile);
        return loaded;
      }
      if(logger)
        logger->write("MLX Winograd cache " + tunerFile + " failed isValid(); re-tuning");
    } catch(const IOError& e) {
      if(logger)
        logger->write(std::string("MLX Winograd cache load failed: ") + e.what() + "; re-tuning");
    }
  }

  // Flat per-stage sweep.
  auto t0 = std::chrono::steady_clock::now();
  auto bestIn  = flatSweepInput (batchSize, nnYLen, nnXLen, modelInfo, useFP16, full, logger);
  auto bestOut = flatSweepOutput(batchSize, nnYLen, nnXLen, modelInfo, useFP16, full, logger);
  auto t1 = std::chrono::steady_clock::now();
  double tuneMs = std::chrono::duration<double, std::milli>(t1 - t0).count();
  if(logger)
    logger->write("MLX tuner flat sweep complete in " + Global::strprintf("%.0f", tuneMs) + " ms");

  if(!bestIn || !bestOut)
    throw StringError("MLXWinogradTuner: flat sweep returned no valid candidate");

  MLXWinogradTuneParams result;
  result.inputTransform    = *bestIn;
  result.outputUntransform = *bestOut;
  // (Global gridOrder and matmulOrient still live on the struct in Task 2; we
  // set defaults. Tasks 5-6 delete those fields entirely.)
  result.gridOrder    = bestIn->gridOrder;
  result.matmulOrient = MLXWinograd::MatmulOrient::Std;

  if(!result.isValid())
    throw StringError("MLXWinogradTuner: flat sweep result failed isValid()");

  if(!tunerFile.empty()) {
    MLXWinogradTuneParams::save(tunerFile, result);
    if(logger)
      logger->write("Saved MLX Winograd tuning parameters to " + tunerFile);
  }
  return result;
}
```

- [ ] **Step 3: Delete the SP4 helpers**

Delete from `mlxwinotuner.cpp`:
- `static constexpr double kJointPassACollapseThreshold = 0.02;`
- `jointPassA_collect<...>` template helper
- `jointPassA_Input`, `jointPassA_Output`
- `jointPassB_collect<...>` template helper
- `jointPassB_Input`, `jointPassB_Output`
- `refineInput`, `refineOutput`
- `timeOneEndToEnd`
- `WptVwScore` struct (anonymous-namespace internal — distinct from the public `WptVwScoreForTesting`)
- The test-only thunks `jointPassA_InputForTesting` and `jointPassA_OutputForTesting`

Use `grep -n` to find each before deletion.

- [ ] **Step 4: Delete the same thunks from the header**

In `cpp/neuralnet/mlxwinotuner.h`:
- Delete the `struct WptVwScoreForTesting { ... };` declaration
- Delete the two `jointPassA_*ForTesting` forward declarations

Keep `scoreInputTransformForTesting`, `scoreOutputUntransformForTesting`, `buildInputCandidatesForTesting`, `buildOutputCandidatesForTesting` — they are reused by the new tests.

- [ ] **Step 5: Delete the matching tests in `testnn.cpp`**

Run: `grep -n "jointPassA_\|jointPassB_\|kJointPassACollapseThreshold\|bad.?seed\|RUN_SP4_BADSEED" cpp/tests/testnn.cpp`

Delete each enclosing test block. Specifically:
- The Joint-A top-3 sort test
- Joint-A/B Input/Output tests
- The `KATAGO_MLX_WINOTUNER_RUN_SP4_BADSEED_TEST` convergence test (the failure mode is structurally gone)

Leave the WPT/VW/Cfast-vs-Tfast/candidate-enumeration/isValid tests intact for now — they exercise input-stage axes that still exist.

- [ ] **Step 6: Build**

Run: `cd cpp && ninja`
Expected: build succeeds. Any unused-helper warnings should now be gone (flatSweepInput/Output are now called from loadOrAutoTune).

- [ ] **Step 7: Run tests**

Run: `./katago runnnlayertests`
Expected: PASS.

- [ ] **Step 8: Smoke-tune to verify driver works**

```bash
trash ~/.katago/mlxwinotuning/tunemlxwino2_gpuAppleSilicon_x19_y19_c384_mv11_fp16.txt
./katago benchmark -model ~/.katago/b18c384nbt-uec-20221121b.bin.gz \
  -config configs/gtp_example.cfg -override-config "mlxUseFP16=true" \
  -t 1 -v 100 -n 1 2>&1 | grep -E "flat sweep|tuning parameters"
```
Expected: log lines `MLX tuner flatSweepInput: considered=... valid=... best=...`, `MLX tuner flatSweepOutput: ...`, `MLX tuner flat sweep complete in NNNNN ms`, `Saved MLX Winograd tuning parameters to ...`. Total tune time should be under 120 s.

- [ ] **Step 9: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.cpp cpp/neuralnet/mlxwinotuner.h cpp/tests/testnn.cpp
git commit -m "SP5 Task 2: Switch loadOrAutoTune to flat sweep; delete Joint-A/B/refine

Production driver now uses flatSweepInput/flatSweepOutput. Deletes the
SP4 hierarchical search helpers (Joint-A, Joint-B, refine, outer combo
wrapper) and their test-only exposures. The SP4 bad-seed convergence
test is removed — the failure mode it guarded against (noisy outer-combo
selection) is structurally impossible after this change.

Output stage now hardcodes vw=1 and gridOrder=Cfast at the candidate
level; the kernel template branches themselves are deleted in Tasks 3-4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Drop output VW (kernel template arg + data model field + tests)

**Goal:** Make the output kernel monomorphic on VW=1. Delete the VW template arg from `kWinoOutputSource`, the `OutputUntransform::vw` field, the VW>1 read paths, and the output-VW equivalence tests.

**Files:**
- Modify: `cpp/neuralnet/mlxwinograd.h` (kernel source, `winogradConv2d`, `OutputUntransform`)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (`timeOneOutputUntransform`, `buildOutputCandidates`, `isOutputCandidateValid`, save/load output line)
- Modify: `cpp/tests/testnn.cpp` (delete output-VW tests)

- [ ] **Step 1: Locate the output-kernel VW template arg site**

Run: `grep -n "VW\b" cpp/neuralnet/mlxwinograd.h | head -30`
Expected: lines in `kWinoOutputSource` referencing `VW` in template params, `static_assert`, and `for (int vc = 0; vc < VW; vc++)` loops.

- [ ] **Step 2: Remove VW from `kWinoOutputSource`**

In the kernel source string for `wino_output_untransform` (around line 322-450 in `mlxwinograd.h`):
- Delete `template <typename T, int WPT, int VW, int GRID_ORDER>` → `template <typename T, int WPT, int GRID_ORDER>`
- Delete the `static_assert(WPT >= 1 && VW >= 1, ...)` and replace with `static_assert(WPT >= 1, "WPT must be positive")`
- Delete the `static_assert(GRID_ORDER == 0 || VW == 1, ...)` (VW is gone)
- Delete the `for (int vc = 0; vc < VW; vc++) { ... }` wrapper loops; inline the loop body with `vc = 0` substituted (i.e., the loop becomes straight-line code reading one channel/output)
- In the Cfast grid description comment, change `ceil(Cout/VW)` to `Cout`
- Adjust the inner index arithmetic: any `c_group * VW + vc` becomes just `c_group`

- [ ] **Step 3: Update `winogradConv2d` output kernel template args**

Around line 470-545 in `mlxwinograd.h`, in the `makeTemplateArgs` lambda invocation for the output kernel call:
- Delete `{"VW", vw}` entry from the output template_args list
- Update the comment referencing `(ceil(Cout/VW), ceil(Ntiles/WPT), 1)` grid to `(Cout, ceil(Ntiles/WPT), 1)`
- Change `int gridX_out = (outCfg.gridOrder == GridOrder::Cfast) ? ((outC + outCfg.vw - 1) / outCfg.vw) : Ntiles;` to `int gridX_out = (outCfg.gridOrder == GridOrder::Cfast) ? outC : Ntiles;`

The `makeTemplateArgs` lambda is shared with the input kernel — keep VW in that lambda for the input call. Output call uses a separate template list inline.

- [ ] **Step 4: Drop `vw` field from `OutputUntransform`**

In `cpp/neuralnet/mlxwinograd.h` around line 23-29:
```cpp
struct OutputUntransform {
  int tg0 = 32;
  int tg1 = 1;
  int wpt = 1;
  GridOrder gridOrder = GridOrder::Cfast;
};
```

- [ ] **Step 5: Update `timeOneOutputUntransform` in `mlxwinotuner.cpp`**

Find with `grep -n "static double timeOneOutputUntransform" cpp/neuralnet/mlxwinotuner.cpp`. In the body:
- Drop `{"VW", cfg.vw}` from the `tmplArgs` vector
- Drop the kernel-name VW suffix: replace `+ "_v" + std::to_string(cfg.vw)` with `""` (i.e., remove that fragment)
- In the grid calculation, replace `((channels + cfg.vw - 1) / cfg.vw)` with `channels`

- [ ] **Step 6: Update `buildOutputCandidates` in `mlxwinotuner.cpp`**

Find with `grep -n "buildOutputCandidates\b" cpp/neuralnet/mlxwinotuner.cpp`. Drop the `for(int vw : vwValues)` loop wrapper; remove the `cand.vw = vw` assignment. The candidate vector now varies only over `(tg0, tg1, wpt)` × `gridOrder` (the gridOrder dimension is dropped in Task 4).

- [ ] **Step 7: Update `isOutputCandidateValid` in `mlxwinotuner.cpp`**

Delete any check involving `cfg.vw`. Specifically the Cfast-divisibility check on output channels — output channels are now read one at a time, no vector-width divisibility constraint.

- [ ] **Step 8: Update v2 save/load for output line**

In `MLXWinogradTuneParams::save` (around line 100 in `mlxwinotuner.cpp`):
- Remove `<< " vw="  << params.outputUntransform.vw` from the output line
In `MLXWinogradTuneParams::load`:
- Remove `params.outputUntransform.vw  = requireKey(kvs, "vw",  filename);`

Note: this technically breaks v2 backward compatibility — any in-flight v2 cache file with `vw=N` on the output line will trigger a "missing key" error. That's fine; the cache is regenerated on next run. The proper v3 bump happens in Task 7.

- [ ] **Step 9: Update `isValid` to drop output VW check**

In `bool MLXWinogradTuneParams::isValid()` around line 64-90:
- Delete `if(outputUntransform.vw < 1) return false;`
- Delete any Tfast⇒vw=1 check that references `outputUntransform.vw`

- [ ] **Step 10: Update `flatSweepOutput`**

In `cpp/neuralnet/mlxwinotuner.cpp` (added in Task 1), delete the `cand.vw = 1;` line — the field no longer exists.

- [ ] **Step 11: Delete output-VW tests in `testnn.cpp`**

Run: `grep -n "output.*VW\|VW.*output\|outputUntransform\.vw\|wino_output_untransform.*vw" cpp/tests/testnn.cpp`

Delete each test that exercises output `vw` variation (vw=1/2/4 on output, fp16 output VW equivalence). Keep input-VW tests.

Also delete any `outputUntransform.vw = N;` assignments in the v2 roundtrip test setup (the field is gone).

- [ ] **Step 12: Build and test**

```bash
cd cpp && ninja
./katago runnnlayertests
```
Expected: PASS.

- [ ] **Step 13: Commit**

```bash
git add cpp/neuralnet/mlxwinograd.h cpp/neuralnet/mlxwinotuner.cpp cpp/neuralnet/mlxwinotuner.h cpp/tests/testnn.cpp
git commit -m "SP5 Task 3: Drop output VW (kernel + data model + tests)

Output kernel is now monomorphic on VW=1 — empirical sensitivity sweep
showed output VW is flat (<3% delta). Removes the VW template arg from
kWinoOutputSource, the OutputUntransform::vw field, the VW>1 read paths
in the output kernel, and the output-VW equivalence tests. Input VW is
unaffected (still searched).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Drop output gridOrder (kernel template arg + data model field + tests)

**Goal:** Make the output kernel monomorphic on GRID_ORDER=Cfast. Same shape as Task 3.

**Files:**
- Modify: `cpp/neuralnet/mlxwinograd.h` (delete Tfast branch in `kWinoOutputSource`, drop GRID_ORDER template arg)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (`timeOneOutputUntransform`, `buildOutputCandidates`, save/load)
- Modify: `cpp/tests/testnn.cpp` (delete output Cfast-vs-Tfast tests)

- [ ] **Step 1: Remove GRID_ORDER template arg and Tfast branch from `kWinoOutputSource`**

In the kernel source string:
- Delete `template <typename T, int WPT, int GRID_ORDER>` → `template <typename T, int WPT>`
- Delete the entire `if (GRID_ORDER == 1) { ... }` Tfast clause (or the `else` branch — whichever wraps the Tfast logic)
- The remaining body is the Cfast path; the `if (GRID_ORDER == 0)` wrapper is collapsed to straight-line code

- [ ] **Step 2: Update `winogradConv2d` output call template args**

- Delete `{"GRID_ORDER", (int)outCfg.gridOrder}` from output `makeTemplateArgs` invocation
- Replace the grid calculation `int gridX_out = (outCfg.gridOrder == GridOrder::Cfast) ? outC : Ntiles;` with `int gridX_out = outC;`
- Replace `int gridY_out = (outCfg.gridOrder == GridOrder::Cfast) ? ((Ntiles + outCfg.wpt - 1) / outCfg.wpt) : ((outC + outCfg.wpt - 1) / outCfg.wpt);` with `int gridY_out = (Ntiles + outCfg.wpt - 1) / outCfg.wpt;`

- [ ] **Step 3: Drop `gridOrder` field from `OutputUntransform`**

In `cpp/neuralnet/mlxwinograd.h`:
```cpp
struct OutputUntransform {
  int tg0 = 32;
  int tg1 = 1;
  int wpt = 1;
};
```

- [ ] **Step 4: Update `timeOneOutputUntransform`**

- Drop `{"GRID_ORDER", (int)cfg.gridOrder}` from `tmplArgs`
- Drop `+ "_g" + std::to_string((int)cfg.gridOrder)` from kernel name
- Replace gridX/gridY calculations as in Step 2

- [ ] **Step 5: Update `buildOutputCandidates`**

- Drop the `GridOrder go` parameter — function now returns a flat vector over `(tg0, tg1, wpt)` only.
- Update the function declaration in `mlxwinotuner.h`:
  ```cpp
  std::vector<MLXWinograd::OutputUntransform>
  buildOutputCandidatesForTesting(bool full, int outC, int Ntiles);
  ```
- Update all callers (flatSweepOutput, any tests).

- [ ] **Step 6: Update v2 save/load for output line**

In `save`:
- Remove `<< " gridOrder=" << (int)params.outputUntransform.gridOrder` from the output line
In `load`:
- Remove the corresponding `requireKey(kvs, "gridOrder", filename)` for the output transform

- [ ] **Step 7: Update `isValid`**

Delete the `if(outputUntransform.gridOrder != gridOrder) return false;` check.

- [ ] **Step 8: Update `flatSweepOutput`**

Drop the `cand.gridOrder = GO::Cfast;` line — the field no longer exists.

- [ ] **Step 9: Delete output Cfast-vs-Tfast tests**

Run: `grep -n "Cfast.*Tfast.*output\|output.*Tfast\|kWinoOutputSource.*Tfast" cpp/tests/testnn.cpp`

Delete each enclosing test. Specifically:
- Cfast-vs-Tfast bit-identity for output kernel
- Output Tfast tail-guard at C=67

Keep input-stage Cfast-vs-Tfast tests intact.

- [ ] **Step 10: Build and test**

```bash
cd cpp && ninja
./katago runnnlayertests
```
Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add cpp/neuralnet/mlxwinograd.h cpp/neuralnet/mlxwinotuner.cpp cpp/neuralnet/mlxwinotuner.h cpp/tests/testnn.cpp
git commit -m "SP5 Task 4: Drop output gridOrder (kernel + data model + tests)

Output kernel is now monomorphic on GRID_ORDER=Cfast — empirical
sensitivity sweep showed output gridOrder is flat (<1% delta). Removes
the GRID_ORDER template arg from kWinoOutputSource, the
OutputUntransform::gridOrder field, the Tfast kernel branch, and the
output Cfast-vs-Tfast tests. Input gridOrder is unaffected (still
searched — fp16 prefers Cfast, fp32 prefers Tfast per the sweep).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Drop matmulOrient (enum + kernel branch + weight layout + backend threading + tests)

**Goal:** Delete the `MatmulOrient` axis end-to-end. This is the largest task — it threads through 5 layer types and the weight-tensor layout.

**Files:**
- Modify: `cpp/neuralnet/mlxwinograd.h` (delete `MatmulOrient` enum, Tpd branch in input kernel, Tpd weight layout in `makeWinogradWeights`, `matmulOrient` parameter on `winogradConv2d`)
- Modify: `cpp/neuralnet/mlxwinotuner.h` (delete `MLXWinogradTuneParams::matmulOrient` field, drop docstring reference)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (drop matmulOrient from save/load, isValid, scoreInputTransform, timeOneInputTransform, flatSweepInput; drop the `MLXWinograd::MatmulOrient::Std` defaulting in loadOrAutoTune)
- Modify: `cpp/neuralnet/mlxbackend.cpp` (delete `matmulOrient` field on `ConvLayer`, delete `MatmulOrient orient` parameter on Residual/Trunk/PolicyHead/ValueHead/Model, delete `tuneParams.matmulOrient` read, delete `-or` segment from `makeCacheKey`)
- Modify: `cpp/tests/testnn.cpp` (delete Std-vs-Tpd equivalence tests + Tfast×Tpd combo)

- [ ] **Step 1: Audit `MatmulOrient` references**

Run: `grep -rn "MatmulOrient\|matmulOrient" cpp/neuralnet/ cpp/tests/ | wc -l`
Expected: ~40 references. Spot-check the call sites in `mlxbackend.cpp` (ConvLayer ctor, Residual/Trunk/PolicyHead/ValueHead ctors, Model::Model).

- [ ] **Step 2: Remove from `mlxwinograd.h`**

- Delete `enum class MatmulOrient : int { Std = 0, Tpd = 1 };` (around line 11)
- In `makeWinogradWeights` (around line 140-170): drop the `MatmulOrient orient` parameter; collapse the conditional weight layout to the Std-only path (output shape `{16, Cin, Cout}`, the `idx = orient == Std ? ... : ...` becomes the Std formula)
- In `winogradConv2d` (around line 449): drop the `MatmulOrient matmulOrient = MatmulOrient::Std` parameter
- In the kernel-name suffix: drop `+ "_o" + std::to_string((int)matmulOrient)`
- In `tmplArgs` for the input kernel: drop `{"MATMUL_ORIENT", (int)matmulOrient}`
- In the output-shape branch (around line 481-485): collapse `(matmulOrient == Std ? {16, Ntiles, channels} : {16, channels, Ntiles})` to `{16, Ntiles, channels}` (Std-only)
- In the matmul-input branch (around line 519): collapse `(matmulOrient == Std ? m : transpose(m, {0, 2, 1}))` to just `m`
- In `kWinoInputSource`: delete the `MATMUL_ORIENT` template parameter and the Tpd write branch (the `if (MATMUL_ORIENT == 0) { write Std layout } else { write Tpd layout }` collapses to the Std branch)

- [ ] **Step 3: Remove from `mlxwinotuner.h`**

- In `struct MLXWinogradTuneParams`: delete `MLXWinograd::MatmulOrient matmulOrient = MLXWinograd::MatmulOrient::Std;`
- Update the docstring comment to drop the v2 format references for the `#global` matmulOrient line — these will be fully rewritten in Task 7

- [ ] **Step 4: Remove from `mlxwinotuner.cpp`**

- In `MLXWinogradTuneParams::save`: delete `<< " matmulOrient=" << (int)params.matmulOrient` from the `#global` line. Note: after this step, the `#global` line only contains `gridOrder` — that whole section gets deleted in Task 7.
- In `MLXWinogradTuneParams::load`: delete `params.matmulOrient = (MLXWinograd::MatmulOrient)requireKey(kvs, "matmulOrient", filename);`
- In `MLXWinogradTuneParams::isValid`: delete any check on `matmulOrient` (unlikely to exist, but search and delete)
- In `timeOneInputTransform`: drop the `MLXWinograd::MatmulOrient mo` parameter and the `mo`-conditional output shape logic; replace with Std-only output shape `{16, Ntiles, channels}`. Drop `{"MATMUL_ORIENT", (int)mo}` from `tmplArgs`. Drop `+ "_o" + std::to_string((int)mo)` from the kernel name.
- In `scoreInputTransform`: drop any `MatmulOrient` parameter (this is called by both `flatSweepInput` and `scoreInputTransformForTesting`).
- In `flatSweepInput`: drop any `mo` argument passed to `scoreInputTransform`.
- In `loadOrAutoTune`: delete `result.matmulOrient = MLXWinograd::MatmulOrient::Std;`

- [ ] **Step 5: Remove from `mlxbackend.cpp`**

This is the most mechanical part — auto-edit each layer signature. Use these greps to find every site:

```bash
grep -n "MatmulOrient\|matmulOrient" cpp/neuralnet/mlxbackend.cpp
```

For each call site:
- `ConvLayer` ctor and field: delete `const MLXWinograd::MatmulOrient matmulOrient;` field, delete `MLXWinograd::MatmulOrient orient = MLXWinograd::MatmulOrient::Std` parameter, delete `,matmulOrient(orient)` initializer, delete `matmulOrient` argument from any `winogradConv2d` calls
- `ResidualBlock`, `GlobalPoolingResidualBlock`, `NestedBottleneckResidualBlock`, `BlockVariant`, `Trunk`, `PolicyHead`, `ValueHead`: delete the `MLXWinograd::MatmulOrient orient = MLXWinograd::MatmulOrient::Std` parameter and stop forwarding it to inner ctors
- `Model::Model`: replace `tuneParams.matmulOrient` references in the trunk/policy/value constructor calls — remove the argument entirely
- `makeCacheKey`: delete the `"-or" + std::to_string((int)tuneParams.matmulOrient)` segment

- [ ] **Step 6: Delete Std-vs-Tpd tests in `testnn.cpp`**

Run: `grep -n "MatmulOrient\|Tpd\|Std vs Tpd\|matmulOrient" cpp/tests/testnn.cpp`

Delete each enclosing test block. Specifically:
- Std-vs-Tpd fp32 equivalence
- Std-vs-Tpd fp16 equivalence
- Tfast×Tpd combo test
- Any v2 roundtrip test cases that set `matmulOrient = Tpd`
- isValid invariant test for matmulOrient enum value 1 (if present)

- [ ] **Step 7: Build and test**

```bash
cd cpp && ninja
./katago runtests
./katago runnnlayertests
```
Expected: PASS.

Note: this is the riskiest task. If the build fails because a layer ctor still expects a `MatmulOrient` arg, grep for `MatmulOrient` again and find the missed site.

- [ ] **Step 8: End-to-end smoke benchmark**

```bash
trash ~/.katago/mlxwinotuning/tunemlxwino2_gpuAppleSilicon_x19_y19_c384_mv11_fp16.txt
./katago benchmark -model ~/.katago/b18c384nbt-uec-20221121b.bin.gz \
  -config configs/gtp_example.cfg -override-config "mlxUseFP16=true" \
  -t 1 -v 200 -n 2 2>&1 | grep -E "visits/s|tuning"
```
Expected: nps around 195-205 (matches SP4 baseline). If nps is significantly lower (<170), check that the Std-only weight layout matches what `kWinoInputSource` now writes.

- [ ] **Step 9: Commit**

```bash
git add cpp/neuralnet/mlxwinograd.h cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp cpp/neuralnet/mlxbackend.cpp cpp/tests/testnn.cpp
git commit -m "SP5 Task 5: Drop matmulOrient (enum + kernel + weight layout + backend threading)

Deletes the MatmulOrient axis end-to-end. Empirical sensitivity sweep
showed Tpd loses 7.5-12% vs Std on both fp16 and fp32 — Std always
wins. Removes:
- enum class MatmulOrient and all references
- the Tpd branch in kWinoInputSource (matmul write path for Tpd layout)
- the Tpd path in makeWinogradWeights (Std-only [16,Cin,Cout] now)
- the matmulOrient parameter on winogradConv2d
- the MLXWinogradTuneParams::matmulOrient field + serialization
- the matmulOrient field on ConvLayer and the MatmulOrient threading
  through 5 layer types (Residual/GlobalPool/NestedBottleneck/Trunk/
  PolicyHead/ValueHead)
- the -or segment from makeCacheKey
- the Std-vs-Tpd equivalence tests + Tfast×Tpd combo test

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Drop global gridOrder field from data model

**Goal:** Delete the `MLXWinogradTuneParams::gridOrder` global field. Input gridOrder lives on `InputTransform`; no global is needed.

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.h` (drop `MLXWinograd::GridOrder gridOrder` field from `MLXWinogradTuneParams`)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (drop `#global` line from save/load; drop isValid global-consistency check; drop global-gridOrder defaulting in loadOrAutoTune)
- Modify: `cpp/neuralnet/mlxbackend.cpp` (drop any `tuneParams.gridOrder` references in `makeCacheKey`)
- Modify: `cpp/tests/testnn.cpp` (drop v2 roundtrip global gridOrder coverage; will be replaced by v3 roundtrip in Task 8)

- [ ] **Step 1: Delete the field**

In `cpp/neuralnet/mlxwinotuner.h`:
```cpp
struct MLXWinogradTuneParams {
  MLXWinograd::InputTransform    inputTransform;
  MLXWinograd::OutputUntransform outputUntransform;
  bool isValid() const;
  static void save(const std::string& filename, const MLXWinogradTuneParams& params);
  static MLXWinogradTuneParams load(const std::string& filename);
};
```

(After Task 5 dropped `matmulOrient` and this drops `gridOrder`, the struct is just the two stage configs.)

- [ ] **Step 2: Update save/load in `mlxwinotuner.cpp`**

In `save`:
- Delete the `#global` comment write
- Delete the line writing `gridOrder=... matmulOrient=...` (matmulOrient already gone after Task 5; now this whole line goes too)

In `load`:
- Adjust the expected line count: previously 4 non-comment lines (VERSION + global + inputTransform + outputUntransform). After deleting global, expect 3 lines (VERSION + input + output). Update the `lines.size() != 4` check to `!= 3`.
- Delete the entire `kvs = parseKeyValueLine(filename, lines[1])` block that reads the global `gridOrder`/`matmulOrient`
- Re-index: `lines[1]` is now inputTransform, `lines[2]` is outputUntransform

- [ ] **Step 3: Update isValid in `mlxwinotuner.cpp`**

Delete the two `if(...gridOrder != gridOrder) return false;` consistency checks. The input gridOrder lives only on `inputTransform`; no cross-stage check needed (output stage no longer has a gridOrder).

The final `isValid` body is:
```cpp
bool MLXWinogradTuneParams::isValid() const {
  if(inputTransform.tg0 <= 0 || inputTransform.tg1 <= 0) return false;
  if(outputUntransform.tg0 <= 0 || outputUntransform.tg1 <= 0) return false;
  if(inputTransform.tg0 * inputTransform.tg1 > 1024) return false;
  if(outputUntransform.tg0 * outputUntransform.tg1 > 1024) return false;
  if(inputTransform.wpt < 1 || outputUntransform.wpt < 1) return false;
  if(inputTransform.vw  < 1) return false;
  if(inputTransform.gridOrder == MLXWinograd::GridOrder::Tfast
     && inputTransform.vw != 1) return false;
  return true;
}
```

- [ ] **Step 4: Update `loadOrAutoTune`**

Delete `result.gridOrder = bestIn->gridOrder;` (the global field is gone).

- [ ] **Step 5: Update `makeCacheKey` in `mlxbackend.cpp`**

Run: `grep -n "tuneParams.gridOrder\b" cpp/neuralnet/mlxbackend.cpp`
Delete any `-g{global gridOrder}` segment. The per-stage gridOrder (input only) stays — it's encoded via `tuneParams.inputTransform.gridOrder`.

- [ ] **Step 6: Update tests**

Run: `grep -n "params.gridOrder\s*=\|tuneParams.gridOrder\b" cpp/tests/testnn.cpp`
Delete any assignments to the (now-deleted) global `gridOrder` field in test setup code.

- [ ] **Step 7: Build and test**

```bash
cd cpp && ninja
./katago runnnlayertests
```
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp cpp/neuralnet/mlxbackend.cpp cpp/tests/testnn.cpp
git commit -m "SP5 Task 6: Drop global gridOrder field from MLXWinogradTuneParams

The global gridOrder existed in SP4 to enforce input/output gridOrder
consistency. After Task 4 deleted output gridOrder, only input
gridOrder remains — it lives on InputTransform directly, no global
needed. Drops the field, the #global serialization section (cache file
now has 3 non-comment lines), the cross-stage isValid consistency
check, and the makeCacheKey global-gridOrder segment.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Bump cache schema to v3

**Goal:** Cement the simplified schema as v3. Old v2 cache files are silently ignored (filename suffix changes).

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (`MLX_WINO_TUNER_VERSION = 3`)
- Modify: `cpp/neuralnet/mlxwinotuner.h` (update docstring above `save`)

- [ ] **Step 1: Bump the version constant**

In `cpp/neuralnet/mlxwinotuner.cpp` around line 28:
```cpp
static const int MLX_WINO_TUNER_VERSION = 3;
static const std::string MLX_WINO_TUNEPARAMS_VERSION_LINE =
    "VERSION=" + std::to_string(MLX_WINO_TUNER_VERSION);
```

- [ ] **Step 2: Update docstring in `mlxwinotuner.h`**

Replace the v2 format comment block (lines 22-29) with:

```cpp
  // VERSION=3 plain-text persistence. Format:
  //   VERSION=3
  //   #inputTransform
  //   tg0=<int> tg1=<int> wpt=<int> vw=<int> gridOrder=<0|1>
  //   #outputUntransform
  //   tg0=<int> tg1=<int> wpt=<int>
```

- [ ] **Step 3: Verify the filename function picks up the new version**

In `cpp/neuralnet/mlxwinotuner.cpp` `defaultFileName`:
```bash
grep -n "MLX_WINO_TUNER_VERSION" cpp/neuralnet/mlxwinotuner.cpp
```
Expected: the format string `tunemlxwino%d_gpu%s...` already substitutes `MLX_WINO_TUNER_VERSION`, so the filename automatically becomes `tunemlxwino3_...`. No change needed.

- [ ] **Step 4: Build and test**

```bash
cd cpp && ninja
./katago runnnlayertests
```
Expected: PASS. Any in-flight v2 cache files in `~/.katago/mlxwinotuning/` are simply ignored because the filename suffix changed (the v3-named file does not exist yet on a fresh run, triggering re-tune).

- [ ] **Step 5: Smoke-tune to verify v3 file is written**

```bash
trash ~/.katago/mlxwinotuning/tunemlxwino2_gpuAppleSilicon_x19_y19_c384_mv11_fp16.txt 2>/dev/null || true
./katago benchmark -model ~/.katago/b18c384nbt-uec-20221121b.bin.gz \
  -config configs/gtp_example.cfg -override-config "mlxUseFP16=true" \
  -t 1 -v 100 -n 1 2>&1 | grep -E "Saved.*tuning|tunemlxwino"
cat ~/.katago/mlxwinotuning/tunemlxwino3_gpuAppleSilicon_x19_y19_c384_mv11_fp16.txt
```

Expected: a fresh `tunemlxwino3_...` file with 5 lines: VERSION=3, `#inputTransform`, `tg0=... tg1=... wpt=... vw=... gridOrder=...`, `#outputUntransform`, `tg0=... tg1=... wpt=...`.

- [ ] **Step 6: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.cpp cpp/neuralnet/mlxwinotuner.h
git commit -m "SP5 Task 7: Bump cache schema to v3

Cache files now named tunemlxwino3_... Format is 3 non-comment lines
(VERSION + inputTransform + outputUntransform). The #global section is
gone (no more global gridOrder or matmulOrient). Output line carries
only tg0/tg1/wpt (no vw, no gridOrder). Old v2 files are silently
ignored — different filename suffix triggers fresh tune on next run.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Add v3 roundtrip + isValid invariant tests

**Goal:** Replace the SP4 v2 tests with v3 equivalents.

**Files:**
- Modify: `cpp/tests/testnn.cpp` (replace v2 roundtrip + v2 isValid tests)

- [ ] **Step 1: Locate the v2 roundtrip test**

Run: `grep -n "VERSION=2\|VERSION_2\|v2 roundtrip" cpp/tests/testnn.cpp`

Find the test that writes and reads back a `MLXWinogradTuneParams` to verify all serialization fields survive.

- [ ] **Step 2: Replace with v3 roundtrip**

Replace the v2 roundtrip test body with:

```cpp
{
  // v3 roundtrip: write -> load -> compare all 7 fields. Two cases for input
  // gridOrder: Cfast and Tfast. (Tfast forces vw=1 per isValid invariant.)
  using namespace MLXWinograd;
  for(auto inGo : {GridOrder::Cfast, GridOrder::Tfast}) {
    MLXWinogradTuneParams p;
    p.inputTransform.tg0 = 32;
    p.inputTransform.tg1 = 1;
    p.inputTransform.wpt = 2;
    p.inputTransform.vw  = (inGo == GridOrder::Cfast) ? 2 : 1;
    p.inputTransform.gridOrder = inGo;
    p.outputUntransform.tg0 = 32;
    p.outputUntransform.tg1 = 8;
    p.outputUntransform.wpt = 1;
    testAssert(p.isValid());

    std::string tmpFile = "/tmp/sp5_v3_roundtrip_" + std::to_string((int)inGo) + ".txt";
    MLXWinogradTuneParams::save(tmpFile, p);
    MLXWinogradTuneParams q = MLXWinogradTuneParams::load(tmpFile);
    testAssert(q.inputTransform.tg0 == p.inputTransform.tg0);
    testAssert(q.inputTransform.tg1 == p.inputTransform.tg1);
    testAssert(q.inputTransform.wpt == p.inputTransform.wpt);
    testAssert(q.inputTransform.vw  == p.inputTransform.vw);
    testAssert(q.inputTransform.gridOrder == p.inputTransform.gridOrder);
    testAssert(q.outputUntransform.tg0 == p.outputUntransform.tg0);
    testAssert(q.outputUntransform.tg1 == p.outputUntransform.tg1);
    testAssert(q.outputUntransform.wpt == p.outputUntransform.wpt);
    testAssert(q.isValid());
    std::remove(tmpFile.c_str());
  }
}
```

- [ ] **Step 3: Add v3 isValid invariant tests**

Add adjacent to the roundtrip test:

```cpp
{
  // v3 isValid invariants.
  using namespace MLXWinograd;
  auto basePass = [&]() {
    MLXWinogradTuneParams p;
    p.inputTransform = {32, 1, 1, 2, GridOrder::Cfast};
    p.outputUntransform = {32, 2, 1};
    return p;
  };

  // Baseline passes.
  testAssert(basePass().isValid());

  // tg0 <= 0 fails.
  { auto p = basePass(); p.inputTransform.tg0 = 0;  testAssert(!p.isValid()); }
  { auto p = basePass(); p.outputUntransform.tg0 = -1; testAssert(!p.isValid()); }

  // tg0 * tg1 > 1024 fails.
  { auto p = basePass(); p.inputTransform.tg0 = 64; p.inputTransform.tg1 = 32;
    testAssert(!p.isValid()); }

  // wpt < 1 fails.
  { auto p = basePass(); p.inputTransform.wpt = 0;  testAssert(!p.isValid()); }
  { auto p = basePass(); p.outputUntransform.wpt = 0; testAssert(!p.isValid()); }

  // vw < 1 fails on input.
  { auto p = basePass(); p.inputTransform.vw = 0;   testAssert(!p.isValid()); }

  // Tfast on input forces vw=1.
  { auto p = basePass();
    p.inputTransform.gridOrder = GridOrder::Tfast;
    p.inputTransform.vw = 2;
    testAssert(!p.isValid()); }
  { auto p = basePass();
    p.inputTransform.gridOrder = GridOrder::Tfast;
    p.inputTransform.vw = 1;
    testAssert(p.isValid()); }
}
```

- [ ] **Step 4: Build and run tests**

```bash
cd cpp && ninja
./katago runnnlayertests
```
Expected: PASS — new v3 tests pass; no SP4-era v2 tests remain in this section.

- [ ] **Step 5: Commit**

```bash
git add cpp/tests/testnn.cpp
git commit -m "SP5 Task 8: v3 roundtrip + isValid invariant tests

Adds v3 cache-format roundtrip (2 cases: Cfast + Tfast input gridOrder)
and exhaustive isValid branch coverage (tg<=0, tg0*tg1>1024, wpt<1,
vw<1, Tfast+VW>1).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Add output-kernel monomorphic smoke test

**Goal:** Lock in that the post-SP5 output kernel JIT-compiles with the reduced template arg list and produces finite, deterministic output via the full convolution path. Catches the case where a stale Tfast branch or VW>1 read path was missed in Task 3/4.

**Files:**
- Modify: `cpp/tests/testnn.cpp`

- [ ] **Step 1: Add the test**

Insert into `runMLXWinogradTests` (find with `grep -n "void runMLXWinogradTests\b" cpp/tests/testnn.cpp`):

```cpp
{
  // SP5 Task 9 — Output kernel is monomorphic on VW=1, GRID_ORDER=Cfast.
  // Run a full conv via winogradConv2d with a deterministic input and weight
  // tensor; assert the output is finite and matches a stable reference
  // checksum (sum of absolute values to 4 decimal places). This catches:
  //   - stale Tfast read paths in the output kernel
  //   - stale VW>1 vector-load paths
  //   - Std-only weight layout not consistent with kernel reads
  namespace mx = mlx::core;
  using namespace MLXWinograd;

  const int N = 1, H = 8, W = 8, Cin = 8, Cout = 8;
  const int Ntiles = N * ((H + 1) / 2) * ((W + 1) / 2);  // = 16

  // Deterministic input: i*0.01.
  std::vector<float> inData(N * H * W * Cin);
  for(size_t i = 0; i < inData.size(); i++) inData[i] = (float)i * 0.01f;
  mx::array input(inData.data(), {N, H, W, Cin}, mx::float32);

  // Deterministic 3x3 weights: (oc*Cin*9 + ic*9 + k)*0.001.
  std::vector<float> wData(Cout * Cin * 9);
  for(size_t i = 0; i < wData.size(); i++) wData[i] = (float)i * 0.001f;
  // makeWinogradWeights takes raw [Cout, Cin, 3, 3] and produces the
  // transformed [16, Cin, Cout] tensor (Std-only after Task 5).
  mx::array rawW(wData.data(), {Cout, Cin, 3, 3}, mx::float32);
  mx::array U = makeWinogradWeights(rawW);

  // Output config: Std post-SP5 OutputUntransform has tg0/tg1/wpt only.
  InputTransform inCfg{};
  inCfg.tg0 = 32; inCfg.tg1 = 1; inCfg.wpt = 1; inCfg.vw = 1;
  inCfg.gridOrder = GridOrder::Cfast;
  OutputUntransform outCfg{};
  outCfg.tg0 = 16; outCfg.tg1 = 4; outCfg.wpt = 1;

  mx::array out = winogradConv2d(input, U, Cout, inCfg, outCfg);
  mx::eval(out);

  // Output shape must be [N, H, W, Cout].
  testAssert(out.shape(0) == N);
  testAssert(out.shape(1) == H);
  testAssert(out.shape(2) == W);
  testAssert(out.shape(3) == Cout);

  // Pull data; assert all finite.
  std::vector<float> outData(out.size());
  out.eval();
  std::memcpy(outData.data(), out.data<float>(), outData.size() * sizeof(float));
  for(float v : outData) testAssert(std::isfinite(v));

  // Stable checksum: sum of absolute values to 4 decimal places. This is
  // a regression check — a change in numerics suggests a kernel-template
  // mismatch (e.g., output kernel reads channels via VW>1 path that no
  // longer exists, producing UB-flavored garbage).
  double sumAbs = 0.0;
  for(float v : outData) sumAbs += std::abs(v);
  // Recompute this expected value once after the test is first written —
  // it captures the deterministic conv result for the inputs above. The
  // test passes thereafter as a regression check, not a correctness check.
  // Tolerance: 0.5% to absorb minor reordering noise from MLX graph rewrites.
  double expectedSumAbs = -1.0;  // set on first run
  if(expectedSumAbs < 0) {
    // First run: print and skip the comparison so the developer can fill in.
    std::cout << "SP5 Task 9 first-run sumAbs = " << sumAbs << "\n";
  } else {
    testAssert(std::abs(sumAbs - expectedSumAbs) / expectedSumAbs < 0.005);
  }
}
```

- [ ] **Step 2: Build and run; capture the first-run sumAbs**

```bash
cd cpp && ninja
./katago runnnlayertests 2>&1 | grep -E "first-run sumAbs"
```
Expected: a line `SP5 Task 9 first-run sumAbs = <value>`. Copy that value.

- [ ] **Step 3: Hardcode the captured sumAbs**

Replace the `double expectedSumAbs = -1.0;` line with the captured value, e.g. `double expectedSumAbs = 32.871234;`. Re-build, re-run; the test now asserts.

- [ ] **Step 4: Build and run final**

```bash
cd cpp && ninja
./katago runnnlayertests
```
Expected: PASS — the assert fires and matches.

- [ ] **Step 5: Commit**

```bash
git add cpp/tests/testnn.cpp
git commit -m "SP5 Task 9: Output-kernel monomorphic smoke test

Runs winogradConv2d with deterministic input + weights through the full
post-SP5 path. Asserts shape, finiteness, and a stable sum-of-absolute-
values checksum at 0.5% tolerance. Catches stale Tfast or VW>1 paths
that escaped the Task 3/4 deletions.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Add gated flat-sweep convergence test

**Goal:** Verify the flat sweep finds an isValid winner whose timing beats any default-seed candidate. Gated by `KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST=1` because it's slow.

**Files:**
- Modify: `cpp/tests/testnn.cpp`

- [ ] **Step 1: Add the gated test**

Insert into `runMLXWinotunerTests` (find with `grep -n "void runMLXWinotunerTests\b" cpp/tests/testnn.cpp`):

```cpp
{
  // SP5 Task 10 — Gated flat-sweep convergence test.
  // Runs the production flat sweep on a small synthetic problem and asserts
  // that the winner is isValid and that its timing is no worse than the
  // SP1 baked default (tg0=32, tg1=1, wpt=1, vw=1, Cfast).
  const char* gate = std::getenv("KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST");
  if(gate != nullptr && std::string(gate) == "1") {
    MLXWinogradTuner::ModelInfoForTuning mi;
    mi.trunkNumChannels    = 64;
    mi.midNumChannels      = 64;
    mi.maxConvChannels3x3  = 64;
    mi.modelVersion        = 11;

    MLXWinogradTuneParams tuned = MLXWinogradTuner::loadOrAutoTune(
        /*tunerFile=*/"",  // empty → skip cache load/save
        /*homeDataDirOverride=*/"",
        /*gpuName=*/"AppleSilicon",
        /*nnXLen=*/19, /*nnYLen=*/19, /*batchSize=*/1,
        mi,
        /*logger=*/nullptr,
        /*full=*/false,
        /*reTune=*/true,
        /*useFP16=*/true);
    testAssert(tuned.isValid());

    // Score the baked default and the tuned winner via scoreInputTransform.
    // tuned.time <= baked.time (within noise).
    MLXWinograd::InputTransform baked{};
    baked.tg0 = 32; baked.tg1 = 1; baked.wpt = 1; baked.vw = 1;
    baked.gridOrder = MLXWinograd::GridOrder::Cfast;
    double bakedMs = MLXWinogradTuner::scoreInputTransformForTesting(
        baked, 1, 19, 19, mi, true);
    double tunedMs = MLXWinogradTuner::scoreInputTransformForTesting(
        tuned.inputTransform, 1, 19, 19, mi, true);
    // Allow 10% noise budget.
    testAssert(tunedMs <= bakedMs * 1.10);
  }
}
```

- [ ] **Step 2: Build and run (gated off — default)**

```bash
cd cpp && ninja
./katago runnnlayertests
```
Expected: PASS — gated test is skipped by default.

- [ ] **Step 3: Build and run (gated on)**

```bash
KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST=1 ./katago runnnlayertests
```
Expected: PASS — sweep completes in <120 s, returns isValid winner whose time is within 10% of baked default's time.

- [ ] **Step 4: Commit**

```bash
git add cpp/tests/testnn.cpp
git commit -m "SP5 Task 10: Gated flat-sweep convergence test

Runs the production flat sweep on C=64 synthetic input and asserts the
winner is isValid + at most 10% slower than the SP1 baked default. Gated
by KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST=1 because sweep takes ~60-90s.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Create bench_sp5_acceptance.sh; delete bench_sp4_acceptance.sh

**Goal:** Replace the SP4 acceptance harness with an SP5 version. Three sub-gates: paired-t perf parity vs SP4-fp16, cold-start wall-time under 120 s, accuracy via `testgpuerror`.

**Files:**
- Delete: `cpp/tools/bench_sp4_acceptance.sh`
- Create: `cpp/tools/bench_sp5_acceptance.sh`

- [ ] **Step 1: Create the new script**

```bash
cat > cpp/tools/bench_sp5_acceptance.sh <<'EOF'
#!/usr/bin/env bash
# SP5 acceptance gate: three sub-gates.
#
# Arm A: SP4-fp16 (pre-SP5 binary) vs SP5-fp16 (this binary). Paired-t test.
#         Pass: CI_lower(SP5 - SP4) >= -2% (SP5 not worse than SP4 by >2%).
# Wall-time: cold-start tuner with cache cleared via `trash` < 120s.
# Accuracy: testgpuerror with mlxUseFP16=true vs eigen reference, exit 0.
#
# Usage:
#   bench_sp5_acceptance.sh <sp4_katago> <sp5_katago> <model.bin.gz> <eigen_ref.json>
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $(basename "$0") <sp4_katago> <sp5_katago> <model.bin.gz> <eigen_ref.json>" >&2
  exit 2
fi

SP4_BIN="$1"; SP5_BIN="$2"; MODEL="$3"; EIGEN_REF="$4"
REPS="${5:-6}"; COOL="${6:-30}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$EIGEN_REF" ]]; then
  echo "FATAL: EIGEN_REF file not found: $EIGEN_REF" >&2
  exit 2
fi

# Arm A: SP4 vs SP5 paired-t.
echo "===== Arm A: SP4-fp16 vs SP5-fp16 (paired-t) ====="
ARM_A_LOG="$(mktemp)"
BENCH_A_LABEL=SP4Fp16 BENCH_B_LABEL=SP5Fp16 \
BENCH_A_FP16=1        BENCH_B_FP16=1 \
  "$HERE/bench_mlx_honest.sh" "$SP4_BIN" "$SP5_BIN" "$MODEL" "$REPS" "$COOL" \
  | tee "$ARM_A_LOG"
CI_A="$(grep -oE 'CI_lower=[+-][0-9]+\.[0-9]+' "$ARM_A_LOG" | tail -1 | cut -d= -f2)"
if [[ -z "$CI_A" ]]; then echo "FATAL: Arm A CI_lower not parsed"; exit 2; fi

# Wall-time gate.
echo "===== Wall-time: cold-start SP5 tune < 120s ====="
trash ~/.katago/mlxwinotuning/tunemlxwino3_*.txt 2>/dev/null || true
TUNE_START=$(date +%s)
"$SP5_BIN" benchmark -model "$MODEL" -config "$HERE/../configs/gtp_example.cfg" \
  -override-config "mlxUseFP16=true" -t 1 -v 100 -n 1 > /tmp/sp5_tune.log 2>&1
TUNE_END=$(date +%s)
TUNE_SECS=$((TUNE_END - TUNE_START))
echo "  Cold-start tune wall-time: ${TUNE_SECS}s"

# Accuracy.
echo "===== Accuracy: testgpuerror (mlxUseFP16 = true) ====="
ACC_LOG="$(mktemp)"
ACC_CFG="$(mktemp).cfg"
cp "$HERE/../configs/gtp_example.cfg" "$ACC_CFG"
sed -i.bak -E 's|^[#[:space:]]*mlxUseFP16[[:space:]]*=.*|mlxUseFP16 = true|' "$ACC_CFG"
rm -f "${ACC_CFG}.bak"
set +e
"$SP5_BIN" testgpuerror -model "$MODEL" -config "$ACC_CFG" -reference-file "$EIGEN_REF" \
  2>&1 | tee "$ACC_LOG"
ACC_EXIT=${PIPESTATUS[0]}
set -e

# Gate decisions.
PASS_A="$(awk -v c="$CI_A" 'BEGIN { print (c+0 >= -2.0) ? "PASS" : "FAIL" }')"
PASS_W=$([[ "$TUNE_SECS" -lt 120 ]] && echo "PASS" || echo "FAIL")
PASS_ACC=$([[ "$ACC_EXIT" == "0" ]] && echo "PASS" || echo "FAIL")

echo "==========================================="
echo "SP5 acceptance summary"
echo "  Arm A (SP5-fp16 - SP4-fp16) CI_lower = $CI_A   [$PASS_A]"
echo "  Wall-time: ${TUNE_SECS}s  [$PASS_W]"
echo "  Accuracy: testgpuerror exit = $ACC_EXIT   [$PASS_ACC]"
echo "==========================================="

if [[ "$PASS_A" == "PASS" && "$PASS_W" == "PASS" && "$PASS_ACC" == "PASS" ]]; then
  echo "OVERALL: PASS"
  exit 0
fi
echo "OVERALL: FAIL"
exit 1
EOF
chmod +x cpp/tools/bench_sp5_acceptance.sh
```

- [ ] **Step 2: Delete the SP4 acceptance script**

```bash
trash cpp/tools/bench_sp4_acceptance.sh
```

- [ ] **Step 3: Commit**

```bash
git add cpp/tools/bench_sp5_acceptance.sh
git rm cpp/tools/bench_sp4_acceptance.sh
git commit -m "SP5 Task 11: Replace bench_sp4_acceptance.sh with SP5 version

Three sub-gates: paired-t perf parity vs SP4 (CI_lower >= -2%),
cold-start wall-time (<120s, was 180s in SP4), accuracy via
testgpuerror.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: End-to-end build + acceptance gate

**Goal:** Clean build, run all unit tests including the gated sweep, run the acceptance gate. Final verification before merge.

- [ ] **Step 1: Clean rebuild**

```bash
cd cpp
trash CMakeCache.txt CMakeFiles/ build.ninja .ninja_deps .ninja_log 2>/dev/null || true
cmake -G Ninja -DUSE_BACKEND=MLX
ninja 2>&1 | tee /tmp/sp5_build.log
```
Expected: build succeeds with no warnings. Inspect `/tmp/sp5_build.log` for any `unused` or `MatmulOrient` references that should have been cleaned up.

- [ ] **Step 2: Run all unit tests**

```bash
./katago runtests
./katago runnnlayertests
KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST=1 ./katago runnnlayertests
```
Expected: PASS on all three commands.

- [ ] **Step 3: Build SP4 reference binary for paired comparison**

```bash
git stash push -m "sp5-uncommitted"
git checkout master  # or the SP4-tip commit hash, ideally cc6ba060^ (commit before SP5 spec)
cd cpp && ninja
cp katago /tmp/katago_sp4
git checkout feature/mlx-backend
git stash pop || true
ninja
```

- [ ] **Step 4: Generate Eigen reference (if not already present)**

If `cpp/eigen_reference_b18.json` is missing:
```bash
# Following the procedure in CLAUDE.md GPU Error Testing section
cd /tmp && git clone /Users/chinchangyang/Code/KataGo-MLX katago-eigen-build
cd katago-eigen-build/cpp
cmake -G Ninja -DUSE_BACKEND=EIGEN -DEIGEN3_INCLUDE_DIRS=/opt/homebrew/opt/eigen@3/include/eigen3
ninja
./katago testgpuerror -model ~/.katago/b18c384nbt-uec-20221121b.bin.gz \
  -config configs/gtp_example.cfg \
  -reference-file /Users/chinchangyang/Code/KataGo-MLX/cpp/eigen_reference_b18.json
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
```

Otherwise skip — use the existing `cpp/eigen_reference_b18.json`.

- [ ] **Step 5: Run acceptance gate**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./tools/bench_sp5_acceptance.sh \
  /tmp/katago_sp4 \
  ./katago \
  ~/.katago/b18c384nbt-uec-20221121b.bin.gz \
  cpp/eigen_reference_b18.json
```
Expected: `OVERALL: PASS`.

- [ ] **Step 6: Final commit (if any leftover changes)**

```bash
git status
# If clean, no commit needed. If there are leftover formatting changes:
git add -u
git commit -m "SP5 Task 12: Final cleanup after acceptance gate

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-review summary

**Spec coverage:**
- §Axes after SP5: Tasks 3 (output VW), 4 (output gridOrder), 5 (matmulOrient + Std-only weights), 6 (global gridOrder) cover all 3 axis deletions plus the redundant global.
- §Data model: Tasks 3-6 progressively shrink `MLXWinogradTuneParams` to the post-SP5 shape.
- §Kernel templates: Tasks 3-5 strip the template args.
- §Search algorithm: Tasks 1-2 add the flat sweep and switch the driver.
- §Cache schema v3: Task 7 bumps the version; Task 6 already shaped the format.
- §isValid invariants: Task 6 rewrites; Task 8 tests them.
- §Deletions list (all entries): covered by Tasks 2-6.
- §Additions list: Tasks 8 (v3 roundtrip + isValid), 9 (output-kernel monomorphic), 10 (flat-sweep convergence), 11 (acceptance script).
- §Tests retained: Tasks 3-5 leave input WPT/VW/Cfast-vs-Tfast/candidate-enumeration/isValid tests intact.
- §Validation strategy: Task 12 runs all four pre-merge gates.

**Placeholder scan:** None — every step has either concrete code, a concrete command, or a concrete file-location reference (with `grep` recipes for finding the exact line).

**Type consistency:** `InputTransform` keeps fields `tg0, tg1, wpt, vw, gridOrder` throughout. `OutputUntransform` progressively narrows: SP4 has 5 fields → after Task 3 has 4 (no vw) → after Task 4 has 3 (no gridOrder). `MLXWinogradTuneParams` progressively narrows: SP4 has 4 members → after Task 5 has 3 (no matmulOrient) → after Task 6 has 2 (no global gridOrder). All cross-task references match the in-task shape.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-21-mlx-winograd-tuner-simplification.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, two-stage review between tasks, fast iteration.

2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
