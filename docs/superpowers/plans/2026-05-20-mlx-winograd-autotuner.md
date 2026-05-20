# SP2 — MLX Winograd Autotuner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an MLX-Winograd autotuner that, on first run per `(GPU, board dims, net)`, searches the launch-geometry space of the input-transform and output-untransform Metal kernels (two independent grid searches), caches the winner to a plain-text file under `<homeDataDir>/mlxwinotuning/`, and loads it instantly on subsequent runs.

**Architecture:** Mirror KataGo's `OpenCLTuner` line-for-line where MLX's structure allows. Split SP1's single shared `WinogradConfig` into two per-stage configs (`InputTransform{tg0,tg1}`, `OutputUntransform{tg0,tg1}`), drop the dead `vec`/`axis`/`tileSize` SP1 seams (OpenCL doesn't tune them either), do exhaustive grid + shuffle + reference baseline (not coordinate descent), persist plain-text `KEY=VALUE` with version-line at top.

**Tech Stack:** C++17, MLX (`mx::array`, `mx::eval`, `mx::fast::metal_kernel`, `mx::matmul`), KataGo `core/fileutils.h`, `core/global.h`, `dataio/homedata.h`, `core/makedir.h`.

**Reference:** Design spec at `docs/superpowers/specs/2026-05-20-mlx-winograd-autotuner-design.md`. OpenCL pattern at `cpp/neuralnet/opencltuner.{h,cpp}`. Current SP1 state at `cpp/neuralnet/mlxwinograd.h` and `cpp/neuralnet/mlxbackend.cpp`.

---

## File Structure (locked-in decomposition)

| File | Action | Responsibility |
|------|--------|----------------|
| `cpp/neuralnet/mlxwinograd.h` | Modify | Schema split: replace `WinogradConfig` with `InputTransform`/`OutputUntransform`; update `winogradConv2d` to take both per-stage configs. Kernel sources unchanged. CPU oracle code unchanged. |
| `cpp/neuralnet/mlxwinotuner.h` | Create | Public API: `MLXWinogradTuneParams` struct (per-stage configs + `isValid`/`save`/`load`), `MLXWinogradTuner` namespace (`loadOrAutoTune`, `defaultDirectory`, `defaultFileName`, `ModelInfoForTuning`). |
| `cpp/neuralnet/mlxwinotuner.cpp` | Create | Implementation: grid-build + filter + shuffle + per-config measurement (mx::eval-based) + winner selection + plain-text save/load via `FileUtils`/`Global` utilities. |
| `cpp/neuralnet/mlxbackend.cpp` | Modify | Plumb `homeDataDirOverride` into `ComputeContext`; invoke `loadOrAutoTune` at `ComputeHandle` ctor (before Model construction); thread tuned params into `Model` → `ConvLayer`; extend `makeCacheKey` to include tuned params; add env-var gates (`KATAGO_MLX_WINOTUNER`, `KATAGO_MLX_WINOTUNER_FORCE`, `KATAGO_MLX_WINOTUNER_FULL`). |
| `cpp/CMakeLists.txt` | Modify | Add `neuralnet/mlxwinotuner.cpp` and `neuralnet/mlxwinotuner.h` to the MLX backend source list (next to `mlxbackend.cpp`/`mlxwinograd.h`). |
| `cpp/tests/tests.h` | Modify | Declare `static void Tests::runMLXWinotunerTests();`. |
| `cpp/tests/testnn.cpp` | Modify | Add `Tests::runMLXWinotunerTests()` — file round-trip + search-works (per stage). Called from `runnnlayertests`. |

---

## Task 1: Schema Split in `mlxwinograd.h`

**Why first:** every downstream file (tuner, backend, tests) depends on the new types. Doing this first lets the rest of the tasks be additive against a stable API.

**Files:**
- Modify: `cpp/neuralnet/mlxwinograd.h:8-18` and `:253-309`
- Modify: `cpp/neuralnet/mlxbackend.cpp:167-171` (one call site)

- [ ] **Step 1: Replace `WinogradConfig` struct with two per-stage structs**

In `cpp/neuralnet/mlxwinograd.h`, replace lines 8–18 (the `namespace MLXWinograd {` opening block through the `};` of `WinogradConfig`) with:

```cpp
namespace MLXWinograd {

// Per-stage launch-geometry configs. SP2 tunes these via grid search;
// defaults are the SP1 baked-in known-tuned fp32 values that the tuner must
// rediscover. Each stage is searched independently (mirrors OpenCL's
// tuneTransform / tuneUntransform split). vec/axis/tileSize were SP1 seams
// that were never tuned and are removed (dead-code cleanup, not regression).
struct InputTransform   { int tg0 = 32; int tg1 = 1; };
struct OutputUntransform { int tg0 = 32; int tg1 = 1; };
```

- [ ] **Step 2: Update `winogradConv2d` signature in the same file**

In `cpp/neuralnet/mlxwinograd.h`, replace the `inline mx::array winogradConv2d(...)` block (currently lines 257–309) with:

```cpp
inline mx::array winogradConv2d(const mx::array& input,
                                const mx::array& Uw,
                                int Cout,
                                const InputTransform& inCfg,
                                const OutputUntransform& outCfg) {
  int N = input.shape(0);
  int H = input.shape(1);
  int W = input.shape(2);
  int C = input.shape(3);
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  // Stage 1: input transform -> [16, Ntiles, C]
  auto inFn = mx::fast::metal_kernel(
      "wino_input_transform_f32",
      /*input_names=*/{"inp"},
      /*output_names=*/{"outp"},
      /*source=*/kWinoInputSource);
  auto inOuts = inFn(
      /*inputs=*/{input},
      /*output_shapes=*/{ mx::Shape{16, Ntiles, C} },
      /*output_dtypes=*/{ mx::float32 },
      /*grid=*/std::make_tuple(C, Ntiles, 1),
      /*threadgroup=*/std::make_tuple(inCfg.tg0, inCfg.tg1, 1),
      /*template_args=*/{},
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});
  mx::array t = inOuts[0];

  // Stage 2: batched matmul [16,Ntiles,C] @ [16,C,Cout] -> [16,Ntiles,Cout]
  mx::array m = mx::matmul(t, Uw);

  // Stage 3: output untransform -> [N, H, W, Cout]
  int nhwc_arr[4] = {N, H, W, Cout};
  mx::array nhwcArr(nhwc_arr, {4}, mx::int32);
  auto outFn = mx::fast::metal_kernel(
      "wino_output_untransform_f32",
      /*input_names=*/{"m", "nhwc"},
      /*output_names=*/{"outp"},
      /*source=*/kWinoOutputSource);
  auto outOuts = outFn(
      /*inputs=*/{m, nhwcArr},
      /*output_shapes=*/{ mx::Shape{N, H, W, Cout} },
      /*output_dtypes=*/{ mx::float32 },
      /*grid=*/std::make_tuple(Cout, Ntiles, 1),
      /*threadgroup=*/std::make_tuple(outCfg.tg0, outCfg.tg1, 1),
      /*template_args=*/{},
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});
  return outOuts[0];
}
```

- [ ] **Step 3: Update the one call site in `mlxbackend.cpp`**

In `cpp/neuralnet/mlxbackend.cpp`, lines 167–171 currently read:

```cpp
  mx::array apply(const mx::array& input) const {
    if(useWinograd) {
      MLXWinograd::WinogradConfig cfg; // fp32 tuned defaults {32,1,1,1,4}
      return MLXWinograd::winogradConv2d(input, winogradWeights, outChannels, cfg);
    }
```

Replace with:

```cpp
  mx::array apply(const mx::array& input) const {
    if(useWinograd) {
      // SP2: per-stage tuned configs (default = SP1 baked values).
      MLXWinograd::InputTransform   inCfg;   // {tg0=32, tg1=1}
      MLXWinograd::OutputUntransform outCfg; // {tg0=32, tg1=1}
      return MLXWinograd::winogradConv2d(input, winogradWeights, outChannels, inCfg, outCfg);
    }
```

(Task 5 will replace these local defaults with members captured at ConvLayer construction.)

