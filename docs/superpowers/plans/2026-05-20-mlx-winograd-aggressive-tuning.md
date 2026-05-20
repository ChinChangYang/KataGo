# SP4 — Aggressive F(2,3) Autotuner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand the MLX Winograd autotuner from 2-D `(tg0, tg1)` to a 6-axis hierarchical search (`tg0, tg1, wpt, vw, gridOrder, matmulOrient`) within the existing F(2,3) algorithm and fp16 mode, holding the SP3 accuracy gate.

**Architecture:** Four per-stage axes (`tg0, tg1, wpt, vw`), one stage-shared axis (`gridOrder`), one global axis (`matmulOrient`). Kernels are template-instantiated on `(T, WPT, VW, GRID_ORDER, MATMUL_ORIENT)` — each combo becomes a separate JIT-compiled Metal kernel. Tuner uses hierarchical search: outer loop over `(matmulOrient, gridOrder)`, inner joint sweeps for tightly-coupled `(wpt, vw)` and `(tg0, tg1)` pairs with top-3 carry-through, plus one end-to-end timing per outer combo. Cache file bumps to `VERSION=2`; SP3 caches sit on disk untouched (different filename per version).

**Tech Stack:** C++17, MLX (`mx::fast::metal_kernel` with `template_args`), Metal shading language, Ninja+CMake, KataGo's existing `testgpuerror` and `runnnlayertests` harnesses.

**Reference spec:** `docs/superpowers/specs/2026-05-20-mlx-winograd-aggressive-tuning-design.md`

**Branch:** `feature/mlx-backend` (continues from SP3 at `36a88189`)

---

## File map

| File | Role | Change shape |
|---|---|---|
| `cpp/neuralnet/mlxwinograd.h` | Kernel source + `InputTransform`/`OutputUntransform` structs + `winogradConv2d` + `makeWinogradWeights` | Add fields, extend kernels, thread orient |
| `cpp/neuralnet/mlxwinotuner.h` | `MLXWinogradTuneParams` struct + tuner API | Add `gridOrder, matmulOrient`; bump VERSION |
| `cpp/neuralnet/mlxwinotuner.cpp` | Tuner search logic + persistence | Replace flat search with hierarchical; expand candidate sets |
| `cpp/neuralnet/mlxbackend.cpp` | `ConvLayer`, `Model`, `ComputeHandle` wiring | Thread new fields through |
| `cpp/tests/testmlxwinograd.cpp` (new) | Kernel-equivalence unit tests | Create — bit-for-bit WPT/VW/gridOrder/orient tests |
| `cpp/tests/testmlxwinotuner.cpp` (existing) | Tuner sanity + schema tests | Extend with bad-seed convergence + version-bump retune |
| `cpp/CMakeLists.txt` | Build registration | Add `testmlxwinograd.cpp` |
| `cpp/command/sp3_orchestrator.sh` or equivalent | Acceptance orchestrator | Extend with SP4 arm |

---

## Task 1: Schema v2 — extend `MLXWinogradTuneParams` + bump version

**Files:**
- Modify: `cpp/neuralnet/mlxwinograd.h:15-16` (struct field additions)
- Modify: `cpp/neuralnet/mlxwinotuner.h:11-23` (struct field additions)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:26-28, 62-112` (version bump + save/load extensions)
- Test: `cpp/tests/testmlxwinotuner.cpp` (existing — extend)

- [ ] **Step 1: Write the failing roundtrip test**

In `cpp/tests/testmlxwinotuner.cpp`, find the existing save/load roundtrip test and add this case **next to it** (don't replace):

```cpp
TEST_CASE("MLXWinogradTuneParams v2 save/load roundtrip with all 6 axes") {
  using namespace MLXWinograd;
  MLXWinogradTuneParams p;
  p.inputTransform    = InputTransform   {/*tg0*/48, /*tg1*/10, /*wpt*/4, /*vw*/4, GridOrder::Cfast};
  p.outputUntransform = OutputUntransform{/*tg0*/96, /*tg1*/25, /*wpt*/2, /*vw*/2, GridOrder::Cfast};
  p.gridOrder    = GridOrder::Cfast;
  p.matmulOrient = MatmulOrient::Std;

  std::string tmp = "/tmp/mlxwino_sp4_roundtrip.txt";
  MLXWinogradTuneParams::save(tmp, p);
  MLXWinogradTuneParams loaded = MLXWinogradTuneParams::load(tmp);

  REQUIRE(loaded.inputTransform.tg0 == 48);
  REQUIRE(loaded.inputTransform.tg1 == 10);
  REQUIRE(loaded.inputTransform.wpt == 4);
  REQUIRE(loaded.inputTransform.vw == 4);
  REQUIRE(loaded.inputTransform.gridOrder == GridOrder::Cfast);
  REQUIRE(loaded.outputUntransform.tg0 == 96);
  REQUIRE(loaded.outputUntransform.tg1 == 25);
  REQUIRE(loaded.outputUntransform.wpt == 2);
  REQUIRE(loaded.outputUntransform.vw == 2);
  REQUIRE(loaded.gridOrder == GridOrder::Cfast);
  REQUIRE(loaded.matmulOrient == MatmulOrient::Std);
  std::remove(tmp.c_str());
}
```

- [ ] **Step 2: Run the test and verify it fails to compile**

Run: `cd cpp && cmake -G Ninja -DUSE_BACKEND=MLX && ninja runtests`
Expected: compile failure on `GridOrder`, `MatmulOrient`, `.wpt`, `.vw`, etc. — the types don't exist yet.

- [ ] **Step 3: Add enums and extend the per-stage structs**

In `cpp/neuralnet/mlxwinograd.h`, replace lines 15-16 with:

```cpp
enum class GridOrder    : int { Cfast = 0, Tfast = 1 };
enum class MatmulOrient : int { Std = 0, Tpd = 1 };

// Per-stage launch-geometry configs. SP2 tunes (tg0, tg1); SP4 adds
// (wpt, vw, gridOrder). The matmulOrient axis is global, not per-stage,
// and lives on MLXWinogradTuneParams.
struct InputTransform {
  int tg0 = 32;
  int tg1 = 1;
  int wpt = 1;            // tiles per thread; {1, 2, 4, 8}
  int vw  = 1;            // vector width; {1, 2, 4}
  GridOrder gridOrder = GridOrder::Cfast;
};
struct OutputUntransform {
  int tg0 = 32;
  int tg1 = 1;
  int wpt = 1;
  int vw  = 1;
  GridOrder gridOrder = GridOrder::Cfast;
};
```

- [ ] **Step 4: Extend `MLXWinogradTuneParams`**

In `cpp/neuralnet/mlxwinotuner.h`, replace the struct body with:

```cpp
struct MLXWinogradTuneParams {
  MLXWinograd::InputTransform    inputTransform;
  MLXWinograd::OutputUntransform outputUntransform;
  MLXWinograd::GridOrder         gridOrder    = MLXWinograd::GridOrder::Cfast;
  MLXWinograd::MatmulOrient      matmulOrient = MLXWinograd::MatmulOrient::Std;

  // tg0 * tg1 <= 1024 (Metal threadgroup cap), all positive, gridOrder of
  // both stages must equal the global gridOrder, vw must divide the fast
  // axis dim of the current model — last check happens at candidate-enumeration
  // time, not here. isValid() only checks structural invariants.
  bool isValid() const;

  // VERSION=2 plain-text persistence. Format:
  //   VERSION=2
  //   #global
  //   gridOrder=<0|1> matmulOrient=<0|1>
  //   #inputTransform
  //   tg0=<int> tg1=<int> wpt=<int> vw=<int> gridOrder=<0|1>
  //   #outputUntransform
  //   tg0=<int> tg1=<int> wpt=<int> vw=<int> gridOrder=<0|1>
  static void save(const std::string& filename, const MLXWinogradTuneParams& params);
  static MLXWinogradTuneParams load(const std::string& filename);
};
```

- [ ] **Step 5: Bump VERSION constant**

In `cpp/neuralnet/mlxwinotuner.cpp:26`, change:

```cpp
static const int MLX_WINO_TUNER_VERSION = 2;
```

This naturally changes the cache filename (`tunemlxwino2_…`), so v1 caches don't collide.

- [ ] **Step 6: Rewrite `MLXWinogradTuneParams::save`**

In `cpp/neuralnet/mlxwinotuner.cpp:70-82`, replace with:

```cpp
void MLXWinogradTuneParams::save(const string& filename, const MLXWinogradTuneParams& params) {
  ofstream out;
  FileUtils::open(out, filename);
  out << MLX_WINO_TUNEPARAMS_VERSION_LINE << "\n";
  out << "#global" << "\n";
  out << "gridOrder=" << (int)params.gridOrder
      << " matmulOrient=" << (int)params.matmulOrient << "\n";
  out << "#inputTransform" << "\n";
  out << "tg0=" << params.inputTransform.tg0
      << " tg1=" << params.inputTransform.tg1
      << " wpt=" << params.inputTransform.wpt
      << " vw="  << params.inputTransform.vw
      << " gridOrder=" << (int)params.inputTransform.gridOrder << "\n";
  out << "#outputUntransform" << "\n";
  out << "tg0=" << params.outputUntransform.tg0
      << " tg1=" << params.outputUntransform.tg1
      << " wpt=" << params.outputUntransform.wpt
      << " vw="  << params.outputUntransform.vw
      << " gridOrder=" << (int)params.outputUntransform.gridOrder << "\n";
  out.flush();
  out.close();
}
```

- [ ] **Step 7: Rewrite `MLXWinogradTuneParams::load`**

In `cpp/neuralnet/mlxwinotuner.cpp:84-112`, replace with:

```cpp
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
                  + MLX_WINO_TUNEPARAMS_VERSION_LINE + " in " + filename);
  if(lines.size() != 4)
    throw IOError("MLXWinogradTuneParams::load: expected 4 non-comment lines in " + filename);

  MLXWinogradTuneParams params;
  {
    map<string,int> kvs = parseKeyValueLine(filename, lines[1]);
    params.gridOrder    = (MLXWinograd::GridOrder)requireKey(kvs, "gridOrder", filename);
    params.matmulOrient = (MLXWinograd::MatmulOrient)requireKey(kvs, "matmulOrient", filename);
  }
  {
    map<string,int> kvs = parseKeyValueLine(filename, lines[2]);
    params.inputTransform.tg0 = requireKey(kvs, "tg0", filename);
    params.inputTransform.tg1 = requireKey(kvs, "tg1", filename);
    params.inputTransform.wpt = requireKey(kvs, "wpt", filename);
    params.inputTransform.vw  = requireKey(kvs, "vw",  filename);
    params.inputTransform.gridOrder = (MLXWinograd::GridOrder)requireKey(kvs, "gridOrder", filename);
  }
  {
    map<string,int> kvs = parseKeyValueLine(filename, lines[3]);
    params.outputUntransform.tg0 = requireKey(kvs, "tg0", filename);
    params.outputUntransform.tg1 = requireKey(kvs, "tg1", filename);
    params.outputUntransform.wpt = requireKey(kvs, "wpt", filename);
    params.outputUntransform.vw  = requireKey(kvs, "vw",  filename);
    params.outputUntransform.gridOrder = (MLXWinograd::GridOrder)requireKey(kvs, "gridOrder", filename);
  }
  return params;
}
```

- [ ] **Step 8: Extend `isValid()`**

In `cpp/neuralnet/mlxwinotuner.cpp:62-68`, replace with:

```cpp
bool MLXWinogradTuneParams::isValid() const {
  if(inputTransform.tg0 <= 0 || inputTransform.tg1 <= 0) return false;
  if(outputUntransform.tg0 <= 0 || outputUntransform.tg1 <= 0) return false;
  if(inputTransform.tg0 * inputTransform.tg1 > 1024) return false;
  if(outputUntransform.tg0 * outputUntransform.tg1 > 1024) return false;
  if(inputTransform.wpt < 1 || outputUntransform.wpt < 1) return false;
  if(inputTransform.vw  < 1 || outputUntransform.vw  < 1) return false;
  // Stage-shared invariant: both stages' gridOrder must match the global.
  if(inputTransform.gridOrder    != gridOrder) return false;
  if(outputUntransform.gridOrder != gridOrder) return false;
  return true;
}
```

- [ ] **Step 9: Build and run the test**

Run: `cd cpp && ninja runtests && ./runtests "MLXWinogradTuneParams v2 save/load roundtrip"`
Expected: PASS

- [ ] **Step 10: Run the full unit suite to catch regressions**

Run: `./runtests` and `./runnnlayertests`
Expected: all pass (kernels still ignore the new fields — no behavior change yet)

- [ ] **Step 11: Commit**

```bash
git add cpp/neuralnet/mlxwinograd.h cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp cpp/tests/testmlxwinotuner.cpp
git commit -m "SP4 Task 1: bump tuner schema to v2 — add wpt/vw/gridOrder/matmulOrient fields

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Kernel template-arg plumbing (no behavior change)

**Files:**
- Modify: `cpp/neuralnet/mlxwinograd.h:256-321` (`winogradConv2d` signature + template_args build)
- Modify: `cpp/neuralnet/mlxbackend.cpp:215` (ConvLayer call site)

