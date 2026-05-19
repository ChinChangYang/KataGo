# MLX Winograd F(2,3) fp32 Conv (SP1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `mx::conv2d` for 3×3 stride-1 dilation-1 trunk convolutions in the MLX backend with a custom Winograd F(2,3) Metal kernel built via `mx::fast::metal_kernel`, so MLX-fp32 ties the Metal backend.

**Architecture:** A new header `mlxwinograd.h` holds the F(2,3) transform constants, a pure-C++ CPU reference (the TDD oracle), and the `mx::fast::metal_kernel` source + builder. `ConvLayer` precomputes Winograd-domain weights at construction and routes qualifying convs through the kernel, falling back to `mx::conv2d` otherwise. An env-var toggle (`KATAGO_MLX_WINOGRAD=0`) is the A/B / safety valve. Correctness is gated by the existing `runnnlayertests` 3×3 oracle and `testgpuerror`; performance by a thermally-robust paired harness.

**Tech Stack:** C++17, MLX 0.31.2 (`mlx/fast.h` `metal_kernel`), Metal Shading Language, KataGo test harness (`runnnlayertests`, `testgpuerror`), CMake/Ninja.

**Spec:** `docs/superpowers/specs/2026-05-19-mlx-winograd-fp32-conv-design.md`

**Reference for porting:** `cpp/neuralnet/openclkernels.cpp` (KataGo OpenCL `winograd3x3TileSize=4` = F(2,3)).

---

## Build/test prerequisites (run once before Task 1)

