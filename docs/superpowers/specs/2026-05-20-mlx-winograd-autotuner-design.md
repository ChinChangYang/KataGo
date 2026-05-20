# SP2 — MLX Winograd Autotuner (Mirrors OpenCL)

**Date:** 2026-05-20
**Status:** Approved (design)
**Branch:** feature/mlx-backend
**Predecessor:** [SP1 — Custom Winograd F(2,3) fp32 Convolution Kernel](2026-05-19-mlx-winograd-fp32-conv-design.md)

## Context

SP1 delivered the three-stage MLX Winograd F(2,3) pipeline (input transform Metal
kernel → `mx::matmul` → output untransform Metal kernel) and proved MLX-fp32
beats the Metal/MPSGraph backend (529.79 ± 2.94 v/s vs 513.64 ± 5.21 v/s, +3.1 %,
CI-aware GATE PASS). The transform-kernel launch geometry `(tg0, tg1)` is
currently baked at `{32, 1}` — the value SP1 retrospectively cited as known-tuned,
but never empirically rediscovered on this machine, this net, this dim.

SP2's job is the search loop and the cache that makes the search amortise to
zero. SP3 (fp16) is a separate cycle.

The governing principle of SP2 is **mirror KataGo's proven OpenCL tuner pattern
to the letter wherever MLX's structure allows**. The OpenCL tuner has been
load-bearing across hundreds of GPUs for years; reinventing the search loop or
the cache layout buys nothing.

## Goal

Add an MLX-Winograd autotuner that, on first run per `(GPU, board dims, net)`:

1. Searches the launch-geometry space for the input-transform and
   output-untransform Metal kernels (independently, two grid searches).
2. Persists the winning configuration to a plain-text cache file under
   `<homeDataDir>/mlxwinotuning/`.
3. Subsequent runs load the cache instantly — no search.

Acceptance: the search converges from a deliberately-bad seed to a config whose
measured weighted-mean time is within 5 % of the SP1 baked default
`{tg0=32, tg1=1}` for each stage independently, and the end-to-end honest
benchmark `cpp/tools/bench_mlx_honest.sh` shows tuner-cached config ≥ SP1
baked-default visits/s (no regression).

## Design

### 1. Schema split — mirror `OpenCLTuneParams::Conv3x3Params`

SP1's single shared `WinogradConfig { int tg0, tg1, vec, axis, tileSize; }`
collapses into **two independent per-stage configs**, dropping the `vec`,
`axis`, and `tileSize` fields:

```cpp
// cpp/neuralnet/mlxwinotuner.h
namespace MLXWinogradParams {
  struct InputTransform   { int tg0 = 32; int tg1 = 1; };  // 2-D launch
  struct OutputUntransform { int tg0 = 32; int tg1 = 1; }; // 2-D launch
}

struct MLXWinogradTuneParams {
  MLXWinogradParams::InputTransform    inputTransform;
  MLXWinogradParams::OutputUntransform outputUntransform;
  bool isValid() const;
  static void save(const std::string& filename, const MLXWinogradTuneParams& params);
  static MLXWinogradTuneParams load(const std::string& filename);
};
```

**`vec`, `axis`, `tileSize` removed because:**
- OpenCL's Winograd tuner doesn't search them either — they're macro-baked into
  the kernel source. SP1 named them as "template_arg seams" but only ever
  implemented the `axis=1, vec=1` channel-fast scalar path. Removing them is
  dead-code cleanup, not regression.
- `tileSize=4` is structural (F(2,3) was ratified in SP1 §3 for numerical
  stability ahead of SP3 fp16). F(4,3) remains a deferred future cycle.