- [ ] **Step 1: Write the failing build test**

Add a smoke test in `cpp/tests/testmlxwinograd.cpp` (new file):

```cpp
#include "../neuralnet/mlxwinograd.h"
#include "../tests/tests.h"

TEST_CASE("winogradConv2d compiles + runs with extended template args (WPT=1, VW=1)") {
  using namespace MLXWinograd;
  using namespace mlx::core;

  // Trivial 4x4x1 input, 1 output channel, identity-ish filter.
  std::vector<float> in_data(16, 1.0f);
  array inp(in_data.data(), {1, 4, 4, 1}, float32);
  std::vector<float> w_data(9, 1.0f);   // all-ones 3x3 filter
  array Uw = makeWinogradWeights(w_data, /*Cout*/1, /*Cin*/1,
                                 /*useFP16*/false, MatmulOrient::Std);

  InputTransform    inCfg;   // defaults: tg0=32, tg1=1, wpt=1, vw=1, Cfast
  OutputUntransform outCfg;  // same
  array out = winogradConv2d(inp, Uw, /*Cout*/1, inCfg, outCfg,
                             /*useFP16*/false, MatmulOrient::Std);
  eval(out);
  REQUIRE(out.shape() == Shape{1, 4, 4, 1});
}
```

Register in `cpp/CMakeLists.txt`: add `cpp/tests/testmlxwinograd.cpp` to the `runtests` target sources list (look for where `testmlxwinotuner.cpp` is added and follow that pattern).

- [ ] **Step 2: Run the test and verify it fails to compile**

Run: `cd cpp && ninja runtests`
Expected: compile failure — `makeWinogradWeights` doesn't accept `MatmulOrient`, `winogradConv2d` doesn't accept `MatmulOrient`.

- [ ] **Step 3: Extend `makeWinogradWeights` signature**

In `cpp/neuralnet/mlxwinograd.h:123-142`, replace with:

```cpp
inline mx::array makeWinogradWeights(const std::vector<float>& wOIHW,
                                     int Cout, int Cin,
                                     bool useFP16 = false,
                                     MatmulOrient orient = MatmulOrient::Std) {
  std::vector<float> U((size_t)16 * Cin * Cout, 0.0f);
  for(int oc = 0; oc < Cout; oc++) {
    for(int ic = 0; ic < Cin; ic++) {
      float g[3][3];
      for(int a = 0; a < 3; a++)
        for(int b = 0; b < 3; b++)
          g[a][b] = wOIHW[(((size_t)oc * Cin + ic) * 3 + a) * 3 + b];
      float Um[4][4]; transformWeight(g, Um);
      for(int a = 0; a < 4; a++) {
        for(int b = 0; b < 4; b++) {
          // Std: [16, Cin, Cout] — Cout fast
          // Tpd: [16, Cout, Cin] — Cin fast
          size_t idx = (orient == MatmulOrient::Std)
            ? ((size_t)(a * 4 + b) * Cin  + ic) * Cout + oc
            : ((size_t)(a * 4 + b) * Cout + oc) * Cin  + ic;
          U[idx] = Um[a][b];
        }
      }
    }
  }
  mx::Shape shape = (orient == MatmulOrient::Std)
    ? mx::Shape{16, Cin, Cout}
    : mx::Shape{16, Cout, Cin};
  mx::array arr(U.data(), shape, mx::float32);
  if(useFP16) return mx::astype(arr, mx::float16);
  return arr;
}
```

- [ ] **Step 4: Extend `winogradConv2d` signature and threading**

In `cpp/neuralnet/mlxwinograd.h:256-321`, replace with:

```cpp
inline mx::array winogradConv2d(const mx::array& input,
                                const mx::array& Uw,
                                int Cout,
                                const InputTransform& inCfg,
                                const OutputUntransform& outCfg,
                                bool useFP16 = false,
                                MatmulOrient matmulOrient = MatmulOrient::Std) {
  int N = input.shape(0);
  int H = input.shape(1);
  int W = input.shape(2);
  int C = input.shape(3);
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  const mx::Dtype dtype = useFP16 ? mx::float16 : mx::float32;

  auto suffix = [&](const char* base, int wpt, int vw, GridOrder go) {
    return std::string(base) + "_" + (useFP16 ? "f16" : "f32")
         + "_w" + std::to_string(wpt)
         + "_v" + std::to_string(vw)
         + "_g" + std::to_string((int)go)
         + "_o" + std::to_string((int)matmulOrient);
  };
  std::string inName  = suffix("wino_input_transform",  inCfg.wpt,  inCfg.vw,  inCfg.gridOrder);
  std::string outName = suffix("wino_output_untransform", outCfg.wpt, outCfg.vw, outCfg.gridOrder);

  auto makeTemplateArgs = [&](int wpt, int vw, GridOrder go) {
    return std::vector<std::pair<std::string, mx::fast::TemplateArg>>{
      {"T", dtype},
      {"WPT",         wpt},
      {"VW",          vw},
      {"GRID_ORDER",  (int)go},
      {"MATMUL_ORIENT", (int)matmulOrient}
    };
  };

  // Stage 1: input transform.
  // Output shape depends on matmulOrient:
  //   Std: [16, Ntiles, C]
  //   Tpd: [16, C, Ntiles]
  mx::Shape inOutShape = (matmulOrient == MatmulOrient::Std)
    ? mx::Shape{16, Ntiles, C}
    : mx::Shape{16, C, Ntiles};

  // Grid: when gridOrder=Cfast the fast axis is C (grid x=C, y=Ntiles/WPT).
  // When gridOrder=Tfast we swap.
  int gridX_in = (inCfg.gridOrder == GridOrder::Cfast) ? C : Ntiles;
  int gridY_in = (inCfg.gridOrder == GridOrder::Cfast)
    ? ((Ntiles + inCfg.wpt - 1) / inCfg.wpt)
    : ((C      + inCfg.wpt - 1) / inCfg.wpt);

  auto inFn = mx::fast::metal_kernel(
      inName.c_str(),
      /*input_names=*/{"inp"},
      /*output_names=*/{"outp"},
      /*source=*/kWinoInputSource);
  auto inOuts = inFn(
      /*inputs=*/{input},
      /*output_shapes=*/{ inOutShape },
      /*output_dtypes=*/{ dtype },
      /*grid=*/std::make_tuple(gridX_in, gridY_in, 1),
      /*threadgroup=*/std::make_tuple(inCfg.tg0, inCfg.tg1, 1),
      /*template_args=*/makeTemplateArgs(inCfg.wpt, inCfg.vw, inCfg.gridOrder),
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});
  mx::array t = inOuts[0];

  // Stage 2: matmul.
  // Std: [16,Ntiles,C] @ [16,C,Cout] -> [16,Ntiles,Cout]
  // Tpd: [16,Cout,Cin] @ [16,Cin,Ntiles] -> [16,Cout,Ntiles]
  mx::array m = (matmulOrient == MatmulOrient::Std)
    ? mx::matmul(t, Uw)
    : mx::matmul(Uw, t);

  // Stage 3: output untransform.
  int nhwc_arr[4] = {N, H, W, Cout};
  mx::array nhwcArr(nhwc_arr, {4}, mx::int32);
  int gridX_out = (outCfg.gridOrder == GridOrder::Cfast) ? Cout : Ntiles;
  int gridY_out = (outCfg.gridOrder == GridOrder::Cfast)
    ? ((Ntiles + outCfg.wpt - 1) / outCfg.wpt)
    : ((Cout   + outCfg.wpt - 1) / outCfg.wpt);

  auto outFn = mx::fast::metal_kernel(
      outName.c_str(),
      /*input_names=*/{"m", "nhwc"},
      /*output_names=*/{"outp"},
      /*source=*/kWinoOutputSource);
  auto outOuts = outFn(
      /*inputs=*/{m, nhwcArr},
      /*output_shapes=*/{ mx::Shape{N, H, W, Cout} },
      /*output_dtypes=*/{ dtype },
      /*grid=*/std::make_tuple(gridX_out, gridY_out, 1),
      /*threadgroup=*/std::make_tuple(outCfg.tg0, outCfg.tg1, 1),
      /*template_args=*/makeTemplateArgs(outCfg.wpt, outCfg.vw, outCfg.gridOrder),
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});
  return outOuts[0];
}
```

- [ ] **Step 5: Add stub branches in the kernel sources for the new template args (no-op at WPT=1/VW=1/Cfast/Std)**

In `cpp/neuralnet/mlxwinograd.h`, prepend to `kWinoInputSource` body (right after the `uint c_group = …` line):

```cpp
// SP4: WPT/VW/GRID_ORDER/MATMUL_ORIENT are now template params.
// Task 2 introduces the plumbing; Tasks 3-6 implement non-default behavior.
// At WPT=1, VW=1, GRID_ORDER=0, MATMUL_ORIENT=0 the kernel must be
// bit-identical to SP3. Guard non-default paths with `if constexpr` or
// runtime checks; this task keeps WPT=1/VW=1/Cfast/Std as the only valid
// instantiation and falls through to the original code.
static_assert(WPT >= 1 && VW >= 1, "WPT and VW must be positive");
```

Same on `kWinoOutputSource`.

(These `static_assert`s use the template params, which forces the JIT to actually substitute them — guaranteeing the plumbing works.)

- [ ] **Step 6: Update `ConvLayer::operator()` call site**

In `cpp/neuralnet/mlxbackend.cpp:215`, replace with:

```cpp
return MLXWinograd::winogradConv2d(input, winogradWeights, outChannels,
                                   winoInCfg, winoOutCfg, useFP16,
                                   MLXWinograd::MatmulOrient::Std);
```

In the `ConvLayer` constructor body at lines 207-208, replace with:

```cpp
weights(useWinograd ? mx::array(0.0f) : toComputeDtype(convertConvWeightsOIHWtoOHWI(desc.weights, outChannels, inChannels, convYSize, convXSize), useFP16_)),
winogradWeights(useWinograd
    ? MLXWinograd::makeWinogradWeights(desc.weights, outChannels, inChannels, useFP16_, MLXWinograd::MatmulOrient::Std)
    : mx::array(0.0f))
```

(Hard-code `Std` until Task 8 wires the configured orient through.)

- [ ] **Step 7: Build and run the smoke test**

Run: `cd cpp && ninja runtests && ./runtests "winogradConv2d compiles"`
Expected: PASS — `winogradConv2d` runs at defaults; output shape is `{1, 4, 4, 1}`.

- [ ] **Step 8: Run the full suites for regressions**

Run: `./runtests` and `./runnnlayertests`
Expected: all pass — defaults reproduce SP3 behavior bit-for-bit.

- [ ] **Step 9: Commit**

```bash
git add cpp/neuralnet/mlxwinograd.h cpp/neuralnet/mlxbackend.cpp cpp/tests/testmlxwinograd.cpp cpp/CMakeLists.txt
git commit -m "SP4 Task 2: thread WPT/VW/GRID_ORDER/MATMUL_ORIENT template args through winogradConv2d

No behavior change at defaults (WPT=1, VW=1, Cfast, Std). Plumbing only —
Tasks 3-6 add non-default kernel paths.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: WPT in both transform kernels

**Files:**
- Modify: `cpp/neuralnet/mlxwinograd.h:147-200` (input kernel WPT loop)
- Modify: `cpp/neuralnet/mlxwinograd.h:207-254` (output kernel WPT loop)
- Test: `cpp/tests/testmlxwinograd.cpp`

- [ ] **Step 1: Write the failing bit-for-bit equivalence test**

In `cpp/tests/testmlxwinograd.cpp`, add:

```cpp
TEST_CASE("WPT=1 vs WPT=4 vs WPT=8 produce bit-identical input-transform output (fp32)") {
  using namespace MLXWinograd;
  using namespace mlx::core;
  // Realistic shape: N=2, H=W=19, C=64 -> Ntiles = 2*10*10 = 200.
  std::vector<float> in_data((size_t)2*19*19*64);
  std::mt19937 rng(0x1234);
  std::uniform_real_distribution<float> dist(-1, 1);
  for(auto& x : in_data) x = dist(rng);
  array inp(in_data.data(), {2, 19, 19, 64}, float32);

  auto runWith = [&](int wpt) {
    InputTransform    inCfg;  inCfg.wpt = wpt;
    OutputUntransform outCfg; // unused — we test input transform in isolation
    // Build dummy weights so winogradConv2d works; assert on intermediate only.
    std::vector<float> w_data((size_t)64*64*9, 1.0f);
    array Uw = makeWinogradWeights(w_data, 64, 64, /*useFP16*/false, MatmulOrient::Std);
    array out = winogradConv2d(inp, Uw, 64, inCfg, outCfg, false, MatmulOrient::Std);
    eval(out);
    return out;
  };

  array out1 = runWith(1);
  array out4 = runWith(4);
  array out8 = runWith(8);
  // Bit-for-bit: same kernel modulo loop unrolling. Tolerance = 0.
  REQUIRE(allclose(out1, out4, /*rtol*/0, /*atol*/0).item<bool>());
  REQUIRE(allclose(out1, out8, /*rtol*/0, /*atol*/0).item<bool>());
}