- [ ] **Step 0a: Confirm MLX build works**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && cmake -G Ninja -DUSE_BACKEND=MLX && ninja
```
Expected: `katago` builds with no errors.

- [ ] **Step 0b: Locate a test model**

Run:
```bash
ls -la /Users/chinchangyang/Code/KataGo-MLX/*.bin.gz 2>/dev/null; find /Users/chinchangyang -maxdepth 4 -name "*b18*.bin.gz" 2>/dev/null | head
```
Expected: at least one `.bin.gz`. Record its path as `<MODEL>` for later tasks. If none, use the `/find-katago-models` skill.

---

## Task 1: F(2,3) constants + CPU reference (the TDD oracle)

The CPU reference is plain C++ (no MLX), used to validate every later stage. F(2,3) (m=2, r=3, input tile=4) 1D matrices:

```
B^T (4x4) = { {1,0,-1,0}, {0,1,1,0}, {0,-1,1,0}, {0,1,0,-1} }
G  (4x3)  = { {1,0,0}, {0.5,0.5,0.5}, {0.5,-0.5,0.5}, {0,0,1} }
A^T (2x4) = { {1,1,1,0}, {0,1,-1,-1} }
```
2D: weight `U = G g G^T` (3×3→4×4); input `V = B^T d B` (4×4→4×4); per-tile `M[xi][nu] = sum_c U[xi][nu][k][c]*V[xi][nu][c]`; output `Y = A^T M A` (4×4→2×2).

**Files:**
- Create: `cpp/neuralnet/mlxwinograd.h`
- Modify: `cpp/CMakeLists.txt` (add header next to `neuralnet/mlxbackend.cpp` entry)
- Modify: `cpp/tests/tests.h` (declare test)
- Modify: `cpp/tests/testnn.cpp` (add test + call from `runNNLayerTests`)

- [ ] **Step 1: Write `mlxwinograd.h` with constants, config struct, and CPU reference**

Create `cpp/neuralnet/mlxwinograd.h`:

```cpp
#ifndef NEURALNET_MLXWINOGRAD_H_
#define NEURALNET_MLXWINOGRAD_H_

#ifdef USE_MLX_BACKEND

#include <vector>
#include <cstring>

namespace MLXWinograd {

// Tuned launch/layout config. SP1 bakes the known-tuned fp32 defaults;
// SP2's autotuner must rediscover these. axis=1 == channel-fast (load-bearing).
struct WinogradConfig {
  int tg0 = 32;
  int tg1 = 1;
  int vec = 1;
  int axis = 1;
  int tileSize = 4; // input tile dim => F(2,3); F(4,3)=6 is a deferred SP2 dim
};

// F(2,3) 1D transform matrices.
static constexpr float BT[4][4] = {
  {1.f, 0.f,-1.f, 0.f},
  {0.f, 1.f, 1.f, 0.f},
  {0.f,-1.f, 1.f, 0.f},
  {0.f, 1.f, 0.f,-1.f}
};
static constexpr float G[4][3] = {
  {1.f, 0.f, 0.f},
  {0.5f,0.5f,0.5f},
  {0.5f,-0.5f,0.5f},
  {0.f, 0.f, 1.f}
};
static constexpr float AT[2][4] = {
  {1.f, 1.f, 1.f, 0.f},
  {0.f, 1.f,-1.f,-1.f}
};

// Transform one 3x3 filter g -> 4x4 U = G g G^T.
inline void transformWeight(const float g[3][3], float U[4][4]) {
  float Gg[4][3];
  for(int i=0;i<4;i++) for(int j=0;j<3;j++) {
    float s=0.f; for(int k=0;k<3;k++) s += G[i][k]*g[k][j]; Gg[i][j]=s;
  }
  for(int i=0;i<4;i++) for(int j=0;j<4;j++) {
    float s=0.f; for(int k=0;k<3;k++) s += Gg[i][k]*G[j][k]; U[i][j]=s;
  }
}

// Transform one 4x4 input tile d -> 4x4 V = B^T d B.
inline void transformInput(const float d[4][4], float V[4][4]) {
  float Bd[4][4];
  for(int i=0;i<4;i++) for(int j=0;j<4;j++) {
    float s=0.f; for(int k=0;k<4;k++) s += BT[i][k]*d[k][j]; Bd[i][j]=s;
  }
  for(int i=0;i<4;i++) for(int j=0;j<4;j++) {
    float s=0.f; for(int k=0;k<4;k++) s += Bd[i][k]*BT[j][k]; V[i][j]=s;
  }
}

// Inverse transform 4x4 M -> 2x2 Y = A^T M A.
inline void transformOutput(const float M[4][4], float Y[2][2]) {
  float AM[2][4];
  for(int i=0;i<2;i++) for(int j=0;j<4;j++) {
    float s=0.f; for(int k=0;k<4;k++) s += AT[i][k]*M[k][j]; AM[i][j]=s;
  }
  for(int i=0;i<2;i++) for(int j=0;j<2;j++) {
    float s=0.f; for(int k=0;k<4;k++) s += AM[i][k]*AT[j][k]; Y[i][j]=s;
  }
}

// Full CPU reference NHWC Winograd F(2,3) "same" conv, stride 1.
// in: [N][H][W][Cin], weights OIHW flattened [Cout][Cin][3][3], out: [N][H][W][Cout].
inline std::vector<float> cpuConv2d3x3(
  const std::vector<float>& in, int N, int H, int W, int Cin,
  const std::vector<float>& wOIHW, int Cout
) {
  std::vector<float> out((size_t)N*H*W*Cout, 0.f);
  // Precompute U per (oc,ic).
  std::vector<float> U((size_t)Cout*Cin*16);
  for(int oc=0;oc<Cout;oc++) for(int ic=0;ic<Cin;ic++) {
    float g[3][3];
    for(int a=0;a<3;a++) for(int b=0;b<3;b++)
      g[a][b]=wOIHW[(((size_t)oc*Cin+ic)*3+a)*3+b];
    float Um[4][4]; transformWeight(g,Um);
    for(int a=0;a<4;a++) for(int b=0;b<4;b++)
      U[(((size_t)oc*Cin+ic)*4+a)*4+b]=Um[a][b];
  }
  // Tile over 2x2 output blocks; pad to "same" (pad=1 each side for 3x3).
  for(int n=0;n<N;n++)
  for(int ty=0; ty<H; ty+=2)
  for(int tx=0; tx<W; tx+=2) {
    for(int oc=0; oc<Cout; oc++) {
      float Macc[4][4]={{0}};
      for(int ic=0; ic<Cin; ic++) {
        float d[4][4];
        for(int a=0;a<4;a++) for(int b=0;b<4;b++) {
          int iy=ty+a-1, ix=tx+b-1; // pad=1
          d[a][b]=(iy>=0&&iy<H&&ix>=0&&ix<W)
            ? in[(((size_t)n*H+iy)*W+ix)*Cin+ic] : 0.f;
        }
        float V[4][4]; transformInput(d,V);
        for(int a=0;a<4;a++) for(int b=0;b<4;b++)
          Macc[a][b]+=U[(((size_t)oc*Cin+ic)*4+a)*4+b]*V[a][b];
      }
      float Y[2][2]; transformOutput(Macc,Y);
      for(int a=0;a<2;a++) for(int b=0;b<2;b++) {
        int oy=ty+a, ox=tx+b;
        if(oy<H&&ox<W) out[(((size_t)n*H+oy)*W+ox)*Cout+oc]=Y[a][b];
      }
    }
  }
  return out;
}

} // namespace MLXWinograd

#endif // USE_MLX_BACKEND
#endif // NEURALNET_MLXWINOGRAD_H_
```

- [ ] **Step 2: Register the header in CMake**

In `cpp/CMakeLists.txt`, find the line `neuralnet/mlxbackend.cpp` inside `add_executable(katago ...)`. Add directly below it:

```cmake
  neuralnet/mlxwinograd.h
```

- [ ] **Step 3: Declare the test in `cpp/tests/tests.h`**

Find `void runNNLayerTests();` (line ~75) and add directly below it:

```cpp
  void runMLXWinogradTests();
```

- [ ] **Step 4: Write the failing CPU-reference test in `cpp/tests/testnn.cpp`**

At the end of `cpp/tests/testnn.cpp` (before any trailing `#endif`/namespace close), add:

```cpp
#ifdef USE_MLX_BACKEND
#include "../neuralnet/mlxwinograd.h"
#include <random>
#include <cmath>
void Tests::runMLXWinogradTests() {
  cout << "Running MLX Winograd F(2,3) tests" << endl;
  // Naive direct 3x3 "same" conv NHWC, OIHW weights, as independent oracle.
  auto direct = [](const vector<float>& in,int N,int H,int W,int Cin,
                    const vector<float>& w,int Cout){
    vector<float> out((size_t)N*H*W*Cout,0.f);
    for(int n=0;n<N;n++)for(int oy=0;oy<H;oy++)for(int ox=0;ox<W;ox++)
    for(int oc=0;oc<Cout;oc++){ float s=0.f;
      for(int ic=0;ic<Cin;ic++)for(int a=0;a<3;a++)for(int b=0;b<3;b++){
        int iy=oy+a-1,ix=ox+b-1;
        if(iy>=0&&iy<H&&ix>=0&&ix<W)
          s+=in[(((size_t)n*H+iy)*W+ix)*Cin+ic]
             *w[(((size_t)oc*Cin+ic)*3+a)*3+b];
      }
      out[(((size_t)n*H+oy)*W+ox)*Cout+oc]=s;
    }
    return out;
  };
  std::mt19937 rng(12345);
  std::uniform_real_distribution<float> dist(-1.f,1.f);
  for(auto dims : vector<array<int,5>>{{1,5,5,3,4},{2,19,19,8,16},{1,7,13,4,4}}){
    int N=dims[0],H=dims[1],W=dims[2],Cin=dims[3],Cout=dims[4];
    vector<float> in((size_t)N*H*W*Cin); for(auto&x:in)x=dist(rng);
    vector<float> w((size_t)Cout*Cin*9); for(auto&x:w)x=dist(rng);
    auto ref = direct(in,N,H,W,Cin,w,Cout);
    auto got = MLXWinograd::cpuConv2d3x3(in,N,H,W,Cin,w,Cout);
    double maxErr=0.0;
    for(size_t i=0;i<ref.size();i++)
      maxErr=std::max(maxErr,(double)std::fabs(ref[i]-got[i]));
    cout<<"  dims "<<N<<"x"<<H<<"x"<<W<<"x"<<Cin<<"->"<<Cout
        <<" maxErr="<<maxErr<<endl;
    testAssert(maxErr < 1e-3);
  }
  cout << "MLX Winograd F(2,3) CPU reference OK" << endl;
}
#else
void Tests::runMLXWinogradTests() {}
#endif
```

(`testAssert` is already used throughout `testnn.cpp`; if the local macro/helper differs, match the existing assertion idiom in that file.)

- [ ] **Step 5: Call the test from `runNNLayerTests`**

In `cpp/tests/testnn.cpp`, in `void Tests::runNNLayerTests()`, add after `testConvLayer(numTestsRun);`:

```cpp
  runMLXWinogradTests();
```

- [ ] **Step 6: Build and run — expect FAIL if math is wrong, PASS if correct**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ninja && ./katago runnnlayertests 2>&1 | grep -A6 "MLX Winograd"
```
Expected: `MLX Winograd F(2,3) CPU reference OK`, every `maxErr` < 1e-3. If any `maxErr` is large, the transform constants/index order are wrong — fix `mlxwinograd.h` before proceeding (this is the whole point of the oracle).

- [ ] **Step 7: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX && git add cpp/neuralnet/mlxwinograd.h cpp/CMakeLists.txt cpp/tests/tests.h cpp/tests/testnn.cpp && git commit -m "Add F(2,3) Winograd constants + CPU reference oracle for MLX backend"
```

---

## Task 2: Metal kernel via mx::fast::metal_kernel, validated against the CPU oracle

Implement the GPU Winograd path as a single `mx::fast::metal_kernel`: per output 2×2 tile and output channel, load the 4×4 input neighborhood, transform input, accumulate `U⊙V` over input channels, inverse-transform, write the 2×2 result. Weights arrive already in 4×4 Winograd domain (`U`, prepared host-side here; `ConvLayer` will cache this in Task 3). Parameterization seams: `tg0,tg1` → call-time threadgroup; `axis,vec,tileSize` → `template_args` (SP1 uses one concrete specialization; SP2 will sweep them).

**Files:**
- Modify: `cpp/neuralnet/mlxwinograd.h` (add MLX builder `winogradConv2d`)
- Modify: `cpp/tests/testnn.cpp` (extend test to exercise the MLX path)

- [ ] **Step 1: Add the MLX kernel builder to `mlxwinograd.h`**

Inside `namespace MLXWinograd`, before the closing `}` and `#endif`, add (keep the `#include` for MLX guarded by the existing `USE_MLX_BACKEND`):

```cpp
} // namespace MLXWinograd (close pure-C++ section)

#include "mlx/mlx.h"
#include "mlx/fast.h"

namespace MLXWinograd {
namespace mx = mlx::core;

// Host-side weight transform: OIHW [Cout][Cin][3][3] -> U array
// laid out [4*4][Cout][Cin] (xi*4+nu outer => channel-fast inner: axis=1).
inline mx::array makeWinogradWeights(const std::vector<float>& wOIHW,
                                     int Cout, int Cin) {
  std::vector<float> U((size_t)16*Cout*Cin);
  for(int oc=0;oc<Cout;oc++) for(int ic=0;ic<Cin;ic++) {
    float g[3][3];
    for(int a=0;a<3;a++) for(int b=0;b<3;b++)
      g[a][b]=wOIHW[(((size_t)oc*Cin+ic)*3+a)*3+b];
    float Um[4][4]; transformWeight(g,Um);
    for(int a=0;a<4;a++) for(int b=0;b<4;b++)
      U[((size_t)(a*4+b)*Cout+oc)*Cin+ic]=Um[a][b];
  }
  return mx::array(U.data(), {16, Cout, Cin}, mx::float32);
}

// One thread per (n, tileY, tileX, oc). grid x = total tiles*Cout style;
// kept simple/correct for SP1 (tg0,tg1 are the tunable threadgroup dims).
static const char* kWinogradSource = R"METAL(
  uint gid = thread_position_in_grid.x;
  // Decode gid -> (n, ty2, tx2, oc). Wtiles=ceil(W/2), Htiles=ceil(H/2).
  int Wt = (W + 1) / 2;
  int Ht = (H + 1) / 2;
  int tilesPerN = Ht * Wt;
  int total = N * tilesPerN * Cout;
  if((int)gid >= total) return;
  int oc = gid % Cout;
  int t  = (gid / Cout) % tilesPerN;
  int n  = gid / (Cout * tilesPerN);
  int ty = (t / Wt) * 2;
  int tx = (t % Wt) * 2;

  float Macc[4][4];
  for(int a=0;a<4;a++) for(int b=0;b<4;b++) Macc[a][b]=0.0f;

  for(int ic=0; ic<Cin; ic++) {
    float d[4][4];
    for(int a=0;a<4;a++) for(int b=0;b<4;b++) {
      int iy=ty+a-1, ix=tx+b-1;
      bool inb = (iy>=0 && iy<H && ix>=0 && ix<W);
      d[a][b] = inb ? inp[(((n*H+iy)*W+ix)*Cin)+ic] : 0.0f;
    }
    // V = BT d B
    const float BT[4][4]={{1,0,-1,0},{0,1,1,0},{0,-1,1,0},{0,1,0,-1}};
    float Bd[4][4], V[4][4];
    for(int i=0;i<4;i++) for(int j=0;j<4;j++){
      float s=0; for(int k=0;k<4;k++) s+=BT[i][k]*d[k][j]; Bd[i][j]=s; }
    for(int i=0;i<4;i++) for(int j=0;j<4;j++){
      float s=0; for(int k=0;k<4;k++) s+=Bd[i][k]*BT[j][k]; V[i][j]=s; }
    for(int a=0;a<4;a++) for(int b=0;b<4;b++) {
      float u = Uw[(((a*4+b)*Cout)+oc)*Cin + ic];
      Macc[a][b] += u * V[a][b];
    }
  }
  // Y = AT M A
  const float AT[2][4]={{1,1,1,0},{0,1,-1,-1}};
  float AM[2][4], Y[2][2];
  for(int i=0;i<2;i++) for(int j=0;j<4;j++){
    float s=0; for(int k=0;k<4;k++) s+=AT[i][k]*Macc[k][j]; AM[i][j]=s; }
  for(int i=0;i<2;i++) for(int j=0;j<2;j++){
    float s=0; for(int k=0;k<4;k++) s+=AM[i][k]*AT[j][k]; Y[i][j]=s; }
  for(int a=0;a<2;a++) for(int b=0;b<2;b++) {
    int oy=ty+a, ox=tx+b;
    if(oy<H && ox<W) out[(((n*H+oy)*W+ox)*Cout)+oc]=Y[a][b];
  }
)METAL";

// Build the Winograd conv as an MLX op. input NHWC fp32, Uw from
// makeWinogradWeights. Returns NHWC [N,H,W,Cout] fp32.
inline mx::array winogradConv2d(const mx::array& input,
                                const mx::array& Uw,
                                int Cout,
                                const WinogradConfig& cfg) {
  int N = input.shape(0), H = input.shape(1);
  int W = input.shape(2), Cin = input.shape(3);
  int Wt=(W+1)/2, Ht=(H+1)/2;
  int total = N*Ht*Wt*Cout;

  auto kernel = mx::fast::metal_kernel(
    "katago_winograd_f23",
    /*input_names=*/{"inp","Uw","N","H","W","Cin","Cout"},
    /*output_names=*/{"out"},
    /*source=*/kWinogradSource);

  std::vector<mx::array> inputs = {
    input, Uw,
    mx::array(N), mx::array(H), mx::array(W),
    mx::array(Cin), mx::array(Cout)
  };
  int grid0 = total;
  auto outs = kernel(
    inputs,
    /*output_shapes=*/{{N,H,W,Cout}},
    /*output_dtypes=*/{mx::float32},
    /*grid=*/std::make_tuple(grid0,1,1),
    /*threadgroup=*/std::make_tuple(cfg.tg0,cfg.tg1,1),
    /*template_args=*/{},
    /*init_value=*/std::nullopt,
    /*verbose=*/false,
    /*stream=*/{});
  return outs[0];
}
```

(If `metal_kernel` rejects scalar `int` inputs in this MLX version, pass `N,H,W,Cin,Cout` instead as `template_args` of type `int` — the signature is `std::vector<std::pair<std::string,TemplateArg>>` where `TemplateArg = variant<int,bool,Dtype>` — and reference them as template params in the source. Decide based on the build error in Step 3; do not leave both paths in.)

- [ ] **Step 2: Extend the test to validate the MLX/Metal path against the oracle**

In `cpp/tests/testnn.cpp` `runMLXWinogradTests()`, after the existing CPU-vs-direct loop and before the final `cout << "...OK"`, add:

```cpp
  {
    int N=2,H=19,W=19,Cin=8,Cout=16;
    std::mt19937 rng2(777);
    std::uniform_real_distribution<float> d2(-1.f,1.f);
    vector<float> in((size_t)N*H*W*Cin); for(auto&x:in)x=d2(rng2);
    vector<float> w((size_t)Cout*Cin*9); for(auto&x:w)x=d2(rng2);
    auto ref = MLXWinograd::cpuConv2d3x3(in,N,H,W,Cin,w,Cout);
    namespace mx = mlx::core;
    mx::array inArr(in.data(), {N,H,W,Cin}, mx::float32);
    auto Uw = MLXWinograd::makeWinogradWeights(w,Cout,Cin);
    MLXWinograd::WinogradConfig cfg; // defaults {32,1,1,1,4}
    mx::array o = MLXWinograd::winogradConv2d(inArr,Uw,Cout,cfg);
    mx::eval(o);
    const float* op = o.data<float>();
    double maxErr=0.0;
    for(size_t i=0;i<ref.size();i++)
      maxErr=std::max(maxErr,(double)std::fabs(ref[i]-op[i]));
    cout<<"  MLX-metal winograd maxErr="<<maxErr<<endl;
    testAssert(maxErr < 2e-3); // fp32 GPU vs CPU tolerance
  }