**Validity:** `tg0 * tg1 ≤ 1024` (Metal threadgroup-thread cap, identical to
OpenCL's check at `opencltuner.cpp:424–425`).

**Divergence from OpenCL — flagged explicitly:** OpenCL's
`untransLocalSize0/1/2` is a 3-D launch; the MLX SP1 output kernel uses a 1-D
launch with the third grid dim hard-coded to 1. SP2 keeps that 1-D launch and
searches a 2-D output space; rewriting the output kernel to 3-D is deferred to a
future cycle if profiling shows the 2-D launch leaves performance on the table.

### 2. Search space — mirror OpenCL line-for-line

Lifted verbatim from `cpp/neuralnet/opencltuner.cpp:2101–2106` (input) and
`:2268–2275` (output). A `-full` mode and a default non-`full` mode, identical
nomenclature to OpenCL's tuner:

**Input transform candidate values:**

| Mode      | `tg0`                       | `tg1`                  | Raw | After `tg0·tg1 ≤ 1024` |
|-----------|-----------------------------|------------------------|-----|------------------------|
| non-full  | `{1,2,4,8,16,32,64,128}`    | `{1,2,4,8,16,32}`      | 48  | **45**                 |
| `full`    | `{1,2,4,8,16,32,64,128}`    | `{1,2,4,8,16,32,64}`   | 56  | **50**                 |

**Output untransform candidate values** (2-D analog of OpenCL's 3-D, `tg2`
dropped):

| Mode      | `tg0`                       | `tg1`                  | Raw | After validity         |
|-----------|-----------------------------|------------------------|-----|------------------------|
| non-full  | `{1,2,8,16,32}`             | `{1,2,4,16,32}`        | 25  | **25**                 |
| `full`    | `{1,2,4,8,16,32,64}`        | `{1,2,4,8,16,32,64}`   | 49  | **46**                 |

**Default (non-full): 45 + 25 = 70 timed configs.** Full mode: 96.

### 3. Search strategy — exhaustive grid (mirror OpenCL)

Per stage, independently:

1. Build cartesian of the stage's candidate values.
2. `filterConfigs(ISVALID)` — drop pairs with `tg0·tg1 > 1024`.
3. `shuffleConfigs` — randomize order so thermal drift doesn't bias the
   ordering.
4. Prepend `currentConfig` (initially the baked default `{32, 1}`) as the
   reference baseline; it gets timed twice and acts as the consistency anchor.
5. Time each survivor: **20 reps** with rotation across `{trunkNumChannels,
   midNumChannels, maxConvChannels3x3}`, **first call as warmup (weight = 0)**,
   remaining 19 weighted into a mean-time score. Mirrors
   `opencltuner.cpp:2172–2206` precisely.
6. Per-candidate correctness check: outputs compared against the *current GPU
   reference config*'s outputs (no CPU oracle for the transforms — mirror
   OpenCL `:2121`).
7. Winner = lowest weighted-mean time among configs that pass the consistency
   check.

This is **not** coordinate descent. KataGo OpenCL does an exhaustive cartesian
sweep of the listed candidate values; SP2 mirrors that exactly. The non-full
default is sized to keep first-run tuning bounded at tens of seconds per `(GPU,
dims, model)` tuple, not minutes.

### 4. Cache file — plain-text key/value, OpenCL pattern

**Location:** `<homeDataDir>/mlxwinotuning/`, where `homeDataDir` is resolved by
`HomeData::getHomeDataDir()` (same mechanism the OpenCL backend uses; default
`~/.katago/`, overridable via the `homeDataDir` cfg key). Mirrors
`opencltuning/`.

**Filename:**
```
tunemlxwino<TUNER_VERSION>_gpu<cleanGpuName>_x<X>_y<Y>_c<Ctrunk>_mv<modelVersion>.txt
```

`cleanGpuName` filters to `[A-Za-z0-9]` only — same recipe as
`OpenCLTuner::defaultFileName` at `opencltuner.cpp:3186–3192`. One file per
`(GPU, board dims, model)` tuple — coexistence handled by the filesystem, not
by a record list.

**Contents** (mirror OpenCL `VERSION` + `#comment` + value-line layout, with
`.desc()`/`fillFromDesc` for the per-stage records):

```
VERSION=1
#inputTransform
tg0=32 tg1=1
#outputUntransform
tg0=32 tg1=1
```