TEST_CASE("WPT=1 vs WPT=4 vs WPT=8 produce bit-identical output-untransform output (fp32)") {
  // Same structure: vary outCfg.wpt instead of inCfg.wpt.
  // (Body identical to above with outCfg.wpt = wpt.)
  using namespace MLXWinograd;
  using namespace mlx::core;
  std::vector<float> in_data((size_t)2*19*19*64);
  std::mt19937 rng(0x5678);
  std::uniform_real_distribution<float> dist(-1, 1);
  for(auto& x : in_data) x = dist(rng);
  array inp(in_data.data(), {2, 19, 19, 64}, float32);

  auto runWith = [&](int wpt) {
    InputTransform    inCfg;
    OutputUntransform outCfg; outCfg.wpt = wpt;
    std::vector<float> w_data((size_t)64*64*9, 1.0f);
    array Uw = makeWinogradWeights(w_data, 64, 64, false, MatmulOrient::Std);
    array out = winogradConv2d(inp, Uw, 64, inCfg, outCfg, false, MatmulOrient::Std);
    eval(out);
    return out;
  };

  array out1 = runWith(1), out4 = runWith(4), out8 = runWith(8);
  REQUIRE(allclose(out1, out4, 0, 0).item<bool>());
  REQUIRE(allclose(out1, out8, 0, 0).item<bool>());
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cd cpp && ninja runtests && ./runtests "WPT"`
Expected: at WPT=4 and WPT=8 the kernel still processes only `Ntiles/WPT` tiles (current grid y dim is `Ntiles/WPT` from Task 2), so most outputs are zero — `allclose` fails.

- [ ] **Step 3: Rewrite `kWinoInputSource` with WPT loop**

In `cpp/neuralnet/mlxwinograd.h:147-200`, replace `kWinoInputSource` body (the string between the `R"METAL(` and `)METAL"` markers) with:

```metal
    uint c_group  = thread_position_in_grid.x;
    uint t_group  = thread_position_in_grid.y;

    static_assert(WPT >= 1 && VW >= 1, "WPT and VW must be positive");

    int N_k      = inp_shape[0];
    int H_k      = inp_shape[1];
    int W_k      = inp_shape[2];
    int C_k      = inp_shape[3];
    int tilesY_k = (H_k + 1) / 2;
    int tilesX_k = (W_k + 1) / 2;
    int Ntiles_k = N_k * tilesY_k * tilesX_k;

    // GRID_ORDER=0 (Cfast): grid x = C, grid y = ceil(Ntiles/WPT).
    // GRID_ORDER=1 (Tfast): grid x = Ntiles, grid y = ceil(C/WPT).
    // (Tfast path lands in Task 5; here we implement only Cfast.)
    uint c = c_group;
    if ((int)c >= C_k) return;

    for (int w = 0; w < WPT; w++) {
      int tileIdx = (int)t_group * WPT + w;
      if (tileIdx >= Ntiles_k) break;

      int rem = tileIdx;
      int n   = rem / (tilesY_k * tilesX_k); rem -= n * tilesY_k * tilesX_k;
      int ty  = rem / tilesX_k;
      int tx  = rem % tilesX_k;

      T d[4][4];
      for (int i = 0; i < 4; i++) {
        int iy = 2 * ty - 1 + i;
        for (int j = 0; j < 4; j++) {
          int ix = 2 * tx - 1 + j;
          if (iy < 0 || iy >= H_k || ix < 0 || ix >= W_k) {
            d[i][j] = (T)0.0f;
          } else {
            d[i][j] = inp[((n * H_k + iy) * W_k + ix) * C_k + (int)c];
          }
        }
      }
      T tmp[4][4];
      for (int j = 0; j < 4; j++) {
        T v0 = d[0][j], v1 = d[1][j], v2 = d[2][j], v3 = d[3][j];
        tmp[0][j] = v0 - v2;
        tmp[1][j] = v1 + v2;
        tmp[2][j] = v2 - v1;
        tmp[3][j] = v1 - v3;
      }
      for (int r = 0; r < 4; r++) {
        T u0 = tmp[r][0], u1 = tmp[r][1], u2 = tmp[r][2], u3 = tmp[r][3];
        T V0 = u0 - u2;
        T V1 = u1 + u2;
        T V2 = u2 - u1;
        T V3 = u1 - u3;
        // MATMUL_ORIENT=0 (Std): outp shape [16, Ntiles, C], C-fast.
        // MATMUL_ORIENT=1 (Tpd): outp shape [16, C, Ntiles], Ntiles-fast.
        // (Tpd path lands in Task 6; here Std only.)
        int base = ((r * 4 + 0) * Ntiles_k + tileIdx) * C_k + (int)c;
        outp[base + 0 * Ntiles_k * C_k] = V0;
        outp[base + 1 * Ntiles_k * C_k] = V1;
        outp[base + 2 * Ntiles_k * C_k] = V2;
        outp[base + 3 * Ntiles_k * C_k] = V3;
      }
    }
```

- [ ] **Step 4: Rewrite `kWinoOutputSource` with WPT loop**

In `cpp/neuralnet/mlxwinograd.h:207-254`, replace the body with:

```metal
    uint oc_group = thread_position_in_grid.x;
    uint t_group  = thread_position_in_grid.y;

    static_assert(WPT >= 1 && VW >= 1, "WPT and VW must be positive");

    int Ntiles_k = m_shape[1];
    int outC_k   = m_shape[2];
    int H_k      = nhwc[1];
    int W_k      = nhwc[2];
    int tilesY_k = (H_k + 1) / 2;
    int tilesX_k = (W_k + 1) / 2;

    uint oc = oc_group;
    if ((int)oc >= outC_k) return;

    for (int w = 0; w < WPT; w++) {
      int tileIdx = (int)t_group * WPT + w;
      if (tileIdx >= Ntiles_k) break;

      int rem = tileIdx;
      int n   = rem / (tilesY_k * tilesX_k); rem -= n * tilesY_k * tilesX_k;
      int ty  = rem / tilesX_k;
      int tx  = rem % tilesX_k;

      T mm[4][4];
      for (int r = 0; r < 4; r++) {
        for (int c2 = 0; c2 < 4; c2++) {
          int p = r * 4 + c2;
          mm[r][c2] = m[(p * Ntiles_k + tileIdx) * outC_k + (int)oc];
        }
      }
      T tmp[2][4];
      for (int c2 = 0; c2 < 4; c2++) {
        T v0 = mm[0][c2], v1 = mm[1][c2], v2 = mm[2][c2], v3 = mm[3][c2];
        tmp[0][c2] = v0 + v1 + v2;
        tmp[1][c2] = v1 - v2 - v3;
      }
      for (int a = 0; a < 2; a++) {
        T u0 = tmp[a][0], u1 = tmp[a][1], u2 = tmp[a][2], u3 = tmp[a][3];
        T Y0 = u0 + u1 + u2;
        T Y1 = u1 - u2 - u3;
        int oy0 = 2 * ty + a;
        if (oy0 < H_k) {
          int ox0 = 2 * tx + 0;
          if (ox0 < W_k)
            outp[((n * H_k + oy0) * W_k + ox0) * outC_k + (int)oc] = Y0;
          int ox1 = 2 * tx + 1;
          if (ox1 < W_k)
            outp[((n * H_k + oy0) * W_k + ox1) * outC_k + (int)oc] = Y1;
        }
      }
    }
```

- [ ] **Step 5: Run the bit-for-bit tests**

Run: `./runtests "WPT"`
Expected: PASS — WPT=1, 4, 8 produce identical output.

- [ ] **Step 6: Run full regression**

Run: `./runtests && ./runnnlayertests`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add cpp/neuralnet/mlxwinograd.h cpp/tests/testmlxwinograd.cpp
git commit -m "SP4 Task 3: WPT loop in both transform kernels with tail guards

Bit-for-bit equivalence verified for WPT in {1, 4, 8} on b18-shaped inputs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: VW (vector packing) in both transform kernels — Cfast only

**Files:**
- Modify: `cpp/neuralnet/mlxwinograd.h` (both kernels — VW-gated half4 paths)
- Test: `cpp/tests/testmlxwinograd.cpp`

- [ ] **Step 1: Write the failing bit-for-bit equivalence test**

In `cpp/tests/testmlxwinograd.cpp`, add:

```cpp
TEST_CASE("VW=1 vs VW=2 vs VW=4 produce bit-identical input-transform output (fp16, Cfast)") {
  using namespace MLXWinograd;
  using namespace mlx::core;
  // C=64 is divisible by 4 — VW=4 valid.
  std::vector<float> in_data((size_t)2*19*19*64);
  std::mt19937 rng(0x9ABC);
  std::uniform_real_distribution<float> dist(-1, 1);
  for(auto& x : in_data) x = dist(rng);
  array inp = astype(array(in_data.data(), {2, 19, 19, 64}, float32), float16);

  auto runWith = [&](int vw) {
    InputTransform    inCfg;  inCfg.vw = vw;
    OutputUntransform outCfg;
    std::vector<float> w_data((size_t)64*64*9, 0.5f);
    array Uw = makeWinogradWeights(w_data, 64, 64, /*useFP16*/true, MatmulOrient::Std);
    array out = winogradConv2d(inp, Uw, 64, inCfg, outCfg, true, MatmulOrient::Std);
    eval(out);
    return out;
  };

  array out1 = runWith(1), out2 = runWith(2), out4 = runWith(4);
  // half4 packed loads/stores must yield bit-identical results (no FP ops
  // change order — only memory transaction width changes).
  REQUIRE(allclose(out1, out2, 0, 0).item<bool>());
  REQUIRE(allclose(out1, out4, 0, 0).item<bool>());
}
```

(Mirror for output-untransform with same structure — `outCfg.vw = vw`.)

- [ ] **Step 2: Verify the test fails**

Run: `./runtests "VW="`
Expected: VW=2, VW=4 currently dispatch the WPT=1/VW=1 kernel (the path is the same — kernel ignores VW); test PASSES by accident.

Add a deliberate `static_assert(VW == 1, "VW>1 not yet implemented")` at the top of both kernel sources to make VW>1 instantiation a compile-time error. Re-run: expected FAIL with `static_assert`.

- [ ] **Step 3: Implement VW packing in `kWinoInputSource`**

Replace the inner-loop body in `kWinoInputSource` (the per-tile work) with VW-aware loads. The simplest correct implementation: when `VW > 1` is used with `GRID_ORDER == 0` (Cfast), each thread processes `VW` consecutive channels at once. Grid x dim becomes `C/VW`, and each thread iterates `c` from `c_group*VW` to `c_group*VW + VW - 1`.

Update the grid x computation in `winogradConv2d` to `C / vw` when `gridOrder == Cfast && vw > 1` (and require `C % vw == 0` — caller's responsibility, enforced by candidate validity filter in Task 9).

Kernel rewrite — replace the line `uint c = c_group;` with:

```metal
    // VW packing: each thread owns VW consecutive channels along the fast axis.
    // VW=1 -> behaves like Task 3. VW>1 -> grid x = C/VW, each thread loops VW.
    static_assert(GRID_ORDER == 0 || VW == 1, "VW>1 only supported in Cfast (GRID_ORDER=0)");
```

And replace the loop body's single-channel work with a `for (int vc = 0; vc < VW; vc++)` outer wrap, with `c = c_group * VW + vc`:

```metal
    for (int w = 0; w < WPT; w++) {
      int tileIdx = (int)t_group * WPT + w;
      if (tileIdx >= Ntiles_k) break;

      int rem = tileIdx;
      int n   = rem / (tilesY_k * tilesX_k); rem -= n * tilesY_k * tilesX_k;
      int ty  = rem / tilesX_k;
      int tx  = rem % tilesX_k;

      for (int vc = 0; vc < VW; vc++) {
        int c = (int)c_group * VW + vc;
        if (c >= C_k) break;
        T d[4][4];
        for (int i = 0; i < 4; i++) {
          int iy = 2 * ty - 1 + i;
          for (int j = 0; j < 4; j++) {
            int ix = 2 * tx - 1 + j;
            if (iy < 0 || iy >= H_k || ix < 0 || ix >= W_k) {
              d[i][j] = (T)0.0f;
            } else {
              d[i][j] = inp[((n * H_k + iy) * W_k + ix) * C_k + c];
            }
          }
        }
        T tmp[4][4];
        for (int j = 0; j < 4; j++) {
          T v0 = d[0][j], v1 = d[1][j], v2 = d[2][j], v3 = d[3][j];
          tmp[0][j] = v0 - v2;
          tmp[1][j] = v1 + v2;
          tmp[2][j] = v2 - v1;
          tmp[3][j] = v1 - v3;
        }
        for (int r = 0; r < 4; r++) {
          T u0 = tmp[r][0], u1 = tmp[r][1], u2 = tmp[r][2], u3 = tmp[r][3];
          T V0 = u0 - u2;
          T V1 = u1 + u2;
          T V2 = u2 - u1;
          T V3 = u1 - u3;
          int base = ((r * 4 + 0) * Ntiles_k + tileIdx) * C_k + c;
          outp[base + 0 * Ntiles_k * C_k] = V0;
          outp[base + 1 * Ntiles_k * C_k] = V1;
          outp[base + 2 * Ntiles_k * C_k] = V2;
          outp[base + 3 * Ntiles_k * C_k] = V3;
        }
      }
    }
```

(The Metal compiler can fold `inp[base+0..3]` into a `half4` load when `VW>=4` and `C_k` is suitably aligned; we don't need explicit `half4*` casts. If profiling later shows the compiler is not vectorizing, we add explicit `*(device const half4*)(...)` loads as a separate optimization — out of scope here.)

- [ ] **Step 4: Update grid x in `winogradConv2d` for VW>1 in Cfast mode**

In `cpp/neuralnet/mlxwinograd.h`, replace the `gridX_in` and `gridX_out` lines from Task 2 with:

```cpp
int gridX_in = (inCfg.gridOrder == GridOrder::Cfast)
  ? ((C + inCfg.vw - 1) / inCfg.vw)
  : Ntiles;
// ...
int gridX_out = (outCfg.gridOrder == GridOrder::Cfast)
  ? ((Cout + outCfg.vw - 1) / outCfg.vw)
  : Ntiles;
```

- [ ] **Step 5: Mirror VW packing in `kWinoOutputSource`**

Apply the same `for (int vc = 0; vc < VW; vc++)` outer wrap to the output kernel, with `oc = oc_group * VW + vc`. Body identical to Task 3's output kernel inside the new wrap.

- [ ] **Step 6: Drop the `static_assert(VW == 1)` and run the equivalence tests**

Remove the `static_assert(VW == 1, …)` from both kernels.

Run: `./runtests "VW="`
Expected: PASS for VW in {1, 2, 4}.

- [ ] **Step 7: Run full regression**

Run: `./runtests && ./runnnlayertests`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add cpp/neuralnet/mlxwinograd.h cpp/tests/testmlxwinograd.cpp
git commit -m "SP4 Task 4: VW (vector-width) packing in both transform kernels — Cfast only

VW in {1, 2, 4} produces bit-identical fp16 output. VW>1 in Tfast is
rejected at compile time via static_assert.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: gridOrder Tfast mode in both kernels

**Files:**
- Modify: `cpp/neuralnet/mlxwinograd.h` (both kernels — GRID_ORDER=1 paths)
- Test: `cpp/tests/testmlxwinograd.cpp`

- [ ] **Step 1: Write the failing roundtrip test**

In `cpp/tests/testmlxwinograd.cpp`:

```cpp
TEST_CASE("gridOrder Cfast vs Tfast produce identical end-to-end output (fp32)") {
  using namespace MLXWinograd;
  using namespace mlx::core;
  std::vector<float> in_data((size_t)2*19*19*64);
  std::mt19937 rng(0xDEAD);
  std::uniform_real_distribution<float> dist(-1, 1);
  for(auto& x : in_data) x = dist(rng);
  array inp(in_data.data(), {2, 19, 19, 64}, float32);
  std::vector<float> w_data((size_t)64*64*9);
  for(auto& x : w_data) x = dist(rng);
  array Uw = makeWinogradWeights(w_data, 64, 64, false, MatmulOrient::Std);

  InputTransform    inC;  inC.gridOrder  = GridOrder::Cfast;
  OutputUntransform outC; outC.gridOrder = GridOrder::Cfast;
  InputTransform    inT;  inT.gridOrder  = GridOrder::Tfast;
  OutputUntransform outT; outT.gridOrder = GridOrder::Tfast;

  array outCfast = winogradConv2d(inp, Uw, 64, inC, outC, false, MatmulOrient::Std);
  array outTfast = winogradConv2d(inp, Uw, 64, inT, outT, false, MatmulOrient::Std);
  eval(outCfast); eval(outTfast);
  // Same FP ops, same order — must be bit-identical.
  REQUIRE(allclose(outCfast, outTfast, 0, 0).item<bool>());
}
```

- [ ] **Step 2: Verify it fails**

Run: `./runtests "gridOrder"`
Expected: FAIL — current kernels assume `GRID_ORDER=0`; with `GRID_ORDER=1` the grid is `(Ntiles, C, 1)` but threads still use `c = c_group * VW + vc` etc., producing garbage.

- [ ] **Step 3: Implement Tfast branching in `kWinoInputSource`**

Wrap the current Cfast loop body with `if (GRID_ORDER == 0) { … } else { … }`. In the Tfast branch, swap roles:

```metal
    if (GRID_ORDER == 0) {
      // (Cfast branch — exact body from Task 4.)
      uint c_group_ = thread_position_in_grid.x;
      uint t_group_ = thread_position_in_grid.y;
      // ... existing Task 4 body using c_group_, t_group_ ...
    } else {
      // Tfast: grid x = Ntiles, grid y = ceil(C/WPT). VW must be 1
      // (enforced by candidate filter).
      uint t_group_ = thread_position_in_grid.x;
      uint c_group_ = thread_position_in_grid.y;
      static_assert(VW == 1, "Tfast requires VW=1");
      int tileIdx = (int)t_group_;
      if (tileIdx >= Ntiles_k) return;
      for (int w = 0; w < WPT; w++) {
        int c = (int)c_group_ * WPT + w;
        if (c >= C_k) break;

        int rem = tileIdx;
        int n   = rem / (tilesY_k * tilesX_k); rem -= n * tilesY_k * tilesX_k;
        int ty  = rem / tilesX_k;
        int tx  = rem % tilesX_k;

        T d[4][4];
        for (int i = 0; i < 4; i++) {
          int iy = 2 * ty - 1 + i;
          for (int j = 0; j < 4; j++) {
            int ix = 2 * tx - 1 + j;
            d[i][j] = (iy < 0 || iy >= H_k || ix < 0 || ix >= W_k)
              ? (T)0.0f
              : inp[((n * H_k + iy) * W_k + ix) * C_k + c];
          }
        }
        T tmp[4][4];
        for (int j = 0; j < 4; j++) {
          T v0=d[0][j], v1=d[1][j], v2=d[2][j], v3=d[3][j];
          tmp[0][j]=v0-v2; tmp[1][j]=v1+v2; tmp[2][j]=v2-v1; tmp[3][j]=v1-v3;
        }
        for (int r = 0; r < 4; r++) {
          T u0=tmp[r][0], u1=tmp[r][1], u2=tmp[r][2], u3=tmp[r][3];
          T V0=u0-u2, V1=u1+u2, V2=u2-u1, V3=u1-u3;
          int base = ((r * 4 + 0) * Ntiles_k + tileIdx) * C_k + c;
          outp[base + 0 * Ntiles_k * C_k] = V0;
          outp[base + 1 * Ntiles_k * C_k] = V1;
          outp[base + 2 * Ntiles_k * C_k] = V2;
          outp[base + 3 * Ntiles_k * C_k] = V3;
        }
      }
    }
```

(Note: the `outp` write layout is unchanged — Tfast only swaps which thread does which (c, tileIdx) pair, not the on-disk layout. matmulOrient handles layout in Task 6.)

- [ ] **Step 4: Mirror Tfast in `kWinoOutputSource`**

Same wrap with role swap: `t_group = thread_position_in_grid.x`, `oc_group = thread_position_in_grid.y`, inner loop iterates `oc` over `WPT` values, `tileIdx = t_group`.

- [ ] **Step 5: Update grid y in `winogradConv2d` for Tfast**

Already handled in Task 2's `gridX_in/gridY_in` ternaries — just verify the `Tfast` branch maps grid x → `Ntiles` and grid y → `ceil(C/WPT)`. No code change if Task 2 was written correctly.

- [ ] **Step 6: Run the roundtrip test**

Run: `./runtests "gridOrder"`
Expected: PASS — Cfast and Tfast produce bit-identical output.

- [ ] **Step 7: Run full regression**

Run: `./runtests && ./runnnlayertests`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add cpp/neuralnet/mlxwinograd.h cpp/tests/testmlxwinograd.cpp
git commit -m "SP4 Task 5: gridOrder Tfast branch in both transform kernels

Tfast swaps thread-to-(c, tile) mapping; output layout unchanged. VW=1
enforced via static_assert. Cfast and Tfast produce bit-identical results.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: matmulOrient Tpd mode (kernels + host filter)

**Files:**
- Modify: `cpp/neuralnet/mlxwinograd.h` (both kernels — MATMUL_ORIENT=1 paths; `makeWinogradWeights` filter layout)
- Test: `cpp/tests/testmlxwinograd.cpp`

- [ ] **Step 1: Write the failing end-to-end equivalence test**

In `cpp/tests/testmlxwinograd.cpp`:

```cpp
TEST_CASE("matmulOrient Std vs Tpd produce close end-to-end output (fp32, rtol 1e-5)") {
  using namespace MLXWinograd;
  using namespace mlx::core;
  std::vector<float> in_data((size_t)2*19*19*64);
  std::mt19937 rng(0xCAFE);
  std::uniform_real_distribution<float> dist(-1, 1);
  for(auto& x : in_data) x = dist(rng);
  array inp(in_data.data(), {2, 19, 19, 64}, float32);
  std::vector<float> w_data((size_t)64*64*9);
  for(auto& x : w_data) x = dist(rng);

  InputTransform inCfg; OutputUntransform outCfg;
  array UwStd = makeWinogradWeights(w_data, 64, 64, false, MatmulOrient::Std);
  array UwTpd = makeWinogradWeights(w_data, 64, 64, false, MatmulOrient::Tpd);
  array outStd = winogradConv2d(inp, UwStd, 64, inCfg, outCfg, false, MatmulOrient::Std);
  array outTpd = winogradConv2d(inp, UwTpd, 64, inCfg, outCfg, false, MatmulOrient::Tpd);
  eval(outStd); eval(outTpd);
  // FP-reordering tolerance — matmul reduces in a different inner-loop order.
  REQUIRE(allclose(outStd, outTpd, /*rtol*/1e-5, /*atol*/1e-5).item<bool>());
}
```

(Note: Std vs Tpd cannot be bit-identical — matmul axis swap changes accumulation order. Hence `rtol=1e-5` instead of zero.)

- [ ] **Step 2: Verify it fails**

Run: `./runtests "matmulOrient"`
Expected: FAIL — current kernels write/read in Std layout regardless of `MATMUL_ORIENT`.

- [ ] **Step 3: Add Tpd write layout to `kWinoInputSource`**

In `kWinoInputSource`, where the Std branch writes:

```metal
int base = ((r * 4 + 0) * Ntiles_k + tileIdx) * C_k + c;
outp[base + 0 * Ntiles_k * C_k] = V0;
```

replace with:

```metal
if (MATMUL_ORIENT == 0) {
  // Std: outp [16, Ntiles, C], C-fast.
  int base = ((r * 4 + 0) * Ntiles_k + tileIdx) * C_k + c;
  outp[base + 0 * Ntiles_k * C_k] = V0;
  outp[base + 1 * Ntiles_k * C_k] = V1;
  outp[base + 2 * Ntiles_k * C_k] = V2;
  outp[base + 3 * Ntiles_k * C_k] = V3;
} else {
  // Tpd: outp [16, C, Ntiles], Ntiles-fast.
  int base = ((r * 4 + 0) * C_k + c) * Ntiles_k + tileIdx;
  outp[base + 0 * C_k * Ntiles_k] = V0;
  outp[base + 1 * C_k * Ntiles_k] = V1;
  outp[base + 2 * C_k * Ntiles_k] = V2;
  outp[base + 3 * C_k * Ntiles_k] = V3;
}
```

Apply this swap in **both** the Cfast and Tfast branches of the kernel (each has its own write block from Tasks 4-5).

- [ ] **Step 4: Add Tpd read layout to `kWinoOutputSource`**

The output untransform reads `m[(p * Ntiles_k + tileIdx) * outC_k + oc]` (Std). For Tpd it should read `m[(p * outC_k + oc) * Ntiles_k + tileIdx]`. In `kWinoOutputSource`, where the inner read is:

```metal
mm[r][c2] = m[(p * Ntiles_k + tileIdx) * outC_k + (int)oc];
```

replace with:

```metal
if (MATMUL_ORIENT == 0) {
  mm[r][c2] = m[(p * Ntiles_k + tileIdx) * outC_k + (int)oc];
} else {
  mm[r][c2] = m[(p * outC_k + (int)oc) * Ntiles_k + tileIdx];
}
```

Also update the shape reads at the top of the kernel — Std reads `Ntiles_k = m_shape[1]; outC_k = m_shape[2]`; Tpd reads `outC_k = m_shape[1]; Ntiles_k = m_shape[2]`:

```metal
int Ntiles_k = (MATMUL_ORIENT == 0) ? m_shape[1] : m_shape[2];
int outC_k   = (MATMUL_ORIENT == 0) ? m_shape[2] : m_shape[1];
```

- [ ] **Step 5: Confirm `winogradConv2d` orient-dispatched matmul is correct**

Re-read the Task 2 implementation; verify the conditional:

```cpp
mx::array m = (matmulOrient == MatmulOrient::Std)
  ? mx::matmul(t, Uw)
  : mx::matmul(Uw, t);
```

is correct. For Tpd: `Uw` is `[16, Cout, C]`, `t` is `[16, C, Ntiles]` (from kernel writing to Tpd layout), product is `[16, Cout, Ntiles]`. ✓

Verify `inOutShape` ternary in Task 2 already covers Tpd. ✓

- [ ] **Step 6: Run the equivalence test**

Run: `./runtests "matmulOrient"`
Expected: PASS — Std and Tpd produce equivalent output within fp tolerance.

- [ ] **Step 7: Run full regression**

Run: `./runtests && ./runnnlayertests`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add cpp/neuralnet/mlxwinograd.h cpp/tests/testmlxwinograd.cpp
git commit -m "SP4 Task 6: matmulOrient Tpd path in kernels + host filter

Std and Tpd produce numerically-equivalent end-to-end output (rtol 1e-5).
Filter layout, intermediate matmul shape, and output untransform read
layout all swap together.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Expanded candidate enumeration with validity filtering

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:374-411` (candidate sets and builders)

- [ ] **Step 1: Write failing test for enumeration size and validity**

In `cpp/tests/testmlxwinotuner.cpp`:

```cpp
TEST_CASE("SP4 candidate enumeration: expanded sets and validity filtering") {
  // Expose the candidate builder via a test-only forward declaration if it's
  // anonymous-namespace static. Or add a public testing entry point in
  // MLXWinogradTuner namespace: vector<...> buildInputCandidatesForTesting(bool full, int C, int Ntiles, GridOrder go);

  auto cands = MLXWinogradTuner::buildInputCandidatesForTesting(
      /*full*/true, /*C*/64, /*Ntiles*/200, MLXWinograd::GridOrder::Cfast);
  // Sanity bounds.
  REQUIRE(cands.size() > 100);    // Should be hundreds after filtering.
  REQUIRE(cands.size() < 2500);   // But bounded by validity.
  // All candidates satisfy tg0*tg1 <= 1024.
  for(const auto& c : cands)
    REQUIRE(c.tg0 * c.tg1 <= 1024);
  // No vw=4 candidate has C % 4 != 0  (C=64, always valid; check on C=66 in next case).
  // ...
  auto cands_C66 = MLXWinogradTuner::buildInputCandidatesForTesting(
      true, /*C*/66, /*Ntiles*/200, MLXWinograd::GridOrder::Cfast);
  for(const auto& c : cands_C66)
    if(c.vw == 4) FAIL("vw=4 candidate should have been filtered out for C=66");
}
```

- [ ] **Step 2: Verify failure**

Run: `./runtests "candidate enumeration"`
Expected: FAIL — `buildInputCandidatesForTesting` doesn't exist; existing builder ignores wpt/vw/gridOrder.

- [ ] **Step 3: Replace candidate-value tables with expanded sets**

In `cpp/neuralnet/mlxwinotuner.cpp:374-393`, replace with:

```cpp
static const std::vector<int>& inputTg0Values(bool full) {
  static const std::vector<int> v = {1,2,4,8,16,24,32,48,64,96,128,160,192,256,384,512,1024};
  (void)full;
  return v;
}
static const std::vector<int>& inputTg1Values(bool full) {
  static const std::vector<int> vFull    = {1,2,4,5,8,10,16,20,25,32,40,50,64,100,128};
  static const std::vector<int> vNonFull = {1,2,4,8,10,16,25,32,50,100};
  return full ? vFull : vNonFull;
}
static const std::vector<int>& outputTg0Values(bool full) {
  // Mirror input set so tg0 is treated symmetrically.
  static const std::vector<int> v = {1,2,4,8,16,24,32,48,64,96,128,160,192,256,384,512,1024};
  (void)full;
  return v;
}
static const std::vector<int>& outputTg1Values(bool full) {
  // SP3 non-full inconsistency (skipped 8) is fixed here.
  static const std::vector<int> vFull    = {1,2,4,5,8,10,16,20,25,32,40,50,64,100,128};
  static const std::vector<int> vNonFull = {1,2,4,8,10,16,25,32,50,100};
  return full ? vFull : vNonFull;
}
static const std::vector<int>& wptValues()  { static const std::vector<int> v={1,2,4,8}; return v; }
static const std::vector<int>& vwValues()   { static const std::vector<int> v={1,2,4};   return v; }
static const std::vector<MLXWinograd::GridOrder>& gridOrderValues() {
  static const std::vector<MLXWinograd::GridOrder> v = {
    MLXWinograd::GridOrder::Cfast, MLXWinograd::GridOrder::Tfast
  };
  return v;
}
```

- [ ] **Step 4: Replace `buildInputCandidates` / `buildOutputCandidates` with model-aware builders**

In `cpp/neuralnet/mlxwinotuner.cpp:395-411`, replace with:

```cpp
// Returns true iff (tg0, tg1, wpt, vw, gridOrder) is structurally valid
// AND vw divides the fast-axis dim of the current stage shape.
static bool isInputCandidateValid(int tg0, int tg1, int wpt, int vw,
                                  MLXWinograd::GridOrder go,
                                  int C, int Ntiles) {
  if(tg0 * tg1 > 1024) return false;
  if(go == MLXWinograd::GridOrder::Cfast) {
    if(vw > 1 && (C % vw) != 0) return false;
  } else {
    // Tfast: vw must be 1 (kernel static_assert).
    if(vw != 1) return false;
  }
  return true;
}
static bool isOutputCandidateValid(int tg0, int tg1, int wpt, int vw,
                                   MLXWinograd::GridOrder go,
                                   int outC, int Ntiles) {
  if(tg0 * tg1 > 1024) return false;
  if(go == MLXWinograd::GridOrder::Cfast) {
    if(vw > 1 && (outC % vw) != 0) return false;
  } else {
    if(vw != 1) return false;
  }
  return true;
}

static std::vector<MLXWinograd::InputTransform>
buildInputCandidates(bool full, int C, int Ntiles, MLXWinograd::GridOrder go) {
  std::vector<MLXWinograd::InputTransform> out;
  for(int tg0 : inputTg0Values(full))
  for(int tg1 : inputTg1Values(full))
  for(int wpt : wptValues())
  for(int vw  : vwValues()) {
    if(!isInputCandidateValid(tg0, tg1, wpt, vw, go, C, Ntiles)) continue;
    out.push_back({tg0, tg1, wpt, vw, go});
  }
  return out;
}
static std::vector<MLXWinograd::OutputUntransform>
buildOutputCandidates(bool full, int outC, int Ntiles, MLXWinograd::GridOrder go) {
  std::vector<MLXWinograd::OutputUntransform> out;
  for(int tg0 : outputTg0Values(full))
  for(int tg1 : outputTg1Values(full))
  for(int wpt : wptValues())
  for(int vw  : vwValues()) {
    if(!isOutputCandidateValid(tg0, tg1, wpt, vw, go, outC, Ntiles)) continue;
    out.push_back({tg0, tg1, wpt, vw, go});
  }
  return out;
}
```

- [ ] **Step 5: Add the test-only forward declarations**

In `cpp/neuralnet/mlxwinotuner.h`, inside `namespace MLXWinogradTuner`, add:

```cpp
  // Test-only — exposed for unit tests. Not part of the stable API.
  std::vector<MLXWinograd::InputTransform>
  buildInputCandidatesForTesting(bool full, int C, int Ntiles, MLXWinograd::GridOrder go);
  std::vector<MLXWinograd::OutputUntransform>
  buildOutputCandidatesForTesting(bool full, int outC, int Ntiles, MLXWinograd::GridOrder go);
```

In `cpp/neuralnet/mlxwinotuner.cpp`, after the anonymous-namespace `buildInputCandidates`, add at file scope:

```cpp
std::vector<MLXWinograd::InputTransform>
MLXWinogradTuner::buildInputCandidatesForTesting(bool full, int C, int Ntiles, MLXWinograd::GridOrder go) {
  return buildInputCandidates(full, C, Ntiles, go);
}
std::vector<MLXWinograd::OutputUntransform>
MLXWinogradTuner::buildOutputCandidatesForTesting(bool full, int outC, int Ntiles, MLXWinograd::GridOrder go) {
  return buildOutputCandidates(full, outC, Ntiles, go);
}
```

- [ ] **Step 6: Run the test**

Run: `./runtests "candidate enumeration"`
Expected: PASS — counts and validity hold.

- [ ] **Step 7: Run full regression**

Run: `./runtests`
Expected: all pass. (Tuner still has the SP3 flat search calling the old `buildInputCandidates(full)` signature — fix that next.)

- [ ] **Step 8: Update existing call sites in tuner**

In `cpp/neuralnet/mlxwinotuner.cpp:421-465`, update `searchInputTransform` / `searchOutputUntransform` to call the new model-aware builders with the seed's `gridOrder` and a representative C/Ntiles. This is temporary scaffolding — Task 11 replaces the whole driver — but keeps things compiling:

```cpp
auto candidates = buildInputCandidates(full,
    mi.trunkNumChannels,           // representative C
    N * ((H+1)/2) * ((W+1)/2),     // Ntiles
    seedCfg.gridOrder);
```

Same for `searchOutputUntransform`.

- [ ] **Step 9: Run full regression again**

Run: `./runtests && ./runnnlayertests`
Expected: all pass.

- [ ] **Step 10: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp cpp/tests/testmlxwinotuner.cpp
git commit -m "SP4 Task 7: expanded candidate sets + validity filtering

tg0: 8 -> 17 values; tg1: 7 -> 15 values; adds wpt/vw/gridOrder axes.
Per-model validity filter prunes (vw | fast-axis) and (Tfast => vw=1).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Joint pass A — `(wpt, vw)` 2-D sweep with top-3 carry-through

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (new helper `jointPassA_Input` / `jointPassA_Output`)

- [ ] **Step 1: Write failing test**

In `cpp/tests/testmlxwinotuner.cpp`:

```cpp
TEST_CASE("Joint pass A returns top-3 (wpt, vw) configs sorted by score") {
  MLXWinogradTuner::ModelInfoForTuning mi;
  mi.trunkNumChannels = 64;
  mi.midNumChannels = 64;
  mi.maxConvChannels3x3 = 64;
  mi.modelVersion = 14;

  auto top3 = MLXWinogradTuner::jointPassA_InputForTesting(
      /*N*/1, /*H*/19, /*W*/19, mi,
      /*go*/MLXWinograd::GridOrder::Cfast,
      /*useFP16*/false);
  REQUIRE(top3.size() <= 3);
  REQUIRE(top3.size() >= 1);
  // Sorted ascending by score.
  for(size_t i = 1; i < top3.size(); i++)
    REQUIRE(top3[i-1].scoreMs <= top3[i].scoreMs);
}
```

- [ ] **Step 2: Verify it fails**

Run: `./runtests "Joint pass A"`
Expected: FAIL — function doesn't exist.

- [ ] **Step 3: Implement `jointPassA_Input`**

In `cpp/neuralnet/mlxwinotuner.cpp`, add near the existing search helpers:

```cpp
namespace {

struct WptVwScore {
  int wpt;
  int vw;
  double scoreMs;
};

// Joint pass A: at SP3-default (tg0=32, tg1=1), sweep all valid (wpt, vw)
// pairs for the input transform under the given gridOrder. Returns top-3
// by score ascending. If top-3 cluster within 2% of best, collapses to top-1.
static std::vector<WptVwScore>
jointPassA_Input(int N, int H, int W,
                 const MLXWinogradTuner::ModelInfoForTuning& mi,
                 MLXWinograd::GridOrder go,
                 bool useFP16, Logger* logger) {
  int Ntiles = N * ((H+1)/2) * ((W+1)/2);
  std::vector<WptVwScore> scored;
  for(int wpt : wptValues())
  for(int vw  : vwValues()) {
    if(!isInputCandidateValid(/*tg0*/32, /*tg1*/1, wpt, vw, go, mi.trunkNumChannels, Ntiles))
      continue;
    MLXWinograd::InputTransform cfg = {32, 1, wpt, vw, go};
    double ms;
    try {
      ms = scoreInputTransform(cfg, N, H, W, mi, useFP16);
    } catch(const std::exception& e) {
      if(logger) logger->write(Global::strprintf(
        "  jointA inp wpt=%d vw=%d FAILED: %s", wpt, vw, e.what()));
      ms = std::numeric_limits<double>::infinity();
    }
    if(logger) logger->write(Global::strprintf(
      "  jointA inp wpt=%d vw=%d  meanMs=%.4f", wpt, vw, ms));
    scored.push_back({wpt, vw, ms});
  }
  std::sort(scored.begin(), scored.end(),
            [](const WptVwScore& a, const WptVwScore& b){ return a.scoreMs < b.scoreMs; });
  std::vector<WptVwScore> top3;
  for(size_t i = 0; i < scored.size() && top3.size() < 3; i++) top3.push_back(scored[i]);
  // Collapse if within 2% of best.
  if(top3.size() > 1) {
    double best = top3[0].scoreMs;
    if(best > 0 && (top3.back().scoreMs - best) / best < 0.02) {
      top3.resize(1);
      if(logger) logger->write("  jointA inp top-3 within 2% — collapsing to top-1");
    }
  }
  return top3;
}

// Same shape for output untransform.
static std::vector<WptVwScore>
jointPassA_Output(int N, int H, int W,
                  const MLXWinogradTuner::ModelInfoForTuning& mi,
                  MLXWinograd::GridOrder go,
                  bool useFP16, Logger* logger) {
  int Ntiles = N * ((H+1)/2) * ((W+1)/2);
  std::vector<WptVwScore> scored;
  for(int wpt : wptValues())
  for(int vw  : vwValues()) {
    if(!isOutputCandidateValid(32, 1, wpt, vw, go, mi.trunkNumChannels, Ntiles))
      continue;
    MLXWinograd::OutputUntransform cfg = {32, 1, wpt, vw, go};
    double ms;
    try {
      ms = scoreOutputUntransform(cfg, N, H, W, mi, useFP16);
    } catch(const std::exception& e) {
      if(logger) logger->write(Global::strprintf(
        "  jointA out wpt=%d vw=%d FAILED: %s", wpt, vw, e.what()));
      ms = std::numeric_limits<double>::infinity();
    }
    if(logger) logger->write(Global::strprintf(
      "  jointA out wpt=%d vw=%d  meanMs=%.4f", wpt, vw, ms));
    scored.push_back({wpt, vw, ms});
  }
  std::sort(scored.begin(), scored.end(),
            [](const WptVwScore& a, const WptVwScore& b){ return a.scoreMs < b.scoreMs; });
  std::vector<WptVwScore> top3;
  for(size_t i = 0; i < scored.size() && top3.size() < 3; i++) top3.push_back(scored[i]);
  if(top3.size() > 1) {
    double best = top3[0].scoreMs;
    if(best > 0 && (top3.back().scoreMs - best) / best < 0.02) {
      top3.resize(1);
      if(logger) logger->write("  jointA out top-3 within 2% — collapsing to top-1");
    }
  }
  return top3;
}

} // namespace
```

- [ ] **Step 4: Expose testing forward-decl**

In `cpp/neuralnet/mlxwinotuner.h`, add inside `MLXWinogradTuner`:

```cpp
  struct WptVwScoreForTesting { int wpt; int vw; double scoreMs; };
  std::vector<WptVwScoreForTesting>
  jointPassA_InputForTesting(int N, int H, int W,
                             const ModelInfoForTuning& mi,
                             MLXWinograd::GridOrder go,
                             bool useFP16);
```

And in `mlxwinotuner.cpp`:

```cpp
std::vector<MLXWinogradTuner::WptVwScoreForTesting>
MLXWinogradTuner::jointPassA_InputForTesting(
    int N, int H, int W,
    const ModelInfoForTuning& mi,
    MLXWinograd::GridOrder go,
    bool useFP16) {
  auto top = jointPassA_Input(N, H, W, mi, go, useFP16, nullptr);
  std::vector<WptVwScoreForTesting> out;
  for(auto& s : top) out.push_back({s.wpt, s.vw, s.scoreMs});
  return out;
}
```

- [ ] **Step 5: Run the test**

Run: `./runtests "Joint pass A"`
Expected: PASS — top-3 returned, sorted ascending.

- [ ] **Step 6: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp cpp/tests/testmlxwinotuner.cpp
git commit -m "SP4 Task 8: Joint pass A — (wpt, vw) sweep with top-3 carry-through

At fixed (tg0=32, tg1=1), sweeps all valid (wpt, vw) under a given
gridOrder. Returns top-3 by score; collapses to top-1 when scores cluster
within 2%.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Joint pass B — `(tg0, tg1)` sweep over each top-3 `(wpt, vw)`

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp`

- [ ] **Step 1: Implement `jointPassB_Input`**

In `cpp/neuralnet/mlxwinotuner.cpp`, in the anonymous namespace, add:

```cpp
// Joint pass B: for each top-(wpt, vw) from pass A, sweep (tg0, tg1) and
// retime. Returns the best (tg0, tg1, wpt, vw) overall for this stage.
static MLXWinograd::InputTransform
jointPassB_Input(const std::vector<WptVwScore>& topWptVw,
                 int N, int H, int W,
                 const MLXWinogradTuner::ModelInfoForTuning& mi,
                 MLXWinograd::GridOrder go,
                 bool full, bool useFP16, Logger* logger) {
  int Ntiles = N * ((H+1)/2) * ((W+1)/2);
  MLXWinograd::InputTransform best = {32, 1, 1, 1, go};
  double bestMs = std::numeric_limits<double>::infinity();

  for(const auto& wv : topWptVw) {
    // Build the (tg0, tg1) candidate list under this (wpt, vw, go).
    std::vector<MLXWinograd::InputTransform> cands;
    for(int tg0 : inputTg0Values(full))
    for(int tg1 : inputTg1Values(full)) {
      if(!isInputCandidateValid(tg0, tg1, wv.wpt, wv.vw, go, mi.trunkNumChannels, Ntiles))
        continue;
      cands.push_back({tg0, tg1, wv.wpt, wv.vw, go});
    }
    shuffleVec(cands, 0xDEADBEEFu ^ (uint32_t)(wv.wpt * 31 + wv.vw));

    for(const auto& c : cands) {
      double ms;
      try {
        ms = scoreInputTransform(c, N, H, W, mi, useFP16);
      } catch(const std::exception& e) {
        if(logger) logger->write(Global::strprintf(
          "  jointB inp tg0=%d tg1=%d wpt=%d vw=%d FAILED: %s",
          c.tg0, c.tg1, c.wpt, c.vw, e.what()));
        continue;
      }
      if(logger) logger->write(Global::strprintf(
        "  jointB inp tg0=%d tg1=%d wpt=%d vw=%d  meanMs=%.4f",
        c.tg0, c.tg1, c.wpt, c.vw, ms));
      if(ms < bestMs) { bestMs = ms; best = c; }
    }
  }
  return best;
}

// Same shape for output.
static MLXWinograd::OutputUntransform
jointPassB_Output(const std::vector<WptVwScore>& topWptVw,
                  int N, int H, int W,
                  const MLXWinogradTuner::ModelInfoForTuning& mi,
                  MLXWinograd::GridOrder go,
                  bool full, bool useFP16, Logger* logger) {
  int Ntiles = N * ((H+1)/2) * ((W+1)/2);
  MLXWinograd::OutputUntransform best = {32, 1, 1, 1, go};
  double bestMs = std::numeric_limits<double>::infinity();

  for(const auto& wv : topWptVw) {
    std::vector<MLXWinograd::OutputUntransform> cands;
    for(int tg0 : outputTg0Values(full))
    for(int tg1 : outputTg1Values(full)) {
      if(!isOutputCandidateValid(tg0, tg1, wv.wpt, wv.vw, go, mi.trunkNumChannels, Ntiles))
        continue;
      cands.push_back({tg0, tg1, wv.wpt, wv.vw, go});
    }
    shuffleVec(cands, 0xCAFEBABEu ^ (uint32_t)(wv.wpt * 31 + wv.vw));

    for(const auto& c : cands) {
      double ms;
      try {
        ms = scoreOutputUntransform(c, N, H, W, mi, useFP16);
      } catch(const std::exception& e) {
        if(logger) logger->write(Global::strprintf(
          "  jointB out tg0=%d tg1=%d wpt=%d vw=%d FAILED: %s",
          c.tg0, c.tg1, c.wpt, c.vw, e.what()));
        continue;
      }
      if(logger) logger->write(Global::strprintf(
        "  jointB out tg0=%d tg1=%d wpt=%d vw=%d  meanMs=%.4f",
        c.tg0, c.tg1, c.wpt, c.vw, ms));
      if(ms < bestMs) { bestMs = ms; best = c; }
    }
  }
  return best;
}
```

- [ ] **Step 2: Confirm it compiles**

Run: `cd cpp && ninja runtests`
Expected: success — function defined; not yet called.

- [ ] **Step 3: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.cpp
git commit -m "SP4 Task 9: Joint pass B — (tg0, tg1) sweep over top-3 (wpt, vw)

Per stage, retimes (tg0, tg1) under each top-(wpt, vw) and picks the
globally-best 4-tuple. Catches dispatch errors per candidate (e.g.,
tg0=1024 on M1 variants with smaller threadgroup mem) and continues.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Refinement (coordinate descent around the winner)

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp`

- [ ] **Step 1: Implement `refineInput` / `refineOutput`**

In the anonymous namespace:

```cpp
// Refinement: coordinate-descent one axis at a time around the winner.
// One pass per axis. Returns the (possibly improved) config.
static MLXWinograd::InputTransform
refineInput(MLXWinograd::InputTransform winner,
            int N, int H, int W,
            const MLXWinogradTuner::ModelInfoForTuning& mi,
            bool full, bool useFP16, Logger* logger) {
  int Ntiles = N * ((H+1)/2) * ((W+1)/2);
  double bestMs = scoreInputTransform(winner, N, H, W, mi, useFP16);

  auto trySwap = [&](MLXWinograd::InputTransform cand, const char* axis) {
    if(!isInputCandidateValid(cand.tg0, cand.tg1, cand.wpt, cand.vw,
                              cand.gridOrder, mi.trunkNumChannels, Ntiles))
      return;
    double ms;
    try { ms = scoreInputTransform(cand, N, H, W, mi, useFP16); }
    catch(const std::exception&) { return; }
    if(logger) logger->write(Global::strprintf(
      "  refine inp [%s] tg0=%d tg1=%d wpt=%d vw=%d  meanMs=%.4f",
      axis, cand.tg0, cand.tg1, cand.wpt, cand.vw, ms));
    if(ms < bestMs) { bestMs = ms; winner = cand; }
  };

  for(int tg0 : inputTg0Values(full)) if(tg0 != winner.tg0) {
    auto cand = winner; cand.tg0 = tg0; trySwap(cand, "tg0");
  }
  for(int tg1 : inputTg1Values(full)) if(tg1 != winner.tg1) {
    auto cand = winner; cand.tg1 = tg1; trySwap(cand, "tg1");
  }
  for(int wpt : wptValues()) if(wpt != winner.wpt) {
    auto cand = winner; cand.wpt = wpt; trySwap(cand, "wpt");
  }
  for(int vw : vwValues()) if(vw != winner.vw) {
    auto cand = winner; cand.vw = vw; trySwap(cand, "vw");
  }
  return winner;
}

// Same shape for output.
static MLXWinograd::OutputUntransform
refineOutput(MLXWinograd::OutputUntransform winner,
             int N, int H, int W,
             const MLXWinogradTuner::ModelInfoForTuning& mi,
             bool full, bool useFP16, Logger* logger) {
  int Ntiles = N * ((H+1)/2) * ((W+1)/2);
  double bestMs = scoreOutputUntransform(winner, N, H, W, mi, useFP16);

  auto trySwap = [&](MLXWinograd::OutputUntransform cand, const char* axis) {
    if(!isOutputCandidateValid(cand.tg0, cand.tg1, cand.wpt, cand.vw,
                               cand.gridOrder, mi.trunkNumChannels, Ntiles))
      return;
    double ms;
    try { ms = scoreOutputUntransform(cand, N, H, W, mi, useFP16); }
    catch(const std::exception&) { return; }
    if(logger) logger->write(Global::strprintf(
      "  refine out [%s] tg0=%d tg1=%d wpt=%d vw=%d  meanMs=%.4f",
      axis, cand.tg0, cand.tg1, cand.wpt, cand.vw, ms));
    if(ms < bestMs) { bestMs = ms; winner = cand; }
  };

  for(int tg0 : outputTg0Values(full)) if(tg0 != winner.tg0) {
    auto cand = winner; cand.tg0 = tg0; trySwap(cand, "tg0");
  }
  for(int tg1 : outputTg1Values(full)) if(tg1 != winner.tg1) {
    auto cand = winner; cand.tg1 = tg1; trySwap(cand, "tg1");
  }
  for(int wpt : wptValues()) if(wpt != winner.wpt) {
    auto cand = winner; cand.wpt = wpt; trySwap(cand, "wpt");
  }
  for(int vw : vwValues()) if(vw != winner.vw) {
    auto cand = winner; cand.vw = vw; trySwap(cand, "vw");
  }
  return winner;
}
```

- [ ] **Step 2: Build to verify**

Run: `cd cpp && ninja runtests`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.cpp
git commit -m "SP4 Task 10: refinement — coordinate-descent around the joint-pass winner

One pass per axis. Skips invalid swaps via the model-aware validity filter.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Hierarchical driver + end-to-end verification

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (`loadOrAutoTune` replacement)

- [ ] **Step 1: Implement end-to-end timing helper**

In the anonymous namespace:

```cpp
// End-to-end timing of one (matmulOrient, gridOrder, inCfg, outCfg) combo.
// Runs the full winogradConv2d once after warmup. Used as the outer-level
// tiebreaker across the 4 (matmulOrient × gridOrder) combos.
static double timeOneEndToEnd(const MLXWinograd::InputTransform& inCfg,
                              const MLXWinograd::OutputUntransform& outCfg,
                              MLXWinograd::MatmulOrient orient,
                              int N, int H, int W,
                              const MLXWinogradTuner::ModelInfoForTuning& mi,
                              bool useFP16) {
  int C = mi.trunkNumChannels, Cout = mi.trunkNumChannels;
  mx::array inp = makeRandomInput(N, H, W, C, 0x11111111u, useFP16);
  std::vector<float> w_data((size_t)Cout * C * 9);
  std::mt19937 rng(0x22222222u);
  std::uniform_real_distribution<float> dist(-1, 1);
  for(auto& x : w_data) x = dist(rng);
  mx::array Uw = MLXWinograd::makeWinogradWeights(w_data, Cout, C, useFP16, orient);
  mx::eval(inp); mx::eval(Uw);

  // Warmup.
  {
    auto out = MLXWinograd::winogradConv2d(inp, Uw, Cout, inCfg, outCfg, useFP16, orient);
    mx::eval(out);
  }
  // Timed.
  auto t0 = std::chrono::steady_clock::now();
  auto out = MLXWinograd::winogradConv2d(inp, Uw, Cout, inCfg, outCfg, useFP16, orient);
  mx::eval(out);
  auto t1 = std::chrono::steady_clock::now();
  return std::chrono::duration<double, std::milli>(t1 - t0).count();
}
```

- [ ] **Step 2: Replace `loadOrAutoTune` body with the hierarchical driver**

Replace `cpp/neuralnet/mlxwinotuner.cpp:467-528` with:

```cpp
MLXWinogradTuneParams MLXWinogradTuner::loadOrAutoTune(
    string tunerFile,
    const string& homeDataDirOverride,
    const string& gpuName,
    int nnXLen, int nnYLen, int batchSize,
    ModelInfoForTuning modelInfo,
    Logger* logger,
    bool full,
    bool reTune,
    bool useFP16,
    const MLXWinogradTuneParams* seedOverride) {
  if(tunerFile.empty()) {
    string dir = defaultDirectory(true, homeDataDirOverride);
    tunerFile = dir + "/" + defaultFileName(gpuName, nnXLen, nnYLen,
                                            modelInfo.trunkNumChannels,
                                            modelInfo.modelVersion, useFP16);
  }

  if(!reTune && FileUtils::exists(tunerFile)) {
    try {
      MLXWinogradTuneParams loaded = MLXWinogradTuneParams::load(tunerFile);
      if(loaded.isValid()) {
        if(logger) logger->write("Loaded MLX Winograd tuning parameters from " + tunerFile);
        return loaded;
      }
    } catch(const IOError& e) {
      if(logger) logger->write(std::string("MLX Winograd tune file unusable, retuning: ") + e.what());
    }
  }

  if(logger) logger->write(
      "Performing SP4 hierarchical autotuning for MLX Winograd (one-time, ~80s)");

  if(seedOverride != nullptr) {
    // Test-only: skip joint passes, run refinement only.
    if(logger) logger->write("seedOverride supplied — skipping joint passes, refinement only");
    MLXWinograd::InputTransform   inRef  =
        refineInput(seedOverride->inputTransform, batchSize, nnYLen, nnXLen,
                    modelInfo, full, useFP16, logger);
    MLXWinograd::OutputUntransform outRef =
        refineOutput(seedOverride->outputUntransform, batchSize, nnYLen, nnXLen,
                     modelInfo, full, useFP16, logger);
    MLXWinogradTuneParams r;
    r.inputTransform    = inRef;
    r.outputUntransform = outRef;
    r.gridOrder         = seedOverride->gridOrder;
    r.matmulOrient      = seedOverride->matmulOrient;
    MLXWinogradTuneParams::save(tunerFile, r);
    return r;
  }

  struct OuterResult {
    MLXWinograd::MatmulOrient orient;
    MLXWinograd::GridOrder    go;
    MLXWinograd::InputTransform    inCfg;
    MLXWinograd::OutputUntransform outCfg;
    double endToEndMs;
  };
  std::vector<OuterResult> outerResults;

  for(MLXWinograd::MatmulOrient orient : {MLXWinograd::MatmulOrient::Std,
                                          MLXWinograd::MatmulOrient::Tpd}) {
    for(MLXWinograd::GridOrder go : {MLXWinograd::GridOrder::Cfast,
                                     MLXWinograd::GridOrder::Tfast}) {
      if(logger) logger->write(Global::strprintf(
          "Outer combo: matmulOrient=%d gridOrder=%d", (int)orient, (int)go));

      // Joint pass A: (wpt, vw) at SP3-default (tg0=32, tg1=1).
      auto topInWv  = jointPassA_Input(batchSize, nnYLen, nnXLen, modelInfo, go, useFP16, logger);
      auto topOutWv = jointPassA_Output(batchSize, nnYLen, nnXLen, modelInfo, go, useFP16, logger);

      // Joint pass B: (tg0, tg1) over each top-3 (wpt, vw).
      MLXWinograd::InputTransform   inBest  =
          jointPassB_Input(topInWv,  batchSize, nnYLen, nnXLen, modelInfo, go, full, useFP16, logger);
      MLXWinograd::OutputUntransform outBest =
          jointPassB_Output(topOutWv, batchSize, nnYLen, nnXLen, modelInfo, go, full, useFP16, logger);

      // Refinement.
      inBest  = refineInput(inBest,   batchSize, nnYLen, nnXLen, modelInfo, full, useFP16, logger);
      outBest = refineOutput(outBest, batchSize, nnYLen, nnXLen, modelInfo, full, useFP16, logger);

      // End-to-end timing for this outer combo.
      double e2e;
      try {
        e2e = timeOneEndToEnd(inBest, outBest, orient,
                              batchSize, nnYLen, nnXLen, modelInfo, useFP16);
      } catch(const std::exception& e) {
        if(logger) logger->write(std::string("end-to-end timing failed: ") + e.what());
        e2e = std::numeric_limits<double>::infinity();
      }
      if(logger) logger->write(Global::strprintf(
          "Outer combo result: orient=%d go=%d  endToEnd=%.4fms", (int)orient, (int)go, e2e));
      outerResults.push_back({orient, go, inBest, outBest, e2e});
    }
  }

  // Pick the best outer combo by end-to-end time.
  auto bestIt = std::min_element(
      outerResults.begin(), outerResults.end(),
      [](const OuterResult& a, const OuterResult& b){ return a.endToEndMs < b.endToEndMs; });
  if(bestIt == outerResults.end())
    throw StringError("MLX Winograd tuner: all outer combos failed");

  MLXWinogradTuneParams result;
  result.inputTransform    = bestIt->inCfg;
  result.outputUntransform = bestIt->outCfg;
  result.gridOrder         = bestIt->go;
  result.matmulOrient      = bestIt->orient;

  MLXWinogradTuneParams::save(tunerFile, result);
  if(logger) logger->write(Global::strprintf(
      "MLX Winograd SP4 tuning done: orient=%d go=%d "
      "inputTransform=(tg0=%d,tg1=%d,wpt=%d,vw=%d) "
      "outputUntransform=(tg0=%d,tg1=%d,wpt=%d,vw=%d) "
      "endToEnd=%.4fms saved to %s",
      (int)result.matmulOrient, (int)result.gridOrder,
      result.inputTransform.tg0, result.inputTransform.tg1,
      result.inputTransform.wpt, result.inputTransform.vw,
      result.outputUntransform.tg0, result.outputUntransform.tg1,
      result.outputUntransform.wpt, result.outputUntransform.vw,
      bestIt->endToEndMs, tunerFile.c_str()));
  return result;
}
```

- [ ] **Step 3: Delete the obsolete flat `searchInputTransform` / `searchOutputUntransform`**

In `cpp/neuralnet/mlxwinotuner.cpp:421-465`, delete these two functions (the hierarchical driver replaces them).

- [ ] **Step 4: Build and run all tests**

Run: `cd cpp && ninja runtests && ./runtests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.cpp
git commit -m "SP4 Task 11: hierarchical driver — orient -> gridOrder -> joint A -> joint B -> refine -> end-to-end

Replaces flat per-stage search with hierarchical search over the 4
(matmulOrient × gridOrder) outer combos, plus inner joint passes and
refinement. Picks the global winner by end-to-end winogradConv2d time.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Wire tuner output through `Model` / `ConvLayer`

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp:180-220` (ConvLayer fields + ctor + operator())
- Modify: `cpp/neuralnet/mlxbackend.cpp:878-892` (Model ctor)
- Modify: `cpp/neuralnet/mlxbackend.cpp:1133-1145` (`makeCacheKey`)

- [ ] **Step 1: Add `matmulOrient` to `ConvLayer`**

In `cpp/neuralnet/mlxbackend.cpp`, in the `ConvLayer` class, add a private field:

```cpp
  const MLXWinograd::MatmulOrient matmulOrient;
```

and add a `MatmulOrient` parameter to the constructor:

```cpp
ConvLayer(const ConvLayerDesc& desc,
          const MLXWinograd::InputTransform& inCfg,
          const MLXWinograd::OutputUntransform& outCfg,
          bool useFP16_ = false,
          MLXWinograd::MatmulOrient orient = MLXWinograd::MatmulOrient::Std)
    : /* existing init list */,
      matmulOrient(orient),
      winogradWeights(useWinograd
        ? MLXWinograd::makeWinogradWeights(desc.weights, outChannels, inChannels, useFP16_, orient)
        : mx::array(0.0f))
      /* … */ {}
```

Update the `operator()` body call to pass `matmulOrient`:

```cpp
return MLXWinograd::winogradConv2d(input, winogradWeights, outChannels,
                                   winoInCfg, winoOutCfg, useFP16, matmulOrient);
```

- [ ] **Step 2: Plumb `MatmulOrient` through `ResidualBlock`, `GlobalPoolingResidualBlock`, `Block`, `Trunk`, `PolicyHead`, `ValueHead`, `Model`**

For each class in `cpp/neuralnet/mlxbackend.cpp:429-892` that constructs a `ConvLayer`, add a `MLXWinograd::MatmulOrient orient` parameter and forward it. At the `Model` level (line 878), take it from `tuneParams.matmulOrient`:

```cpp
Model(const ModelDesc& desc, const MLXWinogradTuneParams& tuneParams, bool useFP16_ = false)
    : /* existing */,
      trunk(desc.trunk, tuneParams.inputTransform, tuneParams.outputUntransform,
            useFP16_, tuneParams.matmulOrient),
      policyHead(desc.policyHead, tuneParams.inputTransform, tuneParams.outputUntransform,
                 useFP16_, tuneParams.matmulOrient),
      valueHead(desc.valueHead, tuneParams.inputTransform, tuneParams.outputUntransform,
                useFP16_, tuneParams.matmulOrient) { /* … */ }
```

(The mechanical change is to add one more arg to ~6 constructors. Pattern is identical for each.)

- [ ] **Step 3: Extend `makeCacheKey`**

In `cpp/neuralnet/mlxbackend.cpp:1133-1145`, replace the cache-key construction with:

```cpp
return /* existing prefix */
  + "-it" + std::to_string(tuneParams.inputTransform.tg0)
  + "x"   + std::to_string(tuneParams.inputTransform.tg1)
  + "x"   + std::to_string(tuneParams.inputTransform.wpt)
  + "x"   + std::to_string(tuneParams.inputTransform.vw)
  + "-ou" + std::to_string(tuneParams.outputUntransform.tg0)
  + "x"   + std::to_string(tuneParams.outputUntransform.tg1)
  + "x"   + std::to_string(tuneParams.outputUntransform.wpt)
  + "x"   + std::to_string(tuneParams.outputUntransform.vw)
  + "-or" + std::to_string((int)tuneParams.matmulOrient)
  + "-go" + std::to_string((int)tuneParams.gridOrder);
```

- [ ] **Step 4: Build and run full suites**

Run: `cd cpp && cmake -G Ninja -DUSE_BACKEND=MLX && ninja && ./runtests && ./runnnlayertests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add cpp/neuralnet/mlxbackend.cpp
git commit -m "SP4 Task 12: wire matmulOrient + new tuner fields through ConvLayer/Model

ConvLayer takes a MatmulOrient; Model forwards tuneParams.matmulOrient to
trunk/policyHead/valueHead. ComputeHandle cache key gains wpt/vw/orient/go
components so caches don't collide across tuner outputs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: Bad-seed convergence test (sanity gate)

**Files:**
- Modify: `cpp/tests/testmlxwinotuner.cpp`

- [ ] **Step 1: Write the test**

```cpp
TEST_CASE("SP4 tuner converges from a deliberately-bad seed") {
  MLXWinogradTuner::ModelInfoForTuning mi;
  mi.trunkNumChannels = 64;
  mi.midNumChannels = 64;
  mi.maxConvChannels3x3 = 64;
  mi.modelVersion = 14;

  // Deliberately bad: tiny threadgroup, no vectorization, max WPT, Tfast.
  MLXWinogradTuneParams seed;
  seed.inputTransform    = {1, 1, 8, 1, MLXWinograd::GridOrder::Tfast};
  seed.outputUntransform = {1, 1, 8, 1, MLXWinograd::GridOrder::Tfast};
  seed.gridOrder    = MLXWinograd::GridOrder::Tfast;
  seed.matmulOrient = MLXWinograd::MatmulOrient::Std;

  // seedOverride bypasses joint passes; runs refinement only.
  // Refinement must move at least one axis on at least one stage.
  std::string tmp = "/tmp/mlxwino_sp4_badseed_test.txt";
  Logger logger;
  MLXWinogradTuneParams tuned = MLXWinogradTuner::loadOrAutoTune(
      tmp, "", "testgpu", 19, 19, /*batchSize*/1, mi, &logger,
      /*full*/false, /*reTune*/true, /*useFP16*/false, &seed);

  // Time the seed and the tuned config; tuned must be ≥30% faster on at least one stage.
  double seedInMs  = /* call existing scoreInputTransform helper via test forward-decl */ 0.0;
  double tunedInMs = 0.0;
  // (Use forward-declared MLXWinogradTuner::scoreInputTransformForTesting / scoreOutputUntransformForTesting helpers,
  //  added in this task if not already present.)
  // Stub for now: at minimum, assert SOME axis moved.
  bool moved =
      tuned.inputTransform.tg0  != seed.inputTransform.tg0  ||
      tuned.inputTransform.tg1  != seed.inputTransform.tg1  ||
      tuned.inputTransform.wpt  != seed.inputTransform.wpt  ||
      tuned.inputTransform.vw   != seed.inputTransform.vw   ||
      tuned.outputUntransform.tg0 != seed.outputUntransform.tg0 ||
      tuned.outputUntransform.tg1 != seed.outputUntransform.tg1 ||
      tuned.outputUntransform.wpt != seed.outputUntransform.wpt ||
      tuned.outputUntransform.vw  != seed.outputUntransform.vw;
  REQUIRE(moved);
  std::remove(tmp.c_str());
}
```

- [ ] **Step 2: Add `scoreInputTransformForTesting` / `scoreOutputUntransformForTesting` forward decls**

In `cpp/neuralnet/mlxwinotuner.h`:

```cpp
  double scoreInputTransformForTesting(const MLXWinograd::InputTransform& cfg,
                                       int N, int H, int W,
                                       const ModelInfoForTuning& mi,
                                       bool useFP16);
  double scoreOutputUntransformForTesting(const MLXWinograd::OutputUntransform& cfg,
                                          int N, int H, int W,
                                          const ModelInfoForTuning& mi,
                                          bool useFP16);
```

Add implementations in `mlxwinotuner.cpp` that just call the anonymous-namespace `scoreInputTransform` / `scoreOutputUntransform`.

Then strengthen the test to assert a ≥30% speed-up on at least one stage:

```cpp
double seedInMs   = MLXWinogradTuner::scoreInputTransformForTesting(seed.inputTransform, 1, 19, 19, mi, false);
double tunedInMs  = MLXWinogradTuner::scoreInputTransformForTesting(tuned.inputTransform, 1, 19, 19, mi, false);
double seedOutMs  = MLXWinogradTuner::scoreOutputUntransformForTesting(seed.outputUntransform, 1, 19, 19, mi, false);
double tunedOutMs = MLXWinogradTuner::scoreOutputUntransformForTesting(tuned.outputUntransform, 1, 19, 19, mi, false);
bool improved =
  (tunedInMs  < 0.7 * seedInMs) ||
  (tunedOutMs < 0.7 * seedOutMs);
REQUIRE(improved);
```

- [ ] **Step 3: Run the test**

Run: `./runtests "tuner converges from a deliberately-bad seed"`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp cpp/tests/testmlxwinotuner.cpp
git commit -m "SP4 Task 13: bad-seed convergence test — refinement moves ≥30% on at least one stage

Seed: (tg0=1, tg1=1, wpt=8, vw=1, Tfast). Asserts refinement reaches
a config beating the seed by ≥30% per-stage time.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: Cache version-mismatch retune test

**Files:**
- Modify: `cpp/tests/testmlxwinotuner.cpp`

- [ ] **Step 1: Write the test**

```cpp
TEST_CASE("Cache from older VERSION triggers a retune on load") {
  // Place a fake v1-format file at a v1-named path, then call loadOrAutoTune.
  // Since the version is embedded in the filename (tunemlxwino<N>_…),
  // loadOrAutoTune at v=2 will look at a *different* file path. Verify
  // (a) no crash, (b) the v1 file is left untouched on disk, (c) the v2 path
  // is freshly created and parseable.

  std::string v1Path = "/tmp/tunemlxwino1_gputest_x19_y19_c64_mv14_fp32.txt";
  {
    std::ofstream f(v1Path);
    f << "VERSION=1\n#inputTransform\ntg0=32 tg1=1\n#outputUntransform\ntg0=32 tg1=1\n";
  }

  MLXWinogradTuner::ModelInfoForTuning mi;
  mi.trunkNumChannels = 64;
  mi.midNumChannels = 64;
  mi.maxConvChannels3x3 = 64;
  mi.modelVersion = 14;

  Logger logger;
  MLXWinogradTuneParams tuned = MLXWinogradTuner::loadOrAutoTune(
      /*tunerFile=*/"", /*homeDataDirOverride=*/"/tmp/sp4_cache_test",
      /*gpuName=*/"gputest", 19, 19, 1, mi, &logger,
      /*full=*/false, /*reTune=*/false, /*useFP16=*/false, /*seed=*/nullptr);

  // v1 file untouched.
  REQUIRE(FileUtils::exists(v1Path));
  // v2 file fresh-written.
  std::string v2Path = "/tmp/sp4_cache_test/mlxwinotuning/tunemlxwino2_gpugputest_x19_y19_c64_mv14_fp32.txt";
  REQUIRE(FileUtils::exists(v2Path));
  // v2 file is parseable.
  MLXWinogradTuneParams reloaded = MLXWinogradTuneParams::load(v2Path);
  REQUIRE(reloaded.isValid());

  // Cleanup.
  std::remove(v1Path.c_str());
  std::remove(v2Path.c_str());
}
```

- [ ] **Step 2: Run the test**

Run: `./runtests "Cache from older VERSION"`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add cpp/tests/testmlxwinotuner.cpp
git commit -m "SP4 Task 14: version-mismatch retune test — v1 cache left untouched, v2 freshly tuned

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: Extend SP3 acceptance orchestrator with SP4 arm

**Files:**
- Modify: SP3 acceptance orchestrator (locate via `git log --all --oneline | grep -i acceptance` or search under `cpp/command/` or `scripts/`)

- [ ] **Step 1: Locate the existing orchestrator**

Run: `git log --all --oneline --diff-filter=A | xargs -I{} git show --stat {} | grep -i 'sp3.*orchestrator\|acceptance' | head`
Or: `find . -name "*sp3*" -o -name "*acceptance*" 2>/dev/null`
The SP3 orchestrator landed at commit `0f4fd12a` ("SP3 Task 7: acceptance orchestrator").

Run: `git show 0f4fd12a --stat` to see the file path.

- [ ] **Step 2: Add an SP4 arm**

In the orchestrator, duplicate the SP3-fp16 arm pattern, except:

- Before the SP4 arm runs, force a retune by deleting any existing SP4 cache file: `rm -f "${HOME_DATA_DIR}/mlxwinotuning/tunemlxwino2_*.txt"` (use `trash` instead of `rm` per the project preference).
- Pass `-cache-dir` such that the SP4 tuner produces and uses a fresh `tunemlxwino2_*.txt`.
- Otherwise identical: same model, same `numSearchThreads`, same arm-length, same paired-t computation.

Pseudo-shell (adapt to the actual orchestrator language):

```bash
# Arm A: SP3 baseline (already tuned).
SP3_RESULT=$(./katago benchmark -model "$MODEL" -config "$CFG" -nthreads "$NT" -ngames "$NG" --mode fp16-sp3)

# Force SP4 retune.
trash "${HOME_DATA_DIR}/mlxwinotuning/tunemlxwino2_${GPU_NAME}_*.txt" 2>/dev/null || true

# Arm B: SP4.
SP4_RESULT=$(./katago benchmark -model "$MODEL" -config "$CFG" -nthreads "$NT" -ngames "$NG" --mode fp16-sp4)

# Paired-t.
python3 paired_t.py "$SP3_RESULT" "$SP4_RESULT"
# Pass: Arm B mean > Arm A mean OR confidence interval contains 0.
```

- [ ] **Step 3: Document the gate in the orchestrator**

Add a comment at the top of the orchestrator describing the SP4 pass condition (Arm B > Arm A at p<0.05, OR CI contains 0).

- [ ] **Step 4: Dry-run the orchestrator on a tiny model**

Run the orchestrator with a small smoke-test model (b6c96 if available, otherwise b18) and a small `-ngames` to verify it completes without crashing.
Expected: completes, prints two-arm summary.

- [ ] **Step 5: Commit**

```bash
git add <orchestrator-path>
git commit -m "SP4 Task 15: extend acceptance orchestrator with SP4 arm (paired-t vs SP3)

Pass: SP4 mean > SP3 mean OR confidence interval contains 0 (no regression).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: Final acceptance — Eigen reference + testgpuerror + benchmark

**Files:**
- No code changes — execution only.

- [ ] **Step 1: Regenerate Eigen reference (if not on disk)**

Run:
```bash
cd cpp
trash CMakeCache.txt CMakeFiles 2>/dev/null
cmake -G Ninja -DUSE_BACKEND=EIGEN -DEIGEN3_INCLUDE_DIRS=/opt/homebrew/opt/eigen@3/include/eigen3
ninja
./katago testgpuerror -model "$MODEL" -config configs/gtp_example.cfg \
    -reference-file eigen_reference_b18.json
```
Expected: a `eigen_reference_b18.json` file ~30 MB exists in `cpp/`.

(If already present from SP3, skip this step.)

- [ ] **Step 2: Build MLX backend**

```bash
trash CMakeCache.txt CMakeFiles 2>/dev/null
cmake -G Ninja -DUSE_BACKEND=MLX
ninja
```
Expected: `katago` binary builds without errors.

- [ ] **Step 3: Run cross-backend accuracy gate**

```bash
trash ~/.katago/mlxwinotuning/tunemlxwino2_*.txt 2>/dev/null
./katago testgpuerror -model "$MODEL" -config configs/gtp_example.cfg \
    -reference-file eigen_reference_b18.json
```
Expected output: winrate error < 0.1%, score error < 0.01 across all configurations. Tuner runs once (~80s); subsequent runs reuse cache.

- [ ] **Step 4: Run the SP4 acceptance orchestrator**

```bash
<orchestrator-path>
```
Expected: paired-t output. **Pass condition**: SP4 arm mean > SP3 arm mean at p<0.05, OR CI contains 0 (statistical equivalence).

- [ ] **Step 5: Verify wall-time bound**

```bash
trash ~/.katago/mlxwinotuning/tunemlxwino2_*.txt 2>/dev/null
time ./katago testgpuerror -model "$MODEL" -config configs/gtp_example.cfg \
    -reference-file eigen_reference_b18.json
```
The tuner phase (logged "Performing SP4 hierarchical autotuning") should complete in < 180s. Above 180s indicates an enumeration leak.

- [ ] **Step 6: Run final unit/layer regressions**

```bash
./runtests && ./runnnlayertests
```
Expected: all pass.

- [ ] **Step 7: Tag the acceptance commit**

```bash
git commit --allow-empty -m "SP4 acceptance: aggressive F(2,3) autotuner gates pass

- testgpuerror winrate error < 0.1%, score error < 0.01 vs eigen_reference_b18.json
- Paired-t SP4 vs SP3: <fill in actual mean and p-value from Step 4>
- Tuner wall-time: <fill in actual seconds> (< 180s)
- ./runtests + ./runnnlayertests pass

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (post-write)

**Spec coverage:**
- Architecture / 6 axes → Task 1 (schema) + Task 2 (plumbing) + Tasks 3-6 (kernel rewrites). ✓
- Kernel template instantiation → Task 2 (template args + name suffix) + each task adds its branch. ✓
- `VERSION=2` schema + filename suffix → Task 1 (version bump uses existing filename pattern; orient suffix is implicit because cache key includes orient via `makeCacheKey` in Task 12). ✓
- Hierarchical search → Tasks 8 (joint A), 9 (joint B), 10 (refinement), 11 (driver). ✓
- Validity filtering during enumeration → Task 7. ✓
- Seed override path → Task 11 (seedOverride branch). ✓
- Acceptance gate 1 (correctness) → Task 16 Step 3. ✓
- Acceptance gate 2 (paired-t) → Task 15 + Task 16 Step 4. ✓
- Acceptance gate 3 (bad-seed convergence) → Task 13. ✓
- Acceptance gate 4 (schema migration) → Task 14. ✓
- Acceptance gate 5 (wall-time bound) → Task 16 Step 5. ✓
- Per-candidate dispatch-error catch (M1 threadgroup limit) → Task 8/9/10 (each `try/catch` per candidate). ✓

**Placeholder scan:** No TBD/TODO/"add appropriate". Task 15 says "locate the existing orchestrator" with concrete commands — that's a navigation step, not a placeholder, but does require the engineer to do a step that depends on artifacts of an earlier sprint. Acceptable.

**Type consistency:** `MatmulOrient`, `GridOrder`, `InputTransform`, `OutputUntransform` defined in Task 1, used identically in Tasks 2-12. Field names `wpt`, `vw`, `gridOrder` (per-stage) and `gridOrder`, `matmulOrient` (global) consistent throughout. ✓

---

**Plan complete and saved to `docs/superpowers/plans/2026-05-20-mlx-winograd-aggressive-tuning.md`.**

Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, two-stage review between tasks, continuous progress.

**2. Inline Execution** — Execute tasks in this session using `executing-plans`, with checkpoints for review.

Which approach?