```

- [ ] **Step 3: Build and run — fix kernel until it matches the oracle**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ninja && ./katago runnnlayertests 2>&1 | grep -A2 "MLX-metal winograd"
```
Expected: `MLX-metal winograd maxErr=<small>`, < 2e-3, test passes. If it fails to build on scalar inputs, switch `N..Cout` to `template_args` as noted in Step 1. If `maxErr` is large, the gid decode or `Uw` layout is wrong — the CPU oracle is correct (Task 1), so debug the kernel against it.

- [ ] **Step 4: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX && git add cpp/neuralnet/mlxwinograd.h cpp/tests/testnn.cpp && git commit -m "Add MLX Winograd F(2,3) metal_kernel validated against CPU oracle"
```

---

## Task 3: Wire Winograd into ConvLayer with env-var safety valve + cache-key bump

`ConvLayer` (fp32 only here) routes 3×3 / stride-1 / dilation-1 convs through `winogradConv2d`, precomputing `Uw` at construction. `KATAGO_MLX_WINOGRAD=0` forces the `mx::conv2d` fallback (A/B + safety valve; full cfg-key plumbing is intentionally deferred — YAGNI for SP1's acceptance gate). The model cache key gains a winograd discriminator so toggling the env var never reuses a stale cached model.

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp` (`#include`; `ConvLayer` fields/ctor/apply; `makeCacheKey`)