Save via `ofstream` (opened with `FileUtils::open`); load via
`FileUtils::readFileLines` + `Global::stripComments` + `Global::trim` +
`fillFromDesc` parsing of `KEY=VALUE` pairs. All utilities already linked into
the MLX backend; **no new JSON dependency** is pulled in.

Version-gated: `VERSION=1` line at top; mismatch on load → `throw IOError(...)`
→ caller falls through to retune-and-overwrite. Identical to
`OpenCLTuneParams::load` at `opencltuner.cpp:624–639`.

### 5. API shape — mirror `OpenCLTuner`

```cpp
// cpp/neuralnet/mlxwinotuner.h
struct MLXWinogradTuner {
  static std::string defaultDirectory(bool makeDir,
                                      const std::string& homeDataDirOverride);
  static std::string defaultFileName(const std::string& gpuName,
                                     int nnXLen, int nnYLen,
                                     int trunkNumChannels, int modelVersion);

  struct ModelInfoForTuning {
    int trunkNumChannels;
    int midNumChannels;
    int maxConvChannels3x3;
    int modelVersion;
  };

  static MLXWinogradTuneParams loadOrAutoTune(
    std::string tunerFile,                       // empty → derive from defaults
    const std::string& homeDataDirOverride,
    const std::string& gpuName,
    int nnXLen, int nnYLen, int batchSize,
    ModelInfoForTuning modelInfo,
    Logger* logger,
    bool full,                                   // non-full default ranges; true → wider grid
    bool reTune                                  // force retune even if cache exists
  );
};
```

`loadOrAutoTune` flow (identical to `OpenCLTuner::loadOrAutoTune` at
`opencltuner.cpp:3212–3315`):
1. If an explicit `tunerFile` was passed → load it directly (parse/version error
   throws; loud failure, no silent fallback).
2. Else compute the default path; if the file exists and parses cleanly → use
   it.
3. Else log "Performing autotuning for MLX Winograd transforms…", run input
   grid search, then output grid search, persist to the default path, return.

### 6. Integration — wiring into `mlxbackend.cpp`

Tuner runs **inside `Model` ctor**, after weight load, before `mx::compile`,
once per `Model` instance. Tuned params thread through:

```
Model ctor → loadOrAutoTune → MLXWinogradTuneParams → ConvLayer → winogradConv2d(input, Uw, Cout, inCfg, outCfg)
```

`winogradConv2d`'s signature changes from `(input, Uw, Cout, WinogradConfig)` to
`(input, Uw, Cout, InputTransform, OutputUntransform)`. The two Metal kernels'
launch parameters in `mlxwinograd.h` consume the respective per-stage configs;
no kernel-source changes (already `axis=1, vec=1` scalar paths).

The `ComputeHandle::makeCacheKey` discriminator appended in SP1 (`-wg`/`-nowg`)
extends to include the tuned `tg0/tg1` quadruple so `mx::compile` caches the
correct specialized graph per tuned config.

**Env-var safety valves** (consistent with SP1's `KATAGO_MLX_WINOGRAD=0`
no-cfg-plumbing pattern):

- `KATAGO_MLX_WINOTUNER=0` → skip tuning entirely; use baked defaults
  `{tg0=32, tg1=1}` for both stages. A/B safety net.
- `KATAGO_MLX_WINOTUNER_FORCE=1` → ignore cache file; retune and overwrite.
- `KATAGO_MLX_WINOTUNER_FULL=1` → use the `full` candidate-value ranges (96
  configs) instead of the non-full default (70).

### 7. Acceptance gate

`Tests::runMLXWinotunerTests()`, called from `runnnlayertests`:

1. **Search-works test (per stage)** — verifies the search actually runs and
   picks well, not that it "converges" (exhaustive grid doesn't converge — it
   visits every candidate regardless of seed). The grid already contains
   `{tg0=32, tg1=1}` by construction, so a single assertion against the optimum's
   time would be satisfiable by a broken search that only times the baseline.
   Two independent assertions instead:

   a. **Beats the bad seed by ≥ 2×.** Seed `currentConfig` at the deliberately
      bad `{tg0=1, tg1=32}` for each stage; run the grid search; independently
      measure `time({tg0=1, tg1=32})` outside the tuner (so the assertion
      doesn't depend on the tuner's own measurement plumbing being correct);
      independently measure `time(tunerResult)` the same way. Assert
      `time(tunerResult) ≤ 0.5 × time({tg0=1, tg1=32})`. This fails if the
      search returns `currentConfig` unchanged (the most common kind of broken
      search loop — silent compile/validity errors, dropped candidates, etc.).

   b. **Within 5 % of the known optimum.** Independently measure
      `time({tg0=32, tg1=1})`. Assert `time(tunerResult) ≤ 1.05 ×
      time({tg0=32, tg1=1})`. This fails if the search picks a random
      mid-grid config rather than the fastest. The 5 % band allows for ties
      and run-to-run noise.

   Both assertions must hold per stage. A broken-only-times-baseline search
   fails (a); a broken-picks-random search fails (b); only a correct search
   passes both.
2. **File round-trip test:** instantiate `MLXWinogradTuneParams` with non-default
   values, `save(tmpfile)`, `load(tmpfile)`, assert exact field equality. Then
   write a corrupted `VERSION=999` file and assert `load` throws `IOError`.
3. **End-to-end honest re-run:** delete any cache file under
   `<homeDataDir>/mlxwinotuning/`, run `cpp/tools/bench_mlx_honest.sh`, assert
   MLX-fp32-with-tuner ≥ Metal AND ≥ SP1 baked-default visits/s. The harness's
   CI-aware gate semantics from SP1 apply unchanged.

### 8. Files

- **`cpp/neuralnet/mlxwinograd.h`** — Modify. Drop `vec`/`axis`/`tileSize` from
  `WinogradConfig`; split into per-stage `InputTransform`/`OutputUntransform`
  structs; update `winogradConv2d` signature. Kernel sources stay as-is
  (already `axis=1, vec=1`).
- **`cpp/neuralnet/mlxwinotuner.h`** — Create. `MLXWinogradTuneParams`,
  `MLXWinogradTuner::loadOrAutoTune`, `defaultFileName`, `defaultDirectory`,
  `ModelInfoForTuning`. Mirrors `OpenCLTuner` API shape.
- **`cpp/neuralnet/mlxwinotuner.cpp`** — Create. Two grid searches with
  shuffle + reference baseline; per-config measurement (20 reps, channel
  rotation, warmup-discard); plain-text save/load (`.desc()`/`fillFromDesc`
  pattern); validity filter.
- **`cpp/neuralnet/mlxbackend.cpp`** — Modify. Call `loadOrAutoTune` in `Model`
  ctor; thread tuned params through `ConvLayer` → `winogradConv2d`; env-var
  gates; extend `makeCacheKey` discriminator.
- **`cpp/CMakeLists.txt`** — Modify. Add `mlxwinotuner.{h,cpp}` to MLX backend
  sources.
- **`cpp/tests/testnn.cpp`** — Modify. `Tests::runMLXWinotunerTests()` —
  search-converges + file round-trip.
- **`cpp/tests/tests.h`** — Modify. Declare `runMLXWinotunerTests()`.

### 9. Non-goals (explicitly out of SP2)

- `vec` and `axis` as runtime knobs — dead seams removed, not promoted.
- F(4,3) tile size — deferred (SP1 §7).
- 3-D output untransform launch — deliberately diverged from OpenCL; future
  cycle if profiling shows headroom.
- fp16 — SP3.
- `mx::matmul` tuning — already hand-tuned by MLX.
- Cross-machine cache sharing — one file per (GPU, dims, model) on the local
  filesystem; mirrors OpenCL.
- A `tunewinograd` subcommand. SP2 is "auto-tune on first run, then cache" per
  user choice. A standalone command is not needed for the autotune-on-miss flow.