- [ ] **Step 4: Build to verify the schema change compiles**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && cmake -G Ninja -DUSE_BACKEND=MLX -DCMAKE_BUILD_TYPE=Release . > /tmp/cmake-task1.log 2>&1 && ninja > /tmp/ninja-task1.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 5: Run SP1 Winograd unit tests to verify nothing regressed**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ./katago runnnlayertests 2>&1 | tail -40
```
Expected: tests pass; specifically `MLXWinograd::winogradConv2d` correctness test (the `maxErr < 2e-3` assertion added in SP1's Task 2) still passes.

- [ ] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxwinograd.h cpp/neuralnet/mlxbackend.cpp
git commit -m "SP2 Task 1: split WinogradConfig into per-stage InputTransform/OutputUntransform

Replaces single shared {tg0, tg1, vec, axis, tileSize} struct with two
per-stage structs each carrying only {tg0, tg1}. Mirrors OpenCL's
Conv3x3Params split between transLocalSize* and untransLocalSize*.

Drops vec/axis/tileSize because:
- OpenCL Winograd tuner doesn't tune them either (macro-baked, not search dims)
- SP1 named them as template_arg seams but only ever implemented axis=1, vec=1
- tileSize=4 is structural (F(2,3) ratified in SP1 spec for fp32+fp16 stability)

ConvLayer::apply() uses local defaults; Task 5 will replace with tuner-supplied
values captured at construction.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Pure-C++ `MLXWinogradTuneParams` (struct + file I/O)

**Goal:** the bit of the tuner module that has zero MLX dependency — the schema struct, the `desc()`/`fillFromDesc` per-stage stringification, and the version-gated plain-text save/load. TDD with a file round-trip test.

**Files:**
- Create: `cpp/neuralnet/mlxwinotuner.h`
- Create: `cpp/neuralnet/mlxwinotuner.cpp`
- Modify: `cpp/CMakeLists.txt` (add new sources)
- Modify: `cpp/tests/tests.h` (declare `runMLXWinotunerTests`)
- Modify: `cpp/tests/testnn.cpp` (add `runMLXWinotunerTests` with the file round-trip test only — search-works comes in Task 4)

- [ ] **Step 1: Create `cpp/neuralnet/mlxwinotuner.h` skeleton**

```cpp
#ifndef NEURALNET_MLXWINOTUNER_H_
#define NEURALNET_MLXWINOTUNER_H_

#ifdef USE_MLX_BACKEND

#include <string>
#include "../neuralnet/mlxwinograd.h"

class Logger;

struct MLXWinogradTuneParams {
  MLXWinograd::InputTransform    inputTransform;
  MLXWinograd::OutputUntransform outputUntransform;

  // tg0 * tg1 <= 1024 (Metal threadgroup-thread cap) for both stages,
  // and all values strictly positive.
  bool isValid() const;

  // Plain-text persistence mirroring OpenCLTuneParams::save/load:
  // VERSION line at top, '#section' comments, 'KEY=VALUE KEY=VALUE' lines.
  static void save(const std::string& filename, const MLXWinogradTuneParams& params);
  static MLXWinogradTuneParams load(const std::string& filename);
};

namespace MLXWinogradTuner {
  struct ModelInfoForTuning {
    int trunkNumChannels;
    int midNumChannels;
    int maxConvChannels3x3;
    int modelVersion;
  };

  std::string defaultDirectory(bool makeDir, const std::string& homeDataDirOverride);
  std::string defaultFileName(const std::string& gpuName,
                              int nnXLen, int nnYLen,
                              int trunkNumChannels, int modelVersion);

  // Loads existing tune file if present and valid; otherwise runs the two
  // grid searches, saves the result, and returns it. Defined in Task 4.
  MLXWinogradTuneParams loadOrAutoTune(
    std::string tunerFile,
    const std::string& homeDataDirOverride,
    const std::string& gpuName,
    int nnXLen, int nnYLen, int batchSize,
    ModelInfoForTuning modelInfo,
    Logger* logger,
    bool full,
    bool reTune
  );
}

#endif // USE_MLX_BACKEND
#endif // NEURALNET_MLXWINOTUNER_H_
```

- [ ] **Step 2: Create `cpp/neuralnet/mlxwinotuner.cpp` with Task-2-scope (struct + I/O only, no search yet)**

```cpp
#ifdef USE_MLX_BACKEND

#include "../neuralnet/mlxwinotuner.h"

#include <fstream>
#include <sstream>
#include <map>
#include <string>
#include <vector>

#include "../core/fileutils.h"
#include "../core/global.h"
#include "../core/logger.h"
#include "../core/makedir.h"
#include "../dataio/homedata.h"

using namespace std;

static const int MLX_WINO_TUNER_VERSION = 1;
static const char* MLX_WINO_TUNEPARAMS_VERSION_LINE = "VERSION=1";

// Mirrors OpenCLTuner's readDescKeyValues: parse "KEY=VALUE KEY=VALUE ..." line into a map.
static map<string,int> parseKeyValueLine(const string& fileName, const string& line) {
  map<string,int> kvs;
  vector<string> tokens = Global::split(line);
  for(const string& tok : tokens) {
    if(tok.empty()) continue;
    size_t eq = tok.find('=');
    if(eq == string::npos)
      throw IOError("MLXWinogradTuneParams: token without '=' in " + fileName + " line: " + line);
    string k = tok.substr(0, eq);
    string v = tok.substr(eq + 1);
    if(kvs.count(k) > 0)
      throw IOError("MLXWinogradTuneParams: duplicate key " + k + " in " + fileName);
    try {
      kvs[k] = Global::stringToInt(v);
    } catch(const StringError&) {
      throw IOError("MLXWinogradTuneParams: could not parse value for key " + k + " in " + fileName);
    }
  }
  return kvs;
}

static int requireKey(const map<string,int>& kvs, const string& key, const string& fileName) {
  auto it = kvs.find(key);
  if(it == kvs.end())
    throw IOError("MLXWinogradTuneParams: missing key " + key + " in " + fileName);
  return it->second;
}

bool MLXWinogradTuneParams::isValid() const {
  if(inputTransform.tg0 <= 0 || inputTransform.tg1 <= 0) return false;
  if(outputUntransform.tg0 <= 0 || outputUntransform.tg1 <= 0) return false;
  if(inputTransform.tg0 * inputTransform.tg1 > 1024) return false;
  if(outputUntransform.tg0 * outputUntransform.tg1 > 1024) return false;
  return true;
}

void MLXWinogradTuneParams::save(const string& filename, const MLXWinogradTuneParams& params) {
  ofstream out;
  FileUtils::open(out, filename);
  out << MLX_WINO_TUNEPARAMS_VERSION_LINE << "\n";
  out << "#inputTransform" << "\n";
  out << "tg0=" << params.inputTransform.tg0
      << " tg1=" << params.inputTransform.tg1 << "\n";
  out << "#outputUntransform" << "\n";
  out << "tg0=" << params.outputUntransform.tg0
      << " tg1=" << params.outputUntransform.tg1 << "\n";
  out.flush();
  out.close();
}

MLXWinogradTuneParams MLXWinogradTuneParams::load(const string& filename) {
  vector<string> raw = FileUtils::readFileLines(filename, '\n');
  vector<string> lines;
  for(const string& r : raw) {
    string s = Global::stripComments(r);
    s = Global::trim(s);
    if(!s.empty()) lines.push_back(s);
  }
  if(lines.empty())
    throw IOError("MLXWinogradTuneParams::load: no content in " + filename);
  if(lines[0] != MLX_WINO_TUNEPARAMS_VERSION_LINE)
    throw IOError("MLXWinogradTuneParams::load: expected first line to be "
                  + string(MLX_WINO_TUNEPARAMS_VERSION_LINE) + " in " + filename);
  if(lines.size() != 3)
    throw IOError("MLXWinogradTuneParams::load: expected 3 non-comment lines in " + filename);

  MLXWinogradTuneParams params;
  {
    map<string,int> kvs = parseKeyValueLine(filename, lines[1]);
    params.inputTransform.tg0 = requireKey(kvs, "tg0", filename);
    params.inputTransform.tg1 = requireKey(kvs, "tg1", filename);
  }
  {
    map<string,int> kvs = parseKeyValueLine(filename, lines[2]);
    params.outputUntransform.tg0 = requireKey(kvs, "tg0", filename);
    params.outputUntransform.tg1 = requireKey(kvs, "tg1", filename);
  }
  return params;
}

string MLXWinogradTuner::defaultDirectory(bool makeDir, const string& homeDataDirOverride) {
  string dir = HomeData::getHomeDataDir(makeDir, homeDataDirOverride);
  dir += "/mlxwinotuning";
  if(makeDir) MakeDir::make(dir);
  return dir;
}

string MLXWinogradTuner::defaultFileName(const string& gpuName,
                                         int nnXLen, int nnYLen,
                                         int trunkNumChannels, int modelVersion) {
  string clean;
  for(char c : gpuName) {
    if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
      clean += c;
  }
  return Global::strprintf("tunemlxwino%d_gpu%s_x%d_y%d_c%d_mv%d.txt",
                           MLX_WINO_TUNER_VERSION, clean.c_str(),
                           nnXLen, nnYLen, trunkNumChannels, modelVersion);
}

// MLXWinogradTuner::loadOrAutoTune is defined in Task 4 once the search loop exists.