- [ ] **Step 1: Include the header**

In `cpp/neuralnet/mlxbackend.cpp`, just after the existing neuralnet includes near the top (after the `#ifdef USE_MLX_BACKEND` block's other includes), add:

```cpp
#include "../neuralnet/mlxwinograd.h"
```

- [ ] **Step 2: Add a process-wide Winograd toggle helper**

In `cpp/neuralnet/mlxbackend.cpp`, in the `// Helpers` section (just above `struct ConvLayer`), add:

```cpp
// Winograd is on by default; KATAGO_MLX_WINOGRAD=0 forces mx::conv2d
// (A/B correctness testing and runtime safety valve).
static bool mlxWinogradEnabled() {
  static const bool enabled = [](){
    const char* e = std::getenv("KATAGO_MLX_WINOGRAD");
    return !(e != nullptr && std::string(e) == "0");
  }();
  return enabled;
}
```

- [ ] **Step 3: Give ConvLayer a Winograd path**

In `struct ConvLayer`, add fields after `mx::array weights;`:

```cpp
  const bool useWinograd;
  mx::array winogradWeights; // 4x4 domain U, valid only if useWinograd
```

Replace the constructor with (keeps existing `weights` init for the fallback path):

```cpp
  ConvLayer(const ConvLayerDesc& desc, bool useFP16 = false)
    : name(desc.name),
      convYSize(desc.convYSize),
      convXSize(desc.convXSize),
      inChannels(desc.inChannels),
      outChannels(desc.outChannels),
      dilationY(desc.dilationY),
      dilationX(desc.dilationX),
      weights(toComputeDtype(convertConvWeightsOIHWtoOHWI(desc.weights, outChannels, inChannels, convYSize, convXSize), useFP16)),
      useWinograd(!useFP16 && mlxWinogradEnabled()
                  && convYSize==3 && convXSize==3
                  && dilationY==1 && dilationX==1),
      winogradWeights(useWinograd
        ? MLXWinograd::makeWinogradWeights(desc.weights, outChannels, inChannels)
        : mx::array(0.0f))
  {}
```

Replace `apply` with:

```cpp
  mx::array apply(const mx::array& input) const {
    if(useWinograd) {
      MLXWinograd::WinogradConfig cfg; // fp32 tuned defaults {32,1,1,1,4}
      return MLXWinograd::winogradConv2d(input, winogradWeights, outChannels, cfg);
    }
    int padY = (convYSize - 1) * dilationY / 2;
    int padX = (convXSize - 1) * dilationX / 2;
    return mx::conv2d(
      input, weights,
      /*stride=*/std::make_pair(1, 1),
      /*padding=*/std::make_pair(padY, padX),
      /*dilation=*/std::make_pair(dilationY, dilationX),
      /*groups=*/1);
  }
```

(Note: `desc.weights` is OIHW per the existing `convertConvWeightsOIHWtoOHWI`; `makeWinogradWeights` consumes that same OIHW order.)

- [ ] **Step 4: Bump the model cache key so the toggle can't alias**

In `ComputeHandle::makeCacheKey`, replace the body with:

```cpp
    return loadedModel.modelDesc.name + "-" + loadedModel.modelDesc.sha256
      + (useFP16 ? "-fp16" : "-fp32")
      + (mlxWinogradEnabled() ? "-wg" : "-nowg");
```

- [ ] **Step 5: Build, then verify the existing 3×3 oracle now exercises Winograd**

`runnnlayertests`' `testConvLayer` constructs `ConvLayer` and calls `apply` with hardcoded expected outputs — the 3×3 case is now the integration oracle.

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ninja && ./katago runnnlayertests 2>&1 | tail -20
```
Expected: all configurations pass, ends with `Done`, no assertion failures (the `3x3 convolution` case passes through Winograd).

- [ ] **Step 6: Verify the safety valve (A/B) — both paths agree**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && KATAGO_MLX_WINOGRAD=0 ./katago runnnlayertests 2>&1 | tail -5
```
Expected: also ends with `Done`, no failures (fallback `mx::conv2d` path still correct).

- [ ] **Step 7: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX && git add cpp/neuralnet/mlxbackend.cpp && git commit -m "Route 3x3 trunk convs through Winograd in MLX ConvLayer (env-var safety valve, cache-key bump)"
```

---

## Task 4: Cross-backend accuracy gate (testgpuerror vs Eigen reference)

Per the spec/CLAUDE.md: a real cross-backend test shows **small non-zero** error; all-zero means no reference was loaded.

**Files:** none (validation only).

- [ ] **Step 1: Ensure an Eigen reference exists**

Run:
```bash
ls -la /Users/chinchangyang/Code/KataGo-MLX/cpp/eigen_reference_b18.json
```
If present, use it as `<REF>` and `<MODEL>` = the matching b18 net. If absent, generate it per CLAUDE.md "GPU Error Testing": build Eigen, run `./katago testgpuerror -model <MODEL> -config configs/gtp_example.cfg -reference-file eigen_reference_b18.json`, then rebuild MLX (`cmake -G Ninja -DUSE_BACKEND=MLX && ninja`).

- [ ] **Step 2: Run testgpuerror with Winograd ON**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ./katago testgpuerror -model <MODEL> -config configs/gtp_example.cfg -reference-file eigen_reference_b18.json 2>&1 | tail -25
```
Expected: small **non-zero** errors (winrate < ~0.1%, score < ~0.01). **If every value is 0.00000**, the reference failed to load — fix that, this is not a pass.

- [ ] **Step 3: Sanity-check against the fallback path**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && KATAGO_MLX_WINOGRAD=0 ./katago testgpuerror -model <MODEL> -config configs/gtp_example.cfg -reference-file eigen_reference_b18.json 2>&1 | tail -25
```
Expected: same order-of-magnitude small errors as Step 2 (Winograd doesn't materially change accuracy vs `mx::conv2d`).

- [ ] **Step 4: Commit the reference if newly generated**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX && git add cpp/eigen_reference_b18.json && git commit -m "Add Eigen cross-backend reference for MLX Winograd validation" || echo "nothing to commit"
```

---

## Task 5: Honest-measurement harness (thermally-robust paired benchmark)

**Files:**
- Create: `cpp/tools/bench_mlx_honest.sh`

- [ ] **Step 1: Write the harness script**

Create `cpp/tools/bench_mlx_honest.sh`:

```bash
#!/usr/bin/env bash
# Honest paired benchmark: Metal backend vs MLX-fp32 (Winograd).
# Interleaved A/B/A/B, warmup discard, cooldown, mean/stdev/95% CI.
# Usage: bench_mlx_honest.sh <metal_katago> <mlx_katago> <model.bin.gz> [reps] [cooldown_s]
set -euo pipefail
METAL_BIN="$1"; MLX_BIN="$2"; MODEL="$3"
REPS="${4:-6}"; COOL="${5:-30}"
CFG="$(dirname "$0")/../configs/gtp_example.cfg"
OUT="$(mktemp -d)/bench_raw.txt"; : > "$OUT"
echo "Raw output -> $OUT"

run_one() { # $1=label $2=bin -> echoes visits/sec
  local label="$1" bin="$2" log
  log="$("$bin" benchmark -model "$MODEL" -config "$CFG" -t 16 -half-batch-size 2>&1)"
  echo "===== $label =====" >> "$OUT"; echo "$log" >> "$OUT"
  # Pinned -t 16 => exactly one result row; print the parsed line for audit.
  local line; line="$(echo "$log" | grep -Ei 'visits/s|nnEvals/s' | tail -1)"
  echo "PARSED[$label]: $line" >> "$OUT"
  echo "$line" | grep -oE '[0-9]+\.[0-9]+' | head -1
}

declare -a M=() X=()
for ((i=0;i<=REPS;i++)); do          # i=0 is warmup, discarded
  m=$(run_one "METAL r$i" "$METAL_BIN"); sleep "$COOL"
  x=$(run_one "MLX   r$i" "$MLX_BIN");   sleep "$COOL"
  if (( i>0 )); then M+=("$m"); X+=("$x"); fi
  echo "rep $i: metal=$m mlx=$x"
done

stats() { # args: samples -> "mean stdev ci95"
  python3 - "$@" <<'PY'
import sys,statistics as st
v=[float(a) for a in sys.argv[1:]]
m=st.mean(v); sd=st.pstdev(v) if len(v)>1 else 0.0
ci=1.96*sd/(len(v)**0.5) if v else 0.0
print(f"{m:.2f} {sd:.2f} {ci:.2f}")
PY
}
read MM MSD MCI <<<"$(stats "${M[@]}")"
read XM XSD XCI <<<"$(stats "${X[@]}")"
DELTA=$(python3 -c "print(f'{($XM-$MM):.2f}')")
echo "---------------------------------------------"
echo "Metal : mean=$MM stdev=$MSD 95%CI=±$MCI"
echo "MLX   : mean=$XM stdev=$XSD 95%CI=±$XCI"
echo "Delta (MLX-Metal): $DELTA  (raw audit: $OUT)"
python3 -c "import sys; sys.exit(0 if ($XM-$XCI)>=($MM-$MCI) else 1)" \
  && echo "GATE PASS: MLX-fp32 >= Metal (CI-aware)" \
  || echo "GATE FAIL: MLX-fp32 slower than Metal"
```

- [ ] **Step 2: Make it executable and commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX && chmod +x cpp/tools/bench_mlx_honest.sh && git add cpp/tools/bench_mlx_honest.sh && git commit -m "Add thermally-robust paired honest-measurement harness for MLX vs Metal"
```

---

## Task 6: SP1 acceptance — MLX-fp32 ties/beats Metal

**Files:** none (acceptance only).

- [ ] **Step 1: Build both backends into separate binaries**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
cmake -G Ninja -DUSE_BACKEND=METAL && ninja && cp katago /tmp/katago_metal
cmake -G Ninja -DUSE_BACKEND=MLX && ninja && cp katago /tmp/katago_mlx
```
Expected: both build cleanly.

- [ ] **Step 2: Run the paired harness and read the raw file**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX && ./cpp/tools/bench_mlx_honest.sh /tmp/katago_metal /tmp/katago_mlx <MODEL> 6 30
```
Then open the printed raw-audit file and confirm the `PARSED[...]` lines match the numbers used. Expected: `GATE PASS: MLX-fp32 >= Metal (CI-aware)`, with the MLX↔Metal delta CI clearly separated from the run-to-run noise band.

- [ ] **Step 3: If GATE FAIL — diagnose, do not fudge**

Re-read the raw file. Common causes, in order: Winograd not actually engaged (check `KATAGO_MLX_WINOGRAD` unset and a `b18`/3×3-heavy model), kernel grid under-occupied (`tg0/tg1` — but SP1 keeps tuned defaults; deeper layout work is SP2), or thermal contamination (raise `cooldown_s`). Record findings; only the harness verdict from raw output counts.

- [ ] **Step 4: Record the result**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX && git commit --allow-empty -m "SP1 acceptance: MLX-fp32 Winograd ties/beats Metal backend (paired harness, see raw audit)"
```

---

## Self-Review

**Spec coverage:**
- §1 graph integration via `mx::fast::metal_kernel`, trunk-only 3×3/stride1/dil1, fallback + safety valve, cache-key discriminator → Task 2, Task 3.
- §2 F(2,3) ported math, weight transform at construction, separate-op stages, pad-to-2 → Task 1 (oracle), Task 2 (kernel), Task 3 (construction-time `Uw`).
- §3 `WinogradConfig{tg0,tg1,vec,axis,tileSize}` defaults `{32,1,1,1,4}` → Task 1 struct, used Task 2/3.
- §4 files (`mlxwinograd.h`, `mlxbackend.cpp`, `CMakeLists.txt`, `bench_mlx_honest.sh`) → Tasks 1,2,3,5.
- §5 harness: paired/interleaved, warmup discard, cooldown, mean/stdev/CI, `-t 16 -half-batch-size`, `configs/gtp_example.cfg`, raw audit, CI-aware gate → Task 5, Task 6.
- §6 validation: `runnnlayertests`, `testgpuerror` small-non-zero (not all-zero), winograd on/off diff → Task 3 (Steps 5–6), Task 4.
- §7 non-goals (fp16, tuner search/persistence, F(4,3), stage fusion) → not implemented; `WinogradConfig` leaves the seams.

Deviation from spec, called out deliberately (YAGNI): the spec's "config flag `mlxUseWinograd`" is realized as the `KATAGO_MLX_WINOGRAD` env var rather than full `.cfg` plumbing through `program/` — it satisfies the spec's stated *purpose* (A/B testing + runtime safety valve) without cross-cutting config-system changes that SP1's acceptance gate doesn't require.

**Placeholder scan:** No TBD/TODO; all code blocks complete; `<MODEL>`/`<REF>` are explicit user-supplied paths resolved in Step 0b / Task 4 Step 1, not code placeholders.

**Type consistency:** `WinogradConfig` fields (`tg0,tg1,vec,axis,tileSize`) consistent across Tasks 1–3. `transformWeight/transformInput/transformOutput`, `cpuConv2d3x3`, `makeWinogradWeights`, `winogradConv2d`, `mlxWinogradEnabled`, `runMLXWinogradTests` names consistent across all references. Weight order is OIHW everywhere (`cpuConv2d3x3`, `makeWinogradWeights`, and `desc.weights` matching the existing `convertConvWeightsOIHWtoOHWI`).