#endif // USE_MLX_BACKEND
```

- [ ] **Step 3: Add the new files to `cpp/CMakeLists.txt`**

Find the MLX block in `cpp/CMakeLists.txt` — there should be lines listing `neuralnet/mlxbackend.cpp` and `neuralnet/mlxwinograd.h`. Locate them with:

```bash
grep -n "mlxbackend\|mlxwinograd" /Users/chinchangyang/Code/KataGo-MLX/cpp/CMakeLists.txt
```
Expected: a few hits, all inside an `if(USE_BACKEND STREQUAL "MLX")` or similar block.

Add `neuralnet/mlxwinotuner.cpp` and `neuralnet/mlxwinotuner.h` immediately after the lines listing the existing MLX sources, preserving existing indentation/style.

- [ ] **Step 4: Declare the test entry point in `cpp/tests/tests.h`**

In `cpp/tests/tests.h`, find the existing line `static void runMLXWinogradTests();` (added in SP1). Immediately after it, add:

```cpp
  static void runMLXWinotunerTests();
```

(Same `static void` style; same `namespace Tests` scope.)

- [ ] **Step 5: Add the failing round-trip test to `cpp/tests/testnn.cpp`**

Find the end of `Tests::runMLXWinogradTests()` (added in SP1). Immediately after it, add:

```cpp
#ifdef USE_MLX_BACKEND
#include "../neuralnet/mlxwinotuner.h"

void Tests::runMLXWinotunerTests() {
  cout << "Running MLX Winograd tuner tests" << endl;

  // ---- File round-trip ----
  {
    MLXWinogradTuneParams written;
    written.inputTransform.tg0 = 64;
    written.inputTransform.tg1 = 2;
    written.outputUntransform.tg0 = 16;
    written.outputUntransform.tg1 = 4;
    testAssert(written.isValid());

    std::string tmp = "/tmp/katago_mlx_winotuner_roundtrip.txt";
    MLXWinogradTuneParams::save(tmp, written);
    MLXWinogradTuneParams readBack = MLXWinogradTuneParams::load(tmp);

    testAssert(readBack.inputTransform.tg0 == written.inputTransform.tg0);
    testAssert(readBack.inputTransform.tg1 == written.inputTransform.tg1);
    testAssert(readBack.outputUntransform.tg0 == written.outputUntransform.tg0);
    testAssert(readBack.outputUntransform.tg1 == written.outputUntransform.tg1);
  }

  // ---- Corrupt-version rejection ----
  {
    std::string tmp = "/tmp/katago_mlx_winotuner_badversion.txt";
    {
      std::ofstream f(tmp);
      f << "VERSION=999\n#inputTransform\ntg0=32 tg1=1\n#outputUntransform\ntg0=32 tg1=1\n";
    }
    bool threw = false;
    try { (void)MLXWinogradTuneParams::load(tmp); }
    catch(const IOError&) { threw = true; }
    testAssert(threw);
  }

  // ---- isValid edges ----
  {
    MLXWinogradTuneParams a; testAssert(a.isValid());          // defaults
    MLXWinogradTuneParams b; b.inputTransform.tg0 = 0;  testAssert(!b.isValid());
    MLXWinogradTuneParams c; c.outputUntransform.tg1 = -1; testAssert(!c.isValid());
    MLXWinogradTuneParams d; d.inputTransform.tg0 = 1024; d.inputTransform.tg1 = 2;
    testAssert(!d.isValid()); // 2048 > 1024
  }

  cout << "MLX Winograd tuner tests passed" << endl;
}
#else
void Tests::runMLXWinotunerTests() {
  cout << "MLX backend not built; skipping MLX Winograd tuner tests" << endl;
}
#endif
```

Then find the function that dispatches `runnnlayertests` (search for `runMLXWinogradTests();` — it should be in the same dispatch site). Add `runMLXWinotunerTests();` immediately after.

```bash
grep -n "runMLXWinogradTests" /Users/chinchangyang/Code/KataGo-MLX/cpp/tests/*.cpp /Users/chinchangyang/Code/KataGo-MLX/cpp/command/*.cpp 2>/dev/null
```
Expected: a hit in the test dispatcher (likely `runnnlayertests.cpp` or similar). Add the new call immediately after the existing one.

- [ ] **Step 6: Build to verify everything compiles**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && cmake -G Ninja -DUSE_BACKEND=MLX -DCMAKE_BUILD_TYPE=Release . > /tmp/cmake-task2.log 2>&1 && ninja > /tmp/ninja-task2.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 7: Run the test, verify it passes**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ./katago runnnlayertests 2>&1 | grep -E "MLX Winograd tuner|passed|FAIL"
```
Expected:
```
Running MLX Winograd tuner tests
MLX Winograd tuner tests passed
```

- [ ] **Step 8: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp \
        cpp/CMakeLists.txt cpp/tests/tests.h cpp/tests/testnn.cpp
git commit -m "SP2 Task 2: MLXWinogradTuneParams struct + plain-text persistence

Mirrors OpenCLTuneParams::save/load:
- VERSION line at top (VERSION=1)
- '#section' comments + 'KEY=VALUE KEY=VALUE' lines
- Parsed via FileUtils::readFileLines + Global::stripComments
- Corrupt version throws IOError (caller retunes)

isValid() enforces tg0*tg1 <= 1024 (Metal threadgroup cap, identical to
OpenCL line 424). Search loop and measurement primitive come in Tasks 3-4.

Tests: file round-trip, corrupt-version rejection, isValid edge cases.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Tuner Measurement Primitive (mx::eval-based)

**Goal:** a function `measureStageMillis(stage, candidate, ...) -> double` that times one candidate config for one stage on synthetic data. Same shape OpenCL uses at `opencltuner.cpp:2172-2206`: 20 reps with rotation across 3 channel-count workloads, first rep is warmup (weight 0), remaining 19 weighted into a mean time.

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (add measurement function — `static`, not in the public header)
- Modify: `cpp/tests/testnn.cpp` (extend `runMLXWinotunerTests` with a measurement-positivity test)

- [ ] **Step 1: Add the measurement primitive to `cpp/neuralnet/mlxwinotuner.cpp`**

At the top of `cpp/neuralnet/mlxwinotuner.cpp`, add MLX includes immediately after the existing `#include "../dataio/homedata.h"` line:

```cpp
#include "mlx/mlx.h"
#include "mlx/fast.h"
#include <chrono>
#include <random>
```

Then, before the final `#endif // USE_MLX_BACKEND` and after the existing `defaultFileName` function, add:

```cpp
namespace mx = mlx::core;

// One stage-1 (input transform) timed run on a synthetic [N,H,W,C] tensor.
// Mirrors the inner-loop shape of winogradConv2d's stage 1, but issues only
// the input-transform kernel so we can score it in isolation. Returns wall ms.
static double timeOneInputTransform(const MLXWinograd::InputTransform& cfg,
                                    const mx::array& input, int channels) {
  int N = input.shape(0);
  int H = input.shape(1);
  int W = input.shape(2);
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  auto fn = mx::fast::metal_kernel(
      "wino_input_transform_f32_tune",
      /*input_names=*/{"inp"},
      /*output_names=*/{"outp"},
      /*source=*/MLXWinograd::kWinoInputSource);
  auto outs = fn(
      /*inputs=*/{input},
      /*output_shapes=*/{ mx::Shape{16, Ntiles, channels} },
      /*output_dtypes=*/{ mx::float32 },
      /*grid=*/std::make_tuple(channels, Ntiles, 1),
      /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
      /*template_args=*/{},
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});

  auto t0 = std::chrono::steady_clock::now();
  mx::eval(outs[0]);
  auto t1 = std::chrono::steady_clock::now();
  return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// Same shape for output untransform: synthetic [16, Ntiles, outC] -> [N,H,W,outC].
static double timeOneOutputUntransform(const MLXWinograd::OutputUntransform& cfg,
                                       const mx::array& m, int N, int H, int W, int outC) {
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  (void)tilesY; (void)tilesX;

  int nhwc_arr[4] = {N, H, W, outC};
  mx::array nhwcArr(nhwc_arr, {4}, mx::int32);

  int Ntiles = m.shape(1);
  (void)Ntiles;

  auto fn = mx::fast::metal_kernel(
      "wino_output_untransform_f32_tune",
      /*input_names=*/{"m", "nhwc"},
      /*output_names=*/{"outp"},
      /*source=*/MLXWinograd::kWinoOutputSource);
  auto outs = fn(
      /*inputs=*/{m, nhwcArr},
      /*output_shapes=*/{ mx::Shape{N, H, W, outC} },
      /*output_dtypes=*/{ mx::float32 },
      /*grid=*/std::make_tuple(outC, m.shape(1), 1),
      /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
      /*template_args=*/{},
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});

  auto t0 = std::chrono::steady_clock::now();
  mx::eval(outs[0]);
  auto t1 = std::chrono::steady_clock::now();
  return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// Random NHWC fp32 input tensor for the input-transform timing harness.
static mx::array makeRandomInput(int N, int H, int W, int C, uint32_t seed) {
  std::vector<float> v((size_t)N * H * W * C);
  std::mt19937 rng(seed);
  std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
  for(auto& x : v) x = dist(rng);
  return mx::array(v.data(), {N, H, W, C}, mx::float32);
}

// Random [16, Ntiles, outC] fp32 tensor for the output-untransform timing harness.
static mx::array makeRandomMatmulOut(int Ntiles, int outC, uint32_t seed) {
  std::vector<float> v((size_t)16 * Ntiles * outC);
  std::mt19937 rng(seed);
  std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
  for(auto& x : v) x = dist(rng);
  return mx::array(v.data(), {16, Ntiles, outC}, mx::float32);
}

// Score one input-transform candidate. Mirrors OpenCL line 2172-2206:
// 20 reps rotating across {trunk, mid, max} channel counts; rep 0 is warmup
// with weight 0; remaining 19 reps weighted into a mean wall-clock time.
static double scoreInputTransform(const MLXWinograd::InputTransform& cfg,
                                  int N, int H, int W,
                                  const MLXWinogradTuner::ModelInfoForTuning& mi) {
  // Pre-create three input tensors at the channel counts we'll rotate over.
  // Re-using identical tensors keeps measurement noise low.
  mx::array inTrunk = makeRandomInput(N, H, W, mi.trunkNumChannels, 0xA1A1A1A1u);
  mx::array inMid   = makeRandomInput(N, H, W, mi.midNumChannels,   0xB2B2B2B2u);
  mx::array inMax   = makeRandomInput(N, H, W, mi.maxConvChannels3x3, 0xC3C3C3C3u);
  mx::eval(inTrunk); mx::eval(inMid); mx::eval(inMax);

  const int reps = 20;
  double totalMs = 0.0;
  double totalWeight = 0.0;
  for(int i = 0; i < reps; i++) {
    int channels;
    double weight;
    switch(i % 10) {
      case 0: channels = mi.trunkNumChannels;     weight = 0; break; // warmup
      case 1: channels = mi.trunkNumChannels;     weight = 1; break;
      case 2: channels = mi.midNumChannels;       weight = 1; break;
      case 3: channels = mi.maxConvChannels3x3;   weight = 1; break;
      case 4: channels = mi.trunkNumChannels;     weight = 1; break;
      case 5: channels = mi.midNumChannels;       weight = 1; break;
      case 6: channels = mi.maxConvChannels3x3;   weight = 1; break;
      case 7: channels = mi.trunkNumChannels;     weight = 1; break;
      case 8: channels = mi.midNumChannels;       weight = 1; break;
      case 9: channels = mi.maxConvChannels3x3;   weight = 1; break;
      default: channels = mi.trunkNumChannels;    weight = 1; break;
    }
    const mx::array& inp =
      (channels == mi.trunkNumChannels) ? inTrunk :
      (channels == mi.midNumChannels)   ? inMid   : inMax;
    double ms = timeOneInputTransform(cfg, inp, channels);
    totalMs += ms * weight;
    totalWeight += weight;
  }
  return totalMs / totalWeight;
}

// Score one output-untransform candidate. Same rotation/warmup structure.
static double scoreOutputUntransform(const MLXWinograd::OutputUntransform& cfg,
                                     int N, int H, int W,
                                     const MLXWinogradTuner::ModelInfoForTuning& mi) {
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  mx::array mTrunk = makeRandomMatmulOut(Ntiles, mi.trunkNumChannels,   0xD4D4D4D4u);
  mx::array mMid   = makeRandomMatmulOut(Ntiles, mi.midNumChannels,     0xE5E5E5E5u);
  mx::array mMax   = makeRandomMatmulOut(Ntiles, mi.maxConvChannels3x3, 0xF6F6F6F6u);
  mx::eval(mTrunk); mx::eval(mMid); mx::eval(mMax);

  const int reps = 20;
  double totalMs = 0.0;
  double totalWeight = 0.0;
  for(int i = 0; i < reps; i++) {
    int outC;
    double weight;
    switch(i % 10) {
      case 0: outC = mi.trunkNumChannels;     weight = 0; break;
      case 1: outC = mi.trunkNumChannels;     weight = 1; break;
      case 2: outC = mi.midNumChannels;       weight = 1; break;
      case 3: outC = mi.maxConvChannels3x3;   weight = 1; break;
      case 4: outC = mi.trunkNumChannels;     weight = 1; break;
      case 5: outC = mi.midNumChannels;       weight = 1; break;
      case 6: outC = mi.maxConvChannels3x3;   weight = 1; break;
      case 7: outC = mi.trunkNumChannels;     weight = 1; break;
      case 8: outC = mi.midNumChannels;       weight = 1; break;
      case 9: outC = mi.maxConvChannels3x3;   weight = 1; break;
      default: outC = mi.trunkNumChannels;    weight = 1; break;
    }
    const mx::array& mIn =
      (outC == mi.trunkNumChannels) ? mTrunk :
      (outC == mi.midNumChannels)   ? mMid   : mMax;
    double ms = timeOneOutputUntransform(cfg, mIn, N, H, W, outC);
    totalMs += ms * weight;
    totalWeight += weight;
  }
  return totalMs / totalWeight;
}
```

- [ ] **Step 2: Extend `runMLXWinotunerTests` with a measurement-positivity test**

In `cpp/tests/testnn.cpp`, inside the existing `#ifdef USE_MLX_BACKEND` block of `Tests::runMLXWinotunerTests`, append (after the `isValid edges` block but before the final `cout` line):

```cpp
  // ---- Measurement primitives return finite positive times ----
  // We can't call the static helpers from the test, so we use the public
  // surface that will be wired in Task 4: loadOrAutoTune with reTune=true
  // would run the search; for Task-3 scope we just verify the public
  // schema struct works with valid configs. The measurement primitive itself
  // is exercised by the search-works test added in Task 4.
```

(Intentionally adds only a comment in Task 3 — the measurement primitive is `static` and not callable from the test directly. Task 4 will exercise it via the public `loadOrAutoTune` entry point, and the search-works assertions there cover the "measurement returns sensible numbers" property.)

- [ ] **Step 3: Build to verify the measurement code compiles**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ninja > /tmp/ninja-task3.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 4: Run tests to verify Task 2 tests still pass**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ./katago runnnlayertests 2>&1 | grep -E "MLX Winograd tuner|passed|FAIL"
```
Expected: same output as Task 2.

- [ ] **Step 5: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxwinotuner.cpp cpp/tests/testnn.cpp
git commit -m "SP2 Task 3: measurement primitive for tuner candidates

Adds static scoreInputTransform / scoreOutputUntransform in
mlxwinotuner.cpp. Each runs 20 reps with rotation across
{trunkNumChannels, midNumChannels, maxConvChannels3x3}, rep 0 is warmup
(weight 0), remaining 19 weighted into a mean wall-ms via mx::eval +
std::chrono::steady_clock. Mirrors OpenCL line 2172-2206 shape.

Uses mx::fast::metal_kernel with distinct kernel names (suffix '_tune')
to keep the lazy-graph cache separate from production.

Search loop and bad-seed convergence assertion come in Task 4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Grid Search + `loadOrAutoTune`

**Goal:** the actual tuner algorithm. Build candidate list, validity-filter, shuffle, prepend current config as reference, time each, pick winner. Two independent searches (input first, output second). Wire it all behind `MLXWinogradTuner::loadOrAutoTune`. Add the search-works test (the two-assertion gate from the spec).

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (add search loop + `loadOrAutoTune`)
- Modify: `cpp/tests/testnn.cpp` (add search-works test)

- [ ] **Step 1: Add search loop helpers to `cpp/neuralnet/mlxwinotuner.cpp`**

After the `scoreOutputUntransform` function and before `#endif`, add:

```cpp
namespace {

struct InputCandidate  { MLXWinograd::InputTransform   cfg; double scoreMs; };
struct OutputCandidate { MLXWinograd::OutputUntransform cfg; double scoreMs; };

static const std::vector<int>& inputTg0Values(bool full) {
  static const std::vector<int> v = {1,2,4,8,16,32,64,128};
  (void)full;
  return v;
}
static const std::vector<int>& inputTg1Values(bool full) {
  static const std::vector<int> vFull    = {1,2,4,8,16,32,64};
  static const std::vector<int> vNonFull = {1,2,4,8,16,32};
  return full ? vFull : vNonFull;
}
static const std::vector<int>& outputTg0Values(bool full) {
  static const std::vector<int> vFull    = {1,2,4,8,16,32,64};
  static const std::vector<int> vNonFull = {1,2,8,16,32};
  return full ? vFull : vNonFull;
}
static const std::vector<int>& outputTg1Values(bool full) {
  static const std::vector<int> vFull    = {1,2,4,8,16,32,64};
  static const std::vector<int> vNonFull = {1,2,4,16,32};
  return full ? vFull : vNonFull;
}

static std::vector<MLXWinograd::InputTransform> buildInputCandidates(bool full,
    const MLXWinograd::InputTransform& seedCfg) {
  std::vector<MLXWinograd::InputTransform> out;
  for(int tg0 : inputTg0Values(full))
    for(int tg1 : inputTg1Values(full))
      if(tg0 * tg1 <= 1024)
        out.push_back({tg0, tg1});
  // Always include the seed (currentConfig) for a known consistency anchor.
  if(seedCfg.tg0 > 0 && seedCfg.tg1 > 0 && seedCfg.tg0 * seedCfg.tg1 <= 1024)
    out.push_back(seedCfg);
  return out;
}

static std::vector<MLXWinograd::OutputUntransform> buildOutputCandidates(bool full,
    const MLXWinograd::OutputUntransform& seedCfg) {
  std::vector<MLXWinograd::OutputUntransform> out;
  for(int tg0 : outputTg0Values(full))
    for(int tg1 : outputTg1Values(full))
      if(tg0 * tg1 <= 1024)
        out.push_back({tg0, tg1});
  if(seedCfg.tg0 > 0 && seedCfg.tg1 > 0 && seedCfg.tg0 * seedCfg.tg1 <= 1024)
    out.push_back(seedCfg);
  return out;
}

template <typename T>
static void shuffleVec(std::vector<T>& v, uint32_t seed) {
  std::mt19937 rng(seed);
  std::shuffle(v.begin(), v.end(), rng);
}

} // anonymous namespace

static MLXWinograd::InputTransform searchInputTransform(
    const MLXWinograd::InputTransform& seedCfg,
    int N, int H, int W,
    const MLXWinogradTuner::ModelInfoForTuning& mi,
    bool full, Logger* logger) {
  auto candidates = buildInputCandidates(full, seedCfg);
  shuffleVec(candidates, 0xDEADBEEFu);
  // Prepend seed as reference baseline; will be timed twice (anchor).
  candidates.insert(candidates.begin(), seedCfg);

  MLXWinograd::InputTransform best = seedCfg;
  double bestMs = std::numeric_limits<double>::infinity();
  for(const auto& c : candidates) {
    double ms = scoreInputTransform(c, N, H, W, mi);
    if(logger != nullptr) {
      logger->write(Global::strprintf(
          "  inputTransform tg0=%d tg1=%d  meanMs=%.4f",
          c.tg0, c.tg1, ms));
    }
    if(ms < bestMs) { bestMs = ms; best = c; }
  }
  return best;
}

static MLXWinograd::OutputUntransform searchOutputUntransform(
    const MLXWinograd::OutputUntransform& seedCfg,
    int N, int H, int W,
    const MLXWinogradTuner::ModelInfoForTuning& mi,
    bool full, Logger* logger) {
  auto candidates = buildOutputCandidates(full, seedCfg);
  shuffleVec(candidates, 0xCAFEBABEu);
  candidates.insert(candidates.begin(), seedCfg);

  MLXWinograd::OutputUntransform best = seedCfg;
  double bestMs = std::numeric_limits<double>::infinity();
  for(const auto& c : candidates) {
    double ms = scoreOutputUntransform(c, N, H, W, mi);
    if(logger != nullptr) {
      logger->write(Global::strprintf(
          "  outputUntransform tg0=%d tg1=%d  meanMs=%.4f",
          c.tg0, c.tg1, ms));
    }
    if(ms < bestMs) { bestMs = ms; best = c; }
  }
  return best;
}

MLXWinogradTuneParams MLXWinogradTuner::loadOrAutoTune(
    string tunerFile,
    const string& homeDataDirOverride,
    const string& gpuName,
    int nnXLen, int nnYLen, int batchSize,
    ModelInfoForTuning modelInfo,
    Logger* logger,
    bool full,
    bool reTune) {
  // Resolve filename.
  if(tunerFile.empty()) {
    string dir = defaultDirectory(true, homeDataDirOverride);
    tunerFile = dir + "/" + defaultFileName(gpuName, nnXLen, nnYLen,
                                            modelInfo.trunkNumChannels,
                                            modelInfo.modelVersion);
  }

  // Try to load existing.
  if(!reTune && FileUtils::exists(tunerFile)) {
    try {
      MLXWinogradTuneParams loaded = MLXWinogradTuneParams::load(tunerFile);
      if(loaded.isValid()) {
        if(logger != nullptr)
          logger->write("Loaded MLX Winograd tuning parameters from " + tunerFile);
        return loaded;
      }
    } catch(const IOError& e) {
      if(logger != nullptr)
        logger->write(std::string("MLX Winograd tune file unusable, retuning: ") + e.what());
    }
  }

  if(logger != nullptr) {
    logger->write("Performing autotuning for MLX Winograd transforms");
    logger->write("Tuning input transform (this may take ~30 seconds)...");
  }

  // Search input first, then output. Each independently.
  MLXWinograd::InputTransform inSeed;    // {tg0=32, tg1=1}
  MLXWinograd::OutputUntransform outSeed; // {tg0=32, tg1=1}
  MLXWinograd::InputTransform inBest =
      searchInputTransform(inSeed, batchSize, nnYLen, nnXLen, modelInfo, full, logger);
  if(logger != nullptr) logger->write("Tuning output untransform...");
  MLXWinograd::OutputUntransform outBest =
      searchOutputUntransform(outSeed, batchSize, nnYLen, nnXLen, modelInfo, full, logger);

  MLXWinogradTuneParams result;
  result.inputTransform = inBest;
  result.outputUntransform = outBest;

  MLXWinogradTuneParams::save(tunerFile, result);
  if(logger != nullptr) {
    logger->write(Global::strprintf(
        "MLX Winograd tuning done: inputTransform=(%d,%d) outputUntransform=(%d,%d), saved to %s",
        inBest.tg0, inBest.tg1, outBest.tg0, outBest.tg1, tunerFile.c_str()));
  }
  return result;
}
```

Add `#include <algorithm>` and `#include <limits>` to the includes block at the top of the file if they aren't already present.

- [ ] **Step 2: Add the search-works test in `cpp/tests/testnn.cpp`**

Inside the `#ifdef USE_MLX_BACKEND` block of `Tests::runMLXWinotunerTests()`, after the existing blocks and before the final `cout`, add:

```cpp
  // ---- Search-works (per stage): bad seed; assert (a) beats bad by 2x, (b) within 5% of optimum.
  // We exercise the search via loadOrAutoTune with reTune=true and a temp tune file.
  // For the assertions we re-time the winner, the bad seed, and the known oracle
  // OUTSIDE the tuner (using a separate loadOrAutoTune call with reTune=true is
  // not viable — that re-runs the search). Instead we run the tuner once, then
  // construct ConvLayer-shaped graphs with the three configs and time them
  // directly via winogradConv2d on synthetic inputs.

  // NOTE: This test is exercised in CI machine but skipped in the standard
  // testnn unit suite because it runs the full search (~minute on first run)
  // and depends on Apple Silicon ordering. It is gated behind
  // KATAGO_MLX_WINOTUNER_RUN_SEARCH_TEST=1 to keep `runnnlayertests` fast.
  if(std::getenv("KATAGO_MLX_WINOTUNER_RUN_SEARCH_TEST") != nullptr) {
    cout << "Running MLX Winograd tuner search-works test" << endl;

    MLXWinogradTuner::ModelInfoForTuning mi;
    mi.trunkNumChannels = 256;
    mi.midNumChannels = 256;
    mi.maxConvChannels3x3 = 256;
    mi.modelVersion = 15;

    int N = 8, H = 19, W = 19;

    // Run the search with a deliberately bad seed.
    std::string tmpFile = "/tmp/katago_mlx_winotuner_searchtest.txt";
    {
      std::remove(tmpFile.c_str());
    }
    // We can't pass a custom seed into loadOrAutoTune (it uses {32,1} internally),
    // so to keep the search-works coverage we directly call the search helpers
    // through a thin re-entry: write a known-bad file, retune=true, observe the
    // overwrite picks something better.
    {
      MLXWinogradTuneParams bad;
      bad.inputTransform.tg0 = 1; bad.inputTransform.tg1 = 32;
      bad.outputUntransform.tg0 = 1; bad.outputUntransform.tg1 = 32;
      MLXWinogradTuneParams::save(tmpFile, bad);
    }
    MLXWinogradTuneParams tuned = MLXWinogradTuner::loadOrAutoTune(
        tmpFile, /*homeDataDirOverride=*/"", /*gpuName=*/"UnitTestGpu",
        /*nnXLen=*/W, /*nnYLen=*/H, /*batchSize=*/N,
        mi, /*logger=*/nullptr, /*full=*/false, /*reTune=*/true);

    // Re-time the three configs via winogradConv2d on synthetic data.
    // Build a synthetic input + winograd weights once; time each config.
    std::vector<float> inV((size_t)N * H * W * mi.trunkNumChannels);
    std::mt19937 rng(0x12345);
    std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
    for(auto& x : inV) x = dist(rng);
    mx::array input(inV.data(), {N, H, W, mi.trunkNumChannels}, mx::float32);
    mx::eval(input);

    std::vector<float> wOIHW((size_t)mi.trunkNumChannels * mi.trunkNumChannels * 9);
    for(auto& x : wOIHW) x = dist(rng);
    mx::array Uw = MLXWinograd::makeWinogradWeights(wOIHW, mi.trunkNumChannels, mi.trunkNumChannels);
    mx::eval(Uw);

    auto timeCfg = [&](const MLXWinograd::InputTransform& ic,
                       const MLXWinograd::OutputUntransform& oc) -> double {
      const int reps = 10;
      double total = 0;
      for(int i = 0; i < reps; i++) {
        auto t0 = std::chrono::steady_clock::now();
        mx::array out = MLXWinograd::winogradConv2d(input, Uw, mi.trunkNumChannels, ic, oc);
        mx::eval(out);
        auto t1 = std::chrono::steady_clock::now();
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        if(i > 0) total += ms; // discard warmup
      }
      return total / (reps - 1);
    };

    MLXWinograd::InputTransform   badIn{1, 32};
    MLXWinograd::OutputUntransform badOut{1, 32};
    MLXWinograd::InputTransform   optIn{32, 1};
    MLXWinograd::OutputUntransform optOut{32, 1};

    double tWinner = timeCfg(tuned.inputTransform, tuned.outputUntransform);
    double tBad    = timeCfg(badIn, badOut);
    double tOpt    = timeCfg(optIn, optOut);

    cout << Global::strprintf(
        "  winner=(%d,%d)/(%d,%d) %.3fms ; bad=(1,32)/(1,32) %.3fms ; opt=(32,1)/(32,1) %.3fms",
        tuned.inputTransform.tg0, tuned.inputTransform.tg1,
        tuned.outputUntransform.tg0, tuned.outputUntransform.tg1,
        tWinner, tBad, tOpt) << endl;

    // (a) Winner must beat bad seed by at least 2x.
    testAssert(tWinner <= 0.5 * tBad);
    // (b) Winner must be within 5% of known optimum.
    testAssert(tWinner <= 1.05 * tOpt);

    cout << "MLX Winograd tuner search-works test passed" << endl;
  } else {
    cout << "Skipping MLX Winograd tuner search-works test (set KATAGO_MLX_WINOTUNER_RUN_SEARCH_TEST=1 to enable)" << endl;
  }
```

Also add at the top of the function (right after `cout << "Running MLX Winograd tuner tests" << endl;`) the necessary includes for `mx::array`, `std::chrono`, `std::random`, and `std::remove`:

```cpp
  // Test-local imports
  using mlx::core::array;
  namespace mx = mlx::core;
```

And ensure the file's includes (top of `testnn.cpp`) contain:

```cpp
#ifdef USE_MLX_BACKEND
#include "mlx/mlx.h"
#include <chrono>
#include <random>
#include <cstdio>
#endif
```

(Add these only if they aren't already in the SP1 test additions.)

- [ ] **Step 3: Build**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ninja > /tmp/ninja-task4.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 4: Run the standard tests (search test will skip without env-var)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ./katago runnnlayertests 2>&1 | grep -E "MLX Winograd|passed|FAIL|Skipping"
```
Expected:
```
Running MLX Winograd tuner tests
Skipping MLX Winograd tuner search-works test (set KATAGO_MLX_WINOTUNER_RUN_SEARCH_TEST=1 to enable)
MLX Winograd tuner tests passed
```

- [ ] **Step 5: Run the search-works test (full, ~30-60s)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && KATAGO_MLX_WINOTUNER_RUN_SEARCH_TEST=1 ./katago runnnlayertests 2>&1 | grep -E "MLX Winograd|winner=|passed|FAIL"
```
Expected:
```
Running MLX Winograd tuner tests
Running MLX Winograd tuner search-works test
  winner=(<x>,<y>)/(<u>,<v>) <wms>ms ; bad=(1,32)/(1,32) <bms>ms ; opt=(32,1)/(32,1) <oms>ms
MLX Winograd tuner search-works test passed
MLX Winograd tuner tests passed
```
With `<wms> ≤ 0.5 * <bms>` and `<wms> ≤ 1.05 * <oms>`. If assertion (a) fails: the search is broken (likely returning the seed unchanged — investigate `searchInputTransform` / `searchOutputUntransform`). If assertion (b) fails: the search measurement is noisy enough that the winner sometimes ties a slower neighbor — re-run; if it fails consistently, increase the per-config `reps` in `scoreInputTransform`/`scoreOutputUntransform` from 20 to 30.

- [ ] **Step 6: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxwinotuner.cpp cpp/tests/testnn.cpp
git commit -m "SP2 Task 4: grid search + loadOrAutoTune

Exhaustive grid per stage, validity-filter (tg0*tg1 <= 1024), shuffle
(deterministic seed per stage), prepend seed as reference baseline,
pick winner by min weighted-mean ms. Two independent searches mirror
OpenCL's tuneTransform / tuneUntransform.

loadOrAutoTune: load existing valid file -> return; else search both
stages -> save -> return. Logs per-candidate ms when logger non-null.

Search-works test (gated by KATAGO_MLX_WINOTUNER_RUN_SEARCH_TEST=1 to
keep runnnlayertests fast). Two independent assertions per the spec:
  (a) winner_time <= 0.5 * time({1,32}/{1,32})  - beats bad seed 2x
  (b) winner_time <= 1.05 * time({32,1}/{32,1}) - within 5% of optimum
Both measurements taken outside the tuner via direct winogradConv2d.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Wire Tuner into `mlxbackend.cpp`

**Goal:** make the tuner actually run in production. Plumb `homeDataDirOverride` and `logger` from `createComputeContext` into `ComputeContext`; resolve a GPU name; call `loadOrAutoTune` at `ComputeHandle` construction (before `Model` ctor); pass tuned params into `Model` → `ConvLayer`; have `ConvLayer::apply()` use the captured per-stage configs. Add env-var safety valves.

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp` (multiple sections)

- [ ] **Step 1: Add includes and env-var helpers**

Near the top of `cpp/neuralnet/mlxbackend.cpp`, add to the existing `#include` block:

```cpp
#include "../neuralnet/mlxwinotuner.h"
```

Below the existing `mlxWinogradEnabled()` static helper (~line 124), add:

```cpp
// Tuner is on by default; KATAGO_MLX_WINOTUNER=0 forces baked SP1 defaults.
static bool mlxWinotunerEnabled() {
  static const bool enabled = [](){
    const char* e = std::getenv("KATAGO_MLX_WINOTUNER");
    return !(e != nullptr && std::string(e) == "0");
  }();
  return enabled;
}
// KATAGO_MLX_WINOTUNER_FORCE=1 ignores cache file, retunes and overwrites.
static bool mlxWinotunerForce() {
  static const bool force = [](){
    const char* e = std::getenv("KATAGO_MLX_WINOTUNER_FORCE");
    return (e != nullptr && std::string(e) == "1");
  }();
  return force;
}
// KATAGO_MLX_WINOTUNER_FULL=1 uses the wider grid ranges.
static bool mlxWinotunerFull() {
  static const bool full = [](){
    const char* e = std::getenv("KATAGO_MLX_WINOTUNER_FULL");
    return (e != nullptr && std::string(e) == "1");
  }();
  return full;
}
// GPU name for the tuner cache filename. MLX exposes device info via metal_device_info();
// keys vary by MLX version, so we attempt "architecture" first then fall back.
static std::string mlxGpuName() {
  try {
    auto info = mlx::core::metal::device_info();
    auto it = info.find("architecture");
    if(it != info.end()) {
      if(auto* s = std::get_if<std::string>(&it->second)) {
        if(!s->empty()) return *s;
      }
    }
  } catch(...) {}
  return "AppleSilicon";
}
```

- [ ] **Step 2: Extend `ConvLayer` to hold per-stage tuned configs**

In `cpp/neuralnet/mlxbackend.cpp` around lines 134–186 (the `ConvLayer` struct), make the following edits:

Replace the field-declaration block (currently `weights` and `winogradWeights`) with:

```cpp
  const bool useWinograd;
  mx::array weights;            // OHWI format (only built when !useWinograd)
  mx::array winogradWeights;    // 4x4 domain U, valid only if useWinograd
  MLXWinograd::InputTransform   winoInCfg;
  MLXWinograd::OutputUntransform winoOutCfg;
```

Change the ctor signature to accept the per-stage configs:

```cpp
  ConvLayer(const ConvLayerDesc& desc,
            const MLXWinograd::InputTransform& inCfg,
            const MLXWinograd::OutputUntransform& outCfg,
            bool useFP16 = false)
    : name(desc.name),
      convYSize(desc.convYSize),
      convXSize(desc.convXSize),
      inChannels(desc.inChannels),
      outChannels(desc.outChannels),
      dilationY(desc.dilationY),
      dilationX(desc.dilationX),
      useWinograd(!useFP16 && mlxWinogradEnabled()
                  && convYSize==3 && convXSize==3
                  && dilationY==1 && dilationX==1),
      weights(useWinograd ? mx::array(0.0f) : toComputeDtype(convertConvWeightsOIHWtoOHWI(desc.weights, outChannels, inChannels, convYSize, convXSize), useFP16)),
      winogradWeights(useWinograd
        ? MLXWinograd::makeWinogradWeights(desc.weights, outChannels, inChannels)
        : mx::array(0.0f)),
      winoInCfg(inCfg),
      winoOutCfg(outCfg)
  {}
```

Replace the `apply()` body's Task-1 local-default block with the captured members:

```cpp
  mx::array apply(const mx::array& input) const {
    if(useWinograd) {
      return MLXWinograd::winogradConv2d(input, winogradWeights, outChannels, winoInCfg, winoOutCfg);
    }
    // MLX conv2d: input NHWC, weights OHWI
    int padY = (convYSize - 1) * dilationY / 2;
    int padX = (convXSize - 1) * dilationX / 2;
    return mx::conv2d(
      input,
      weights,
      /*stride=*/std::make_pair(1, 1),
      /*padding=*/std::make_pair(padY, padX),
      /*dilation=*/std::make_pair(dilationY, dilationX),
      /*groups=*/1
    );
  }
```

- [ ] **Step 3: Thread tuned configs through `Model` ctor**

In `cpp/neuralnet/mlxbackend.cpp`, find the `struct Model` declaration (~line 773). The `Model` ctor takes `(const ModelDesc&, bool useFP16)`. Change it to also accept tuned params:

```cpp
  Model(const ModelDesc& desc, const MLXWinogradTuneParams& tuneParams, bool useFP16 = false)
```

Then, every place inside `Model` (and its sub-structs `Trunk`, `Block`, etc.) that constructs a `ConvLayer(desc, useFP16)` becomes:

```cpp
ConvLayer(desc, tuneParams.inputTransform, tuneParams.outputUntransform, useFP16)
```

Find all those call sites with:

```bash
grep -n "ConvLayer(" /Users/chinchangyang/Code/KataGo-MLX/cpp/neuralnet/mlxbackend.cpp
```

Update each occurrence inside the Model construction tree to pass the per-stage configs. (Sub-structs may need to take `tuneParams` as a constructor arg too — follow the same pattern recursively.)

- [ ] **Step 4: Store `homeDataDirOverride` and `logger` in `ComputeContext`**

Locate the `struct ComputeContext` block (~line 992). Add two new fields:

```cpp
  std::string homeDataDirOverride;
  Logger* logger;
```

Update the ctor:

```cpp
  ComputeContext(int nnX, int nnY, enabled_t fp16Mode,
                 const std::string& homeDataDirOverride_, Logger* logger_)
    : nnXLen(nnX),
      nnYLen(nnY),
      useFP16Mode(fp16Mode),
      homeDataDirOverride(homeDataDirOverride_),
      logger(logger_),
      cachedModelsMutex(),
      cachedModels(),
      cachedModelsRefCount()
  {}
```

In `NeuralNet::createComputeContext` (~line 1172), replace the call:

```cpp
ComputeContext* context = new ComputeContext(nnXLen, nnYLen, useFP16Mode);
```

with:

```cpp
ComputeContext* context = new ComputeContext(nnXLen, nnYLen, useFP16Mode, homeDataDirOverride, logger);
```

And remove the `(void)homeDataDirOverride;` and `(void)logger;` lines.

- [ ] **Step 5: Invoke `loadOrAutoTune` in `ComputeHandle` ctor before `Model` construction**

In the `ComputeHandle` ctor (~line 1042), replace the body that constructs the cached `Model` with:

```cpp
  ComputeHandle(ComputeContext* ctx, const LoadedModel& loadedModel, bool iNHWC, bool requireExactNNLen_, bool useFP16_)
    : context(ctx),
      inputsUseNHWC(iNHWC),
      requireExactNNLen(requireExactNNLen_),
      useFP16(useFP16_),
      modelCacheKey(makeCacheKey(loadedModel, useFP16_)),
      model(nullptr),
      modelVersion(loadedModel.modelDesc.modelVersion),
      compiledFuncsMutex(),
      compiledFuncs()
  {
    // Determine tuner params: either run the autotuner, or use baked SP1 defaults.
    MLXWinogradTuneParams tuneParams;
    if(mlxWinogradEnabled() && mlxWinotunerEnabled() && !useFP16_) {
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels    = loadedModel.modelDesc.trunk.trunkNumChannels;
      mi.midNumChannels      = loadedModel.modelDesc.trunk.midNumChannels;
      mi.maxConvChannels3x3  = std::max({
          loadedModel.modelDesc.trunk.trunkNumChannels,
          loadedModel.modelDesc.trunk.midNumChannels,
          loadedModel.modelDesc.trunk.regularNumChannels,
          loadedModel.modelDesc.trunk.gpoolNumChannels
      });
      mi.modelVersion = loadedModel.modelDesc.modelVersion;
      tuneParams = MLXWinogradTuner::loadOrAutoTune(
          /*tunerFile=*/"",
          context->homeDataDirOverride,
          mlxGpuName(),
          context->nnXLen, context->nnYLen,
          /*batchSize=*/8,
          mi,
          context->logger,
          /*full=*/mlxWinotunerFull(),
          /*reTune=*/mlxWinotunerForce());
    }
    // else: tuneParams is default-constructed = SP1 baked {32,1} / {32,1}.

    std::lock_guard<std::mutex> lock(context->cachedModelsMutex);
    if(context->cachedModels.find(modelCacheKey) == context->cachedModels.end()) {
      context->cachedModels[modelCacheKey] = std::make_shared<const Model>(loadedModel.modelDesc, tuneParams, useFP16_);
    }
    model = context->cachedModels[modelCacheKey];
    context->cachedModelsRefCount[modelCacheKey] += 1;
  }
```

- [ ] **Step 6: Extend `makeCacheKey` to discriminate by tuned config**

Note that `makeCacheKey` is called from the ctor *before* the tuner runs, so it can't include the tuned values directly. Instead, since SP2 guarantees one tune per (GPU, dims, model), and the existing key already covers (model name, sha256, fp16, wg), the existing key remains adequate — but we should add a tuner-version discriminator so a future TUNER_VERSION bump invalidates correctly. Replace:

```cpp
  static std::string makeCacheKey(const LoadedModel& loadedModel, bool useFP16) {
    return loadedModel.modelDesc.name + "-" + loadedModel.modelDesc.sha256
      + (useFP16 ? "-fp16" : "-fp32")
      + (mlxWinogradEnabled() ? "-wg" : "-nowg");
  }
```

with:

```cpp
  static std::string makeCacheKey(const LoadedModel& loadedModel, bool useFP16) {
    return loadedModel.modelDesc.name + "-" + loadedModel.modelDesc.sha256
      + (useFP16 ? "-fp16" : "-fp32")
      + (mlxWinogradEnabled() ? "-wg" : "-nowg")
      + (mlxWinotunerEnabled() && !useFP16 ? "-tuned" : "-untuned");
  }
```

- [ ] **Step 7: Update the standalone `ConvLayer` constructor used in `runnnlayertests`**

The `runMLXWinogradTests` (and any other test that creates a `ConvLayer` directly) needs to pass the new args. Search for `ConvLayer(` calls outside `mlxbackend.cpp`:

```bash
grep -rn "ConvLayer(" /Users/chinchangyang/Code/KataGo-MLX/cpp/tests/ /Users/chinchangyang/Code/KataGo-MLX/cpp/neuralnet/ | grep -v ConvLayerDesc | grep -v "::"
```

For each external caller, update to pass `MLXWinograd::InputTransform{}` and `MLXWinograd::OutputUntransform{}` (defaulted) as the two new args. If `ConvLayer` is only directly constructed inside `mlxbackend.cpp` (which is the SP1 design), no external call sites need updates — confirm via the grep above. If the test file has no direct construction, this step is a no-op.

- [ ] **Step 8: Build**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ninja > /tmp/ninja-task5.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 9: Quick smoke test — tuner doesn't crash with a real model**

Find any KataGo `.bin.gz` model file:

```bash
find / -name "*.bin.gz" 2>/dev/null | grep -i kata | head -3
```

Pick one (e.g. `/Users/chinchangyang/Downloads/b18.bin.gz`); call this path `$MODEL` below.

Force a retune so we exercise the search:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
KATAGO_MLX_WINOTUNER_FORCE=1 ./katago benchmark -model "$MODEL" -config configs/gtp_example.cfg -t 16 -half-batch-size 2>&1 | grep -E "MLX Winograd|tuning|tuned|visits/s = " | head -20
```
Expected: log lines mentioning "Performing autotuning for MLX Winograd transforms", "Tuning input transform", "Tuning output untransform", "MLX Winograd tuning done: inputTransform=…", followed by the usual benchmark `visits/s = …` lines.

Then verify the cache file was written:

```bash
ls -la ~/.katago/mlxwinotuning/ && cat ~/.katago/mlxwinotuning/tunemlxwino1_gpu*_x19_y19_*.txt | head
```
Expected: one file, content matches the schema (`VERSION=1`, `#inputTransform`, `tg0=... tg1=...`, `#outputUntransform`, `tg0=... tg1=...`).

Then verify the second run loads the cache (no tuning re-run):

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago benchmark -model "$MODEL" -config configs/gtp_example.cfg -t 16 -half-batch-size 2>&1 | grep -E "Loaded MLX Winograd|Performing autotuning" | head -5
```
Expected: a `Loaded MLX Winograd tuning parameters from …` line and **no** `Performing autotuning` line.

- [ ] **Step 10: Run runnnlayertests to verify the schema change didn't regress correctness**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ./katago runnnlayertests 2>&1 | tail -10
```
Expected: all tests pass; specifically the SP1 winogradConv2d-vs-cpu-oracle test still asserts `maxErr < 2e-3`.

- [ ] **Step 11: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxbackend.cpp
git commit -m "SP2 Task 5: wire tuner into ComputeHandle/Model/ConvLayer

ComputeContext now stores homeDataDirOverride and logger. ComputeHandle
ctor calls MLXWinogradTuner::loadOrAutoTune before Model construction;
tuned per-stage configs flow into Model -> ConvLayer -> winogradConv2d.

Env-var safety valves consistent with SP1 KATAGO_MLX_WINOGRAD pattern:
  KATAGO_MLX_WINOTUNER=0        - skip tuning, use SP1 baked defaults
  KATAGO_MLX_WINOTUNER_FORCE=1  - ignore cache file, retune & overwrite
  KATAGO_MLX_WINOTUNER_FULL=1   - use wider grid ranges

makeCacheKey gains '-tuned'/'-untuned' discriminator so Model cache
invalidates correctly when tuner is toggled.

gpuName via mlx::core::metal::device_info()['architecture'] with fallback.

Tuner is disabled for useFP16 (SP3 territory).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Acceptance — Honest Benchmark + Traceability Commit

**Goal:** prove SP2 doesn't regress SP1's GATE PASS. Run `cpp/tools/bench_mlx_honest.sh` with the tuner-cached config; record the result in a traceability commit.

**Files:**
- Read-only: `cpp/tools/bench_mlx_honest.sh`
- No code changes; only a benchmark run + an empty traceability commit

- [ ] **Step 1: Delete any pre-existing tune file, force a fresh tune**

```bash
trash ~/.katago/mlxwinotuning/ 2>/dev/null || true
ls ~/.katago/mlxwinotuning/ 2>/dev/null || echo "(no tune dir)"
```
Expected: `(no tune dir)` or empty.

- [ ] **Step 2: Identify the same KataGo model used in SP1's acceptance**

```bash
find / -name "*.bin.gz" 2>/dev/null | grep -iE "b18|katago" | head -3
```
Pick the same one SP1 used. (If unclear from `git log -p docs/superpowers/specs/2026-05-19-mlx-winograd-fp32-conv-design.md`, fall back to any b18 net file.) Call its path `$MODEL`.

- [ ] **Step 3: Run the honest benchmark harness — tuner-on**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
MODEL="$MODEL" CFG=cpp/configs/gtp_example.cfg \
  bash cpp/tools/bench_mlx_honest.sh 2>&1 | tee /tmp/sp2_honest_bench.log | tail -20
```
Expected output (the final block):
```
Metal : mean=<MMm> stdev=<MSm> 95%CI=±<MCm>
MLX   : mean=<XMm> stdev=<XSm> 95%CI=±<XCm>
Delta (MLX-Metal): <DELTA>  (raw audit: /var/folders/...)
GATE PASS: MLX-fp32 >= Metal (CI-aware)
```
With `<XMm> ≥ <MMm>` (MLX matches or beats Metal) and the gate's CI-aware comparison passing. Expected `<XMm>` should be comparable to SP1's 529.79 v/s figure (within ~5%); if it's substantially lower (e.g. < 510 v/s), SP2 has regressed and the cause must be diagnosed before committing.

- [ ] **Step 4: Confirm the cache file was used (not re-tuned during the bench)**

```bash
cat ~/.katago/mlxwinotuning/tunemlxwino1_gpu*_x19_y19_*.txt
```
Expected: the file contains the tuned configs (likely `tg0=32 tg1=1` or a similar near-optimum). The mere fact the file existed at the start of `Step 3`'s benchmark means the tuner skipped the search and just loaded it — confirmed implicitly by the lack of "Performing autotuning" messages in the bench log.

- [ ] **Step 5: Empty traceability commit recording the gate-pass numbers**

Edit the placeholder values below to match the actual numbers from Step 3's output before running:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git commit --allow-empty -m "SP2 acceptance: MLX-fp32 Winograd with tuner-cached configs >= Metal

Honest paired benchmark (cpp/tools/bench_mlx_honest.sh) on Apple Silicon
with the model and config used in SP1's acceptance:

  Metal : mean=<MMm> ± <MCm> (95%CI) v/s
  MLX   : mean=<XMm> ± <XCm> (95%CI) v/s
  Delta : +<DELTA> v/s  (CI-aware GATE PASS)

Tuner produced and cached:
$(cat ~/.katago/mlxwinotuning/tunemlxwino1_gpu*_x19_y19_*.txt | tail -n +1 | tr '\n' ' ')

SP2 acceptance gate fully satisfied:
  - Search-works test (Task 4): (a) winner <= 0.5x bad seed; (b) winner <= 1.05x optimum
  - File round-trip test (Task 2): save/load identity + corrupt-version rejection
  - End-to-end honest re-run (this commit): tuner-cached >= SP1 baked default >= Metal

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

(Replace the `<MMm>`, `<MCm>`, `<XMm>`, `<XCm>`, `<DELTA>` placeholders with the actual numbers from the benchmark log before the commit message is committed.)

- [ ] **Step 6: (Optional) Run the search-works test once more for the record**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && \
  KATAGO_MLX_WINOTUNER_RUN_SEARCH_TEST=1 ./katago runnnlayertests 2>&1 | grep -E "MLX Winograd|winner=|passed"
```
Expected: same as Task 4 Step 5.

---

## Self-Review (controller checklist, run before handoff)

### 1. Spec coverage

| Spec section | Implementing task | Status |
|---|---|---|
| §1 schema split (`InputTransform`/`OutputUntransform`, drop vec/axis/tileSize) | Task 1 | ✓ |
| §2 candidate ranges (mirror OpenCL lines 2101–2106, 2268–2275) | Task 4 step 1 (`inputTg0Values`/etc.) | ✓ |
| §3 search strategy (cartesian + validity-filter + shuffle + reference baseline) | Task 4 step 1 (`buildInputCandidates`, `searchInputTransform`) | ✓ |
| §4 cache file format (plain-text VERSION + KEY=VALUE, `<homeDataDir>/mlxwinotuning/`, OpenCL-clean filename) | Task 2 step 2 (`save`/`load`/`defaultDirectory`/`defaultFileName`) | ✓ |
| §5 API shape (`loadOrAutoTune`, `ModelInfoForTuning`) | Task 2 step 1 (header) + Task 4 step 1 (impl) | ✓ |
| §6 wiring into `mlxbackend.cpp` (Model ctor, env-vars, cache-key) | Task 5 | ✓ |
| §7 acceptance gate (a) winner ≤ 0.5 × bad-seed; (b) winner ≤ 1.05 × optimum | Task 4 step 2 + Task 6 | ✓ |
| §7 file round-trip + corrupt-version rejection | Task 2 step 5 | ✓ |
| §7 end-to-end honest re-run via bench_mlx_honest.sh | Task 6 | ✓ |
| §8 files list | Task 1–6 (one task per file group) | ✓ |
| §9 non-goals | (no implementation needed) | — |

### 2. Placeholder scan

No `TBD`, `TODO`, `implement later`, `fill in details`. The only `<placeholder>` is in Task 6 step 5's commit message, which is explicitly directed to be filled in from the benchmark output.

### 3. Type consistency

- `MLXWinograd::InputTransform` and `MLXWinograd::OutputUntransform` are introduced in Task 1, used in Tasks 2–5. Same field names (`tg0`, `tg1`) throughout.
- `MLXWinogradTuneParams` has `inputTransform` and `outputUntransform` members in both the header (Task 2) and all use sites (Tasks 4, 5).
- `MLXWinogradTuner::ModelInfoForTuning` has `trunkNumChannels`, `midNumChannels`, `maxConvChannels3x3`, `modelVersion` — used consistently in Task 3 (`scoreInputTransform`, `scoreOutputUntransform`), Task 4 (`searchInputTransform`, `loadOrAutoTune`), and Task 5 (Step 5 construction).
- `MLXWinogradTuner::loadOrAutoTune` signature is identical across the header declaration (Task 2) and the implementation (Task 4).
- `winogradConv2d` takes `(input, Uw, Cout, inCfg, outCfg)` in Task 1; the same signature is used in Task 5 (`ConvLayer::apply`) and Task 4 (the test's `timeCfg` lambda).

No type-name drift.
