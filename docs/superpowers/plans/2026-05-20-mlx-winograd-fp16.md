# SP3 — MLX Winograd fp16 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable Winograd F(2,3) in fp16 mode on the MLX backend with selective fp32 accumulation at the matmul and BatchNorm intermediate, gated on a strict paired-t two-arm acceptance test.

**Architecture:** Templatize the two Winograd Metal kernel sources on `T` (mx::float16 / mx::float32) via MLX's `template_args` API. Drop the `!useFP16` gate on `useWinograd` in `ConvLayer`. Store BatchNorm `mergedScale`/`mergedBias` as fp32 regardless of compute dtype so the multiply-add-activation chain auto-promotes to fp32 (defense against `inf`/`nan` in the 25-block-deep residual chain). Extend the tuner's cache file naming to include `_fp16`/`_fp32` so two ComputeHandles in the same process get distinct geometry. The default-flip (`Auto → fp16` at `mlxbackend.cpp:1319`) is the final gated commit.

**Tech Stack:** C++17, MLX 0.31.2, Apple Metal (kernel JIT via `mx::fast::metal_kernel`), KataGo's `testgpuerror` cross-backend validator, paired-t statistics in shell harness via python3.

**Spec:** `docs/superpowers/specs/2026-05-20-mlx-winograd-fp16-design.md`

---

## File Structure

Files touched:

| Path | Responsibility |
|------|----------------|
| `cpp/neuralnet/mlxwinograd.h` | Templatized kernel sources, `winogradConv2d`/`makeWinogradWeights` dtype-aware |
| `cpp/neuralnet/mlxbackend.cpp` | `BatchNormLayer` fp32 intermediate; `ConvLayer` gate drop + dtype threading; ComputeHandle ctor pass-through; final `Auto → fp16` resolution |
| `cpp/neuralnet/mlxwinotuner.h` | `defaultFileName` and `loadOrAutoTune` gain `bool useFP16` parameter |
| `cpp/neuralnet/mlxwinotuner.cpp` | Filename `_fp16/_fp32` suffix; timing path passes dtype into `winogradConv2d` |
| `cpp/tests/testnn.cpp` | New `runMLXWinogradFp16Test` (smoke + numerical); `runMLXWinotunerTests` adds fp16 round-trip |
| `cpp/tools/bench_mlx_honest.sh` | `BENCH_MLX_FP16` / `BENCH_METAL_FP16` env-var hooks, paired-t output on per-rep deltas |
| `cpp/tools/bench_sp3_acceptance.sh` | NEW. Orchestrates both gate arms and `testgpuerror`, parses paired-t lower bound, emits overall PASS/FAIL |
| `cpp/configs/gtp_example.cfg` | `mlxUseFP16` block comment updated to reflect `auto = fp16` policy |

Task dependency:

```
Task 1 (kernel templatization)
  ↓
Task 2 (BN fp32 intermediate)  ──┐
Task 3 (ConvLayer gate drop)  ←──┤  (depends on Task 1 signature, parallel with Task 2)
  ↓
Task 4 (tuner cache key dtype)
  ↓
Task 5 (ComputeHandle wiring + header comment)
  ↓
Task 6 (bench harness env-vars + paired-t)
  ↓
Task 7 (acceptance orchestrator script)
  ↓
Task 8 (acceptance run + Auto-flip + traceability)
```

---

### Task 1: Templatize Winograd Metal kernels on `T`

**Files:**
- Modify: `cpp/neuralnet/mlxwinograd.h:143-249, 251-304, 123-139`
- Test: `cpp/tests/testnn.cpp` (extend existing `runMLXWinogradTests`)

**Background:** `winogradConv2d` currently hard-codes `float` everywhere and registers a single kernel name (`wino_input_transform_f32` / `wino_output_untransform_f32`). MLX's `fast::metal_kernel` accepts `template_args=std::vector<std::pair<std::string, TemplateArg>>` where `TemplateArg = std::variant<int, bool, Dtype>` (verified in `/opt/homebrew/include/mlx/fast.h:57`). When the user passes `{{"T", mx::float16}}`, MLX wraps the body in `template<typename T> [[kernel]] void name<T>(...)` and instantiates the specialization. Inside the body, the literal token `T` is then a Metal type.

- [ ] **Step 1.1: Add fp16 numerical test BEFORE changing the signature**

Append to `cpp/tests/testnn.cpp` `runMLXWinogradTests()` (inside `#ifdef USE_MLX_BACKEND`), right after the existing fp32 GPU block (ends `testAssert(maxErr < 2e-3);`):

```cpp
  // FP16 Winograd: input/weights/output all fp16, compared against fp32 CPU oracle.
  // Tolerance ~5e-2 covers (a) fp16 input quantization, (b) fp16 weight quantization,
  // (c) fp16 transform/store rounding. The matmul itself accumulates in fp32 (MLX
  // steel gemm default), so the dominant error is the storage round-trip.
  {
    namespace mxc = mlx::core;
    int N=2,H=19,W=19,Cin=8,Cout=16;
    std::mt19937 grng(778);
    std::uniform_real_distribution<float> gdist(-1.f,1.f);
    vector<float> in((size_t)N*H*W*Cin); for(auto&x:in)x=gdist(grng);
    vector<float> w((size_t)Cout*Cin*9); for(auto&x:w)x=gdist(grng);
    auto refv = MLXWinograd::cpuConv2d3x3(in,N,H,W,Cin,w,Cout);
    mxc::array inArrF32(in.data(),{N,H,W,Cin},mxc::float32);
    mxc::array inArr = mxc::astype(inArrF32, mxc::float16);
    auto Uw = MLXWinograd::makeWinogradWeights(w,Cout,Cin,/*useFP16=*/true);
    MLXWinograd::InputTransform inCfg;
    MLXWinograd::OutputUntransform outCfg;
    mxc::array o = MLXWinograd::winogradConv2d(inArr,Uw,Cout,inCfg,outCfg,/*useFP16=*/true);
    mxc::eval(o);
    testAssert(o.dtype() == mxc::float16);
    mxc::array oF32 = mxc::astype(o, mxc::float32);
    mxc::eval(oF32);
    const float* od = oF32.data<float>();
    double maxErr=0.0;
    for(size_t i=0;i<refv.size();i++)
      maxErr=std::max(maxErr,(double)std::fabs(refv[i]-od[i]));
    cout<<"  MLX-metal winograd FP16 maxErr="<<maxErr<<endl;
    testAssert(maxErr < 5e-2);
  }
```

- [ ] **Step 1.2: Verify test fails to compile**

Run:
```bash
cd cpp && cmake -G Ninja -DUSE_BACKEND=MLX && ninja
```

Expected: compile FAIL with one or both of:
- `error: no matching function for call to 'MLXWinograd::makeWinogradWeights' ... candidate function not viable: requires 3 arguments, but 4 were provided`
- `error: no matching function for call to 'MLXWinograd::winogradConv2d' ... candidate function not viable: requires 5 arguments, but 6 were provided`

This proves the new test exercises the new API.

- [ ] **Step 1.3: Templatize `kWinoInputSource` and `kWinoOutputSource` on `T`**

In `cpp/neuralnet/mlxwinograd.h`, replace every `float` token that names a storage type inside `R"METAL(...)METAL"` with `T`. Literal constants (`0.0f`, etc.) stay as-is — Metal implicitly converts to `T` on assign. Concretely, edit `kWinoInputSource`:

```cpp
inline constexpr const char* kWinoInputSource = R"METAL(
    uint c_group  = thread_position_in_grid.x;
    uint tileIdx  = thread_position_in_grid.y;

    int N_k      = inp_shape[0];
    int H_k      = inp_shape[1];
    int W_k      = inp_shape[2];
    int C_k      = inp_shape[3];
    int tilesY_k = (H_k + 1) / 2;
    int tilesX_k = (W_k + 1) / 2;
    int Ntiles_k = N_k * tilesY_k * tilesX_k;

    if ((int)tileIdx >= Ntiles_k) return;

    int rem = (int)tileIdx;
    int n   = rem / (tilesY_k * tilesX_k); rem -= n * tilesY_k * tilesX_k;
    int ty  = rem / tilesX_k;
    int tx  = rem % tilesX_k;

    uint c = c_group;
    if ((int)c >= C_k) return;
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
      int base = ((r * 4 + 0) * Ntiles_k + (int)tileIdx) * C_k + (int)c;
      outp[base + 0 * Ntiles_k * C_k] = V0;
      outp[base + 1 * Ntiles_k * C_k] = V1;
      outp[base + 2 * Ntiles_k * C_k] = V2;
      outp[base + 3 * Ntiles_k * C_k] = V3;
    }
)METAL";
```

And edit `kWinoOutputSource` analogously — replace every `float` declaration with `T`:

```cpp
inline constexpr const char* kWinoOutputSource = R"METAL(
    uint oc_group = thread_position_in_grid.x;
    uint tileIdx  = thread_position_in_grid.y;

    int Ntiles_k = m_shape[1];
    int outC_k   = m_shape[2];
    int H_k      = nhwc[1];
    int W_k      = nhwc[2];
    int tilesY_k = (H_k + 1) / 2;
    int tilesX_k = (W_k + 1) / 2;

    if ((int)tileIdx >= Ntiles_k) return;

    int rem = (int)tileIdx;
    int n   = rem / (tilesY_k * tilesX_k); rem -= n * tilesY_k * tilesX_k;
    int ty  = rem / tilesX_k;
    int tx  = rem % tilesX_k;

    uint oc = oc_group;
    if ((int)oc >= outC_k) return;
    T mm[4][4];
    for (int r = 0; r < 4; r++) {
      for (int c2 = 0; c2 < 4; c2++) {
        int p = r * 4 + c2;
        mm[r][c2] = m[(p * Ntiles_k + (int)tileIdx) * outC_k + (int)oc];
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
)METAL";
```

- [ ] **Step 1.4: Add `useFP16` parameter to `makeWinogradWeights`**

Replace the existing `makeWinogradWeights` function in `cpp/neuralnet/mlxwinograd.h` with:

```cpp
inline mx::array makeWinogradWeights(const std::vector<float>& wOIHW,
                                     int Cout, int Cin,
                                     bool useFP16 = false) {
  std::vector<float> U((size_t)16 * Cin * Cout, 0.0f);
  for(int oc = 0; oc < Cout; oc++) {
    for(int ic = 0; ic < Cin; ic++) {
      float g[3][3];
      for(int a = 0; a < 3; a++)
        for(int b = 0; b < 3; b++)
          g[a][b] = wOIHW[(((size_t)oc * Cin + ic) * 3 + a) * 3 + b];
      float Um[4][4]; transformWeight(g, Um);
      for(int a = 0; a < 4; a++)
        for(int b = 0; b < 4; b++)
          U[((size_t)(a * 4 + b) * Cin + ic) * Cout + oc] = Um[a][b];
    }
  }
  mx::array arr(U.data(), {16, Cin, Cout}, mx::float32);
  if(useFP16) return mx::astype(arr, mx::float16);
  return arr;
}
```

The host-side transform stays fp32 (accuracy-critical, one-time). Only the storage handed to MLX is fp16.

- [ ] **Step 1.5: Add `useFP16` parameter to `winogradConv2d`; dispatch kernel name + template_args + output dtype**

Replace the existing `winogradConv2d` function in `cpp/neuralnet/mlxwinograd.h` with:

```cpp
inline mx::array winogradConv2d(const mx::array& input,
                                const mx::array& Uw,
                                int Cout,
                                const InputTransform& inCfg,
                                const OutputUntransform& outCfg,
                                bool useFP16 = false) {
  int N = input.shape(0);
  int H = input.shape(1);
  int W = input.shape(2);
  int C = input.shape(3);
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  const mx::Dtype dtype = useFP16 ? mx::float16 : mx::float32;
  const char* inKernelName  = useFP16 ? "wino_input_transform_f16"
                                      : "wino_input_transform_f32";
  const char* outKernelName = useFP16 ? "wino_output_untransform_f16"
                                      : "wino_output_untransform_f32";
  std::vector<std::pair<std::string, mx::fast::TemplateArg>> templArgs = {
    {"T", dtype}
  };

  // Stage 1: input transform -> [16, Ntiles, C]
  auto inFn = mx::fast::metal_kernel(
      inKernelName,
      /*input_names=*/{"inp"},
      /*output_names=*/{"outp"},
      /*source=*/kWinoInputSource);
  auto inOuts = inFn(
      /*inputs=*/{input},
      /*output_shapes=*/{ mx::Shape{16, Ntiles, C} },
      /*output_dtypes=*/{ dtype },
      /*grid=*/std::make_tuple(C, Ntiles, 1),
      /*threadgroup=*/std::make_tuple(inCfg.tg0, inCfg.tg1, 1),
      /*template_args=*/templArgs,
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});
  mx::array t = inOuts[0];

  // Stage 2: batched matmul [16,Ntiles,C] @ [16,C,Cout] -> [16,Ntiles,Cout]
  // MLX steel gemm uses AccumType=float (static-asserted in mma.h:772) when
  // T=half, so fp32 accumulation is automatic.
  mx::array m = mx::matmul(t, Uw);

  // Stage 3: output untransform -> [N, H, W, Cout]
  int nhwc_arr[4] = {N, H, W, Cout};
  mx::array nhwcArr(nhwc_arr, {4}, mx::int32);
  auto outFn = mx::fast::metal_kernel(
      outKernelName,
      /*input_names=*/{"m", "nhwc"},
      /*output_names=*/{"outp"},
      /*source=*/kWinoOutputSource);
  auto outOuts = outFn(
      /*inputs=*/{m, nhwcArr},
      /*output_shapes=*/{ mx::Shape{N, H, W, Cout} },
      /*output_dtypes=*/{ dtype },
      /*grid=*/std::make_tuple(Cout, Ntiles, 1),
      /*threadgroup=*/std::make_tuple(outCfg.tg0, outCfg.tg1, 1),
      /*template_args=*/templArgs,
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});
  return outOuts[0];
}
```

Notes:
- Kernel names differ between dtypes to avoid MLX's JIT cache collisions (cached on `(name, source)` pair).
- `template_args` passes `{"T", mx::float16}` or `{"T", mx::float32}`; MLX wraps the body in `template<typename T> ...` automatically.
- `output_dtypes` matches `dtype` so MLX allocates the right output buffer.

- [ ] **Step 1.6: Verify both fp32 and fp16 tests pass**

Run:
```bash
cd cpp && ninja && ./katago runnnlayertests
```

Expected output includes:
```
Running MLX Winograd F(2,3) tests
  ...
  MLX-metal winograd maxErr=<small>
  MLX-metal winograd FP16 maxErr=<larger but < 5e-2>
MLX Winograd F(2,3) CPU reference OK
...
Done
```

Both the original fp32 GPU test and the new fp16 test must pass. The fp32 test serves as a regression check that templatization didn't change the fp32 path.

- [ ] **Step 1.7: Commit**

```bash
git add cpp/neuralnet/mlxwinograd.h cpp/tests/testnn.cpp
git commit -m "SP3 Task 1: templatize Winograd kernels on T (fp16/fp32 dispatch)

Both kWinoInputSource and kWinoOutputSource swap 'float' for 'T'; kernel
names suffixed _f16/_f32 to avoid MLX JIT cache collision. winogradConv2d
and makeWinogradWeights gain bool useFP16 = false param with mx::astype
on the host-transformed weight buffer when fp16 requested.

Selective fp32 accumulation at the matmul reduction is automatic via
MLX steel gemm's AccumType=float static-asserted at mma.h:772.

New fp16 numerical test in runMLXWinogradTests asserts maxErr < 5e-2
vs CPU fp32 oracle (covers input/weight/store round-trip).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: BatchNormLayer fp32 intermediate (REQUIRED for accuracy gate)

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp:226-289` (BatchNormLayer)
- Test: `cpp/tests/testnn.cpp` (new BN-fp16 dtype assertion test)

**Background:** Spec §3 item 4 requires `mergedScale`/`mergedBias` stored as fp32 regardless of `useFP16`, and the result cast back to fp16 at end of `apply()` when `useFP16` is active. This is the engineered defense against `inf`/`nan` in the 25-block deep b18c384 residual chain — without it, the first `testgpuerror` run reports nonfinite outputs.

- [ ] **Step 2.1: Write the failing dtype assertion test**

Append to `cpp/tests/testnn.cpp` `runMLXWinogradTests()` (after the FP16 winograd block from Task 1):

```cpp
  // SP3 Task 2: BatchNormLayer must produce fp16 output but compute the
  // intermediate in fp32. We verify the output dtype here; the deep-chain
  // nan defense is gated end-to-end by testgpuerror.
  {
    namespace mxc = mlx::core;
    int N=1,H=5,W=5,C=4;
    std::vector<float> mean(C), variance(C, 1.0f), scale(C, 1.0f), bias(C, 0.0f);
    for(int c=0;c<C;c++) mean[c] = 0.0f;
    BatchNormLayerDesc bnDesc;
    bnDesc.name = "bnSP3Test";
    bnDesc.numChannels = C;
    bnDesc.epsilon = 1e-5f;
    bnDesc.mean = mean;
    bnDesc.variance = variance;
    bnDesc.scale = scale;
    bnDesc.bias = bias;
    BatchNormLayer bn(bnDesc, ACTIVATION_IDENTITY, /*useFP16=*/true);
    // mergedScale/mergedBias must be fp32 even in fp16 mode.
    testAssert(bn.mergedScale.dtype() == mxc::float32);
    testAssert(bn.mergedBias.dtype()  == mxc::float32);
    // apply() must return fp16 when useFP16=true.
    std::vector<float> inV((size_t)N*H*W*C, 0.5f);
    std::vector<float> maskV((size_t)N*H*W*1, 1.0f);
    mxc::array inArrF32(inV.data(), {N,H,W,C}, mxc::float32);
    mxc::array inArr = mxc::astype(inArrF32, mxc::float16);
    mxc::array maskArrF32(maskV.data(), {N,H,W,1}, mxc::float32);
    mxc::array maskArr = mxc::astype(maskArrF32, mxc::float16);
    mxc::array out = bn.apply(inArr, maskArr, /*useMask=*/true);
    mxc::eval(out);
    testAssert(out.dtype() == mxc::float16);
    cout << "  BatchNormLayer fp16: mergedScale/Bias fp32, output fp16 OK" << endl;
  }
```

This test requires `BatchNormLayer::mergedScale` and `mergedBias` to be publicly accessible — they already are (line 230-231 are non-`private` members in the struct).

- [ ] **Step 2.2: Verify test fails**

Run:
```bash
cd cpp && ninja && ./katago runnnlayertests 2>&1 | tail -40
```

Expected: FAIL on either `testAssert(bn.mergedScale.dtype() == mxc::float32)` (currently the BN ctor calls `createArray1D(..., useFP16=true)` which converts to fp16) or on `testAssert(out.dtype() == mxc::float16)` (if input is fp16 the current code returns fp16 by accident; depends on path). Either way, the test surfaces a real behavioral gap. Capture the actual failure message.

- [ ] **Step 2.3: Modify `BatchNormLayer::createArray1D` to ignore `useFP16`**

In `cpp/neuralnet/mlxbackend.cpp:237-241`, replace:

```cpp
  static mx::array createArray1D(const std::vector<float>& data, int size, bool useFP16) {
    mx::Shape shape = {size};
    mx::array arr = mx::array(data.data(), shape, mx::float32);
    return toComputeDtype(arr, useFP16);
  }
```

with:

```cpp
  // SP3: mergedScale/mergedBias storage is always fp32 to preserve dynamic
  // range across the 25-block-deep b18c384 chain. The `useFP16` parameter
  // is intentionally ignored. See spec §3 item 4.
  static mx::array createArray1D(const std::vector<float>& data, int size, bool /*useFP16*/) {
    mx::Shape shape = {size};
    return mx::array(data.data(), shape, mx::float32);
  }
```

- [ ] **Step 2.4: Add `useFP16` member to BatchNormLayer and cast result at end of `apply`**

In `cpp/neuralnet/mlxbackend.cpp:226-289`, modify `BatchNormLayer` struct. Add a `useFP16` member, store it in the ctor, and append a cast at the end of `apply`. Replace lines 226-289 with:

```cpp
struct BatchNormLayer {
  const string name;
  const int numChannels;
  const int activation;
  const bool useFP16;
  mx::array mergedScale; // Shape: [C], always fp32 (SP3)
  mx::array mergedBias;  // Shape: [C], always fp32 (SP3)

  BatchNormLayer() = delete;
  BatchNormLayer(const BatchNormLayer&) = delete;
  BatchNormLayer& operator=(const BatchNormLayer&) = delete;

  // SP3: mergedScale/mergedBias storage is always fp32 to preserve dynamic
  // range across the 25-block-deep b18c384 chain. The `useFP16` parameter
  // is intentionally ignored. See spec §3 item 4.
  static mx::array createArray1D(const std::vector<float>& data, int size, bool /*useFP16*/) {
    mx::Shape shape = {size};
    return mx::array(data.data(), shape, mx::float32);
  }

  static std::vector<float> getMergedScale(const BatchNormLayerDesc& desc) {
    // If mergedScale is already computed, use it
    if(!desc.mergedScale.empty()) {
      return desc.mergedScale;
    }
    // Otherwise compute from mean/variance/scale/bias (for tests)
    std::vector<float> mergedScale(desc.numChannels);
    for(int c = 0; c < desc.numChannels; c++) {
      mergedScale[c] = desc.scale[c] / sqrt(desc.variance[c] + desc.epsilon);
    }
    return mergedScale;
  }

  static std::vector<float> getMergedBias(const BatchNormLayerDesc& desc) {
    // If mergedBias is already computed, use it
    if(!desc.mergedBias.empty()) {
      return desc.mergedBias;
    }
    // Otherwise compute from mean/variance/scale/bias (for tests)
    std::vector<float> mergedBias(desc.numChannels);
    for(int c = 0; c < desc.numChannels; c++) {
      float ms = desc.scale[c] / sqrt(desc.variance[c] + desc.epsilon);
      mergedBias[c] = desc.bias[c] - ms * desc.mean[c];
    }
    return mergedBias;
  }

  BatchNormLayer(const BatchNormLayerDesc& desc, int activationType, bool useFP16_ = false)
    : name(desc.name),
      numChannels(desc.numChannels),
      activation(activationType),
      useFP16(useFP16_),
      mergedScale(createArray1D(getMergedScale(desc), desc.numChannels, useFP16_)),
      mergedBias(createArray1D(getMergedBias(desc), desc.numChannels, useFP16_))
  {}

  mx::array apply(const mx::array& input, const mx::array& mask, bool useMask) const {
    // input: NHWC [N, H, W, C] in compute dtype (fp16 or fp32).
    // mask: NHW1 [N, H, W, 1] in compute dtype.
    // mergedScale/mergedBias are always fp32; MLX type promotion lifts the
    // multiply-add-activation chain to fp32 automatically (selective fp32
    // accumulation, spec §3 item 4 — defense against inf/nan in deep stacks).
    mx::array normalized = input * mergedScale + mergedBias;
    mx::array activated = applyActivation(normalized, activation);
    if(useMask)
      activated = activated * mask;
    // Cast back to fp16 so downstream layers see the expected compute dtype.
    if(useFP16) activated = mx::astype(activated, mx::float16);
    return activated;
  }
};
```

Note the assignment to `activated` (was `return ... * mask` in the old code) — moved to a single trailing return so the cast applies uniformly.

- [ ] **Step 2.5: Verify test passes**

Run:
```bash
cd cpp && ninja && ./katago runnnlayertests 2>&1 | tail -20
```

Expected: includes `BatchNormLayer fp16: mergedScale/Bias fp32, output fp16 OK` and `Done`.

- [ ] **Step 2.6: Commit**

```bash
git add cpp/neuralnet/mlxbackend.cpp cpp/tests/testnn.cpp
git commit -m "SP3 Task 2: BatchNormLayer fp32 intermediate (required for accuracy)

mergedScale/mergedBias storage forced to fp32 regardless of useFP16
(createArray1D's useFP16 param now ignored). MLX type promotion lifts
the multiply-add-activation chain to fp32 automatically. apply() casts
result back to fp16 at the end so downstream layers see the expected
compute dtype.

This is the engineered defense against inf/nan in the 25-block-deep
b18c384 residual chain. Without it the first testgpuerror fp16 run
reports nonfinite outputs (spec §3 item 4).

Memory overhead ~6 KB per BN layer (fp32 vs fp16 for two [C] tensors),
negligible.

New dtype-assertion test in runMLXWinogradTests verifies mergedScale
and mergedBias are fp32 and that apply() returns fp16 when useFP16=true.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: ConvLayer drop `!useFP16` gate; thread dtype to Winograd

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp:170-224` (ConvLayer)
- Test: `cpp/tests/testnn.cpp` (new ConvLayer-fp16-winograd test)

**Background:** Today `ConvLayer` initializes `useWinograd(!useFP16 && mlxWinogradEnabled() && ...)` (line 195), so fp16 mode falls through to `mx::conv2d`. Task 1 made `winogradConv2d` dtype-aware; this task drops the gate and threads `useFP16` from `ConvLayer` into the Winograd path.

- [ ] **Step 3.1: Write the failing test**

Append to `cpp/tests/testnn.cpp` `runMLXWinogradTests()`:

```cpp
  // SP3 Task 3: ConvLayer in fp16 mode must use the Winograd path for 3x3
  // (gate `!useFP16` dropped). Numerical check against CPU fp32 oracle.
  {
    namespace mxc = mlx::core;
    int N=1,H=19,W=19,Cin=8,Cout=16;
    std::mt19937 grng(779);
    std::uniform_real_distribution<float> gdist(-1.f,1.f);
    vector<float> in((size_t)N*H*W*Cin); for(auto&x:in)x=gdist(grng);
    vector<float> w((size_t)Cout*Cin*9); for(auto&x:w)x=gdist(grng);
    auto refv = MLXWinograd::cpuConv2d3x3(in,N,H,W,Cin,w,Cout);

    ConvLayerDesc convDesc;
    convDesc.name = "convSP3FP16Test";
    convDesc.convYSize = 3;
    convDesc.convXSize = 3;
    convDesc.inChannels = Cin;
    convDesc.outChannels = Cout;
    convDesc.dilationY = 1;
    convDesc.dilationX = 1;
    convDesc.weights = w;

    MLXWinograd::InputTransform inCfg;
    MLXWinograd::OutputUntransform outCfg;
    ConvLayer conv(convDesc, inCfg, outCfg, /*useFP16=*/true);
    testAssert(conv.useWinograd);  // gate dropped: fp16 still picks Winograd

    mxc::array inArrF32(in.data(),{N,H,W,Cin},mxc::float32);
    mxc::array inArr = mxc::astype(inArrF32, mxc::float16);
    mxc::array o = conv.apply(inArr);
    mxc::eval(o);
    testAssert(o.dtype() == mxc::float16);
    mxc::array oF32 = mxc::astype(o, mxc::float32);
    mxc::eval(oF32);
    const float* od = oF32.data<float>();
    double maxErr=0.0;
    for(size_t i=0;i<refv.size();i++)
      maxErr=std::max(maxErr,(double)std::fabs(refv[i]-od[i]));
    cout<<"  ConvLayer fp16 winograd maxErr="<<maxErr<<endl;
    testAssert(maxErr < 5e-2);
  }
```

This requires `ConvLayer::useWinograd` to be accessible — it's already `const` non-`private` (line 174). The test makes the failing-first contract explicit: today `ConvLayer(useFP16=true)` would set `useWinograd=false`, so `testAssert(conv.useWinograd)` fails.

- [ ] **Step 3.2: Verify test fails**

Run:
```bash
cd cpp && ninja && ./katago runnnlayertests 2>&1 | tail -30
```

Expected: assertion failure on `testAssert(conv.useWinograd)` because today's gate is `!useFP16 && ...`.

- [ ] **Step 3.3: Drop the `!useFP16` gate and thread useFP16**

In `cpp/neuralnet/mlxbackend.cpp:170-224`, replace the entire `ConvLayer` struct (170-224) with:

```cpp
struct ConvLayer {
  const string name;
  const int convYSize;
  const int convXSize;
  const int inChannels;
  const int outChannels;
  const int dilationY;
  const int dilationX;
  const bool useFP16;
  const bool useWinograd;
  mx::array weights;            // OHWI format (only built when !useWinograd)
  mx::array winogradWeights;    // 4x4 domain U, valid only if useWinograd
  const MLXWinograd::InputTransform    winoInCfg;
  const MLXWinograd::OutputUntransform winoOutCfg;

  ConvLayer() = delete;
  ConvLayer(const ConvLayer&) = delete;
  ConvLayer& operator=(const ConvLayer&) = delete;

  ConvLayer(const ConvLayerDesc& desc,
            const MLXWinograd::InputTransform& inCfg,
            const MLXWinograd::OutputUntransform& outCfg,
            bool useFP16_ = false)
    : name(desc.name),
      convYSize(desc.convYSize),
      convXSize(desc.convXSize),
      inChannels(desc.inChannels),
      outChannels(desc.outChannels),
      dilationY(desc.dilationY),
      dilationX(desc.dilationX),
      useFP16(useFP16_),
      // SP3: `!useFP16` gate removed — Winograd path now runs in fp16 too.
      useWinograd(mlxWinogradEnabled()
                  && convYSize==3 && convXSize==3
                  && dilationY==1 && dilationX==1),
      weights(useWinograd ? mx::array(0.0f) : toComputeDtype(convertConvWeightsOIHWtoOHWI(desc.weights, outChannels, inChannels, convYSize, convXSize), useFP16_)),
      winogradWeights(useWinograd
        ? MLXWinograd::makeWinogradWeights(desc.weights, outChannels, inChannels, useFP16_)
        : mx::array(0.0f))
      ,winoInCfg(inCfg)
      ,winoOutCfg(outCfg)
  {}

  mx::array apply(const mx::array& input) const {
    if(useWinograd) {
      return MLXWinograd::winogradConv2d(input, winogradWeights, outChannels, winoInCfg, winoOutCfg, useFP16);
    }
    // MLX conv2d: input NHWC, weights OHWI
    // Compute padding to maintain spatial dimensions (same padding)
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
};
```

Changes from previous version:
- New `useFP16` member (immutable).
- Ctor parameter renamed `useFP16` → `useFP16_` to avoid shadowing.
- `useWinograd` gate no longer has `!useFP16`.
- `makeWinogradWeights` call now passes `useFP16_`.
- `apply()` passes `useFP16` to `winogradConv2d`.

- [ ] **Step 3.4: Verify test passes**

Run:
```bash
cd cpp && ninja && ./katago runnnlayertests 2>&1 | tail -30
```

Expected: includes `ConvLayer fp16 winograd maxErr=<small>` and `Done`. The fp32 ConvLayer regression test (existing) must still pass.

- [ ] **Step 3.5: Commit**

```bash
git add cpp/neuralnet/mlxbackend.cpp cpp/tests/testnn.cpp
git commit -m "SP3 Task 3: ConvLayer drops !useFP16 gate, threads dtype to Winograd

useWinograd(!useFP16 && ...) -> useWinograd(...) — Winograd path now
runs in fp16 too. ConvLayer gains immutable useFP16 member; ctor
threads it into makeWinogradWeights() and apply()'s winogradConv2d()
call. The non-Winograd mx::conv2d fallback path is unchanged
(toComputeDtype already handled fp16 there).

New test: a ConvLayer constructed with useFP16=true now reports
useWinograd=true, returns fp16 output, and matches CPU fp32 oracle
within 5e-2 (fp16 round-trip tolerance).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Tuner cache key dtype-aware

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.h:33-54`
- Modify: `cpp/neuralnet/mlxwinotuner.cpp:121-132, 444-460` (and the search-timing call sites)
- Test: `cpp/tests/testnn.cpp` `runMLXWinotunerTests` (new fp16 round-trip subtest)

**Background:** Spec §3 item 3 requires the cache filename to differ by dtype so two ComputeHandles can hold distinct geometry. Today `defaultFileName` has no dtype suffix. The search timing path (`timeOneInputTransform` / `timeOneOutputUntransform` in `mlxwinotuner.cpp`) calls `winogradConv2d` — that call needs to pass `useFP16` so the search measures the active precision's kernel.

- [ ] **Step 4.1: Add fp16/fp32 round-trip subtest to `runMLXWinotunerTests`**

In `cpp/tests/testnn.cpp` `runMLXWinotunerTests()`, locate the existing round-trip block (around line 1010-1019, opens with `MLXWinogradTuneParams written;` and ends with `MLXWinogradTuneParams::load(tmp)`). After the existing block, append:

```cpp
  // SP3 Task 4: dtype-aware cache filenames must coexist in the same directory
  // without collision. Verify defaultFileName gains a _fp16/_fp32 suffix.
  {
    std::string nameF32 = MLXWinogradTuner::defaultFileName(
      "AppleSilicon", 19, 19, 384, 13, /*useFP16=*/false);
    std::string nameF16 = MLXWinogradTuner::defaultFileName(
      "AppleSilicon", 19, 19, 384, 13, /*useFP16=*/true);
    testAssert(nameF32 != nameF16);
    testAssert(nameF32.find("_fp32") != std::string::npos);
    testAssert(nameF16.find("_fp16") != std::string::npos);
    // Both end with .txt (suffix is before extension)
    testAssert(nameF32.size() >= 4 && nameF32.substr(nameF32.size()-4) == ".txt");
    testAssert(nameF16.size() >= 4 && nameF16.substr(nameF16.size()-4) == ".txt");
    cout << "  defaultFileName dtype suffix OK: "
         << nameF32 << " vs " << nameF16 << endl;
  }
```

- [ ] **Step 4.2: Verify test fails to compile**

Run:
```bash
cd cpp && ninja 2>&1 | tail -20
```

Expected: compile error along the lines of `error: too many arguments to function call, expected 5, have 6` on `defaultFileName(...)`.

- [ ] **Step 4.3: Add `bool useFP16` to `defaultFileName` and `loadOrAutoTune` declarations**

In `cpp/neuralnet/mlxwinotuner.h`, replace lines 33-54 with:

```cpp
  std::string defaultDirectory(bool makeDir, const std::string& homeDataDirOverride);
  std::string defaultFileName(const std::string& gpuName,
                              int nnXLen, int nnYLen,
                              int trunkNumChannels, int modelVersion,
                              bool useFP16);

  // Loads existing tune file if present and valid; otherwise runs the two
  // grid searches, saves the result, and returns it.
  // useFP16: passed to defaultFileName for cache-file naming AND to the
  // search-timing kernels so geometry is measured at the active precision.
  // seedOverride: when non-null, the search uses these configs as the initial
  // baseline instead of the SP1 baked defaults {tg0=32, tg1=1}. Used by tests
  // to verify that the search converges from a bad seed; production callers
  // pass nullptr.
  MLXWinogradTuneParams loadOrAutoTune(
    std::string tunerFile,
    const std::string& homeDataDirOverride,
    const std::string& gpuName,
    int nnXLen, int nnYLen, int batchSize,
    ModelInfoForTuning modelInfo,
    Logger* logger,
    bool full,
    bool reTune,
    bool useFP16,
    const MLXWinogradTuneParams* seedOverride = nullptr
  );
}
```

- [ ] **Step 4.4: Implement `defaultFileName` with dtype suffix**

In `cpp/neuralnet/mlxwinotuner.cpp:121-132`, replace:

```cpp
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
```

with:

```cpp
string MLXWinogradTuner::defaultFileName(const string& gpuName,
                                         int nnXLen, int nnYLen,
                                         int trunkNumChannels, int modelVersion,
                                         bool useFP16) {
  string clean;
  for(char c : gpuName) {
    if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
      clean += c;
  }
  const char* dtypeSuffix = useFP16 ? "_fp16" : "_fp32";
  return Global::strprintf("tunemlxwino%d_gpu%s_x%d_y%d_c%d_mv%d%s.txt",
                           MLX_WINO_TUNER_VERSION, clean.c_str(),
                           nnXLen, nnYLen, trunkNumChannels, modelVersion,
                           dtypeSuffix);
}
```

- [ ] **Step 4.5: Thread `useFP16` through `loadOrAutoTune` and search helpers**

The search-timing helpers `searchInputTransform` and `searchOutputUntransform` (in `cpp/neuralnet/mlxwinotuner.cpp`) call `winogradConv2d` via internal `timeOneInputTransform` / `timeOneOutputUntransform` helpers. They need `useFP16`.

Add a `useFP16` parameter to `searchInputTransform` and `searchOutputUntransform` in their definitions inside `mlxwinotuner.cpp` (anonymous namespace), and to the `timeOneInputTransform` / `timeOneOutputUntransform` helpers they call. Inspect the current signatures with:

```bash
grep -n "searchInputTransform\|searchOutputUntransform\|timeOneInputTransform\|timeOneOutputUntransform\|winogradConv2d" cpp/neuralnet/mlxwinotuner.cpp
```

For every signature reported, add `bool useFP16` as the final parameter (before any default-arg parameters). At every `winogradConv2d(...)` call site inside those helpers, pass `useFP16` as the last argument. At every `makeWinogradWeights(...)` call site inside those helpers, pass `useFP16` as the new last argument. The two callers `loadOrAutoTune` (already inspected, line 487 and 490) become:

In `cpp/neuralnet/mlxwinotuner.cpp:444-460`, replace:

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
    const MLXWinogradTuneParams* seedOverride) {
  if(tunerFile.empty()) {
    string dir = defaultDirectory(true, homeDataDirOverride);
    tunerFile = dir + "/" + defaultFileName(gpuName, nnXLen, nnYLen,
                                            modelInfo.trunkNumChannels,
                                            modelInfo.modelVersion);
  }
```

with:

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
                                            modelInfo.modelVersion,
                                            useFP16);
  }
```

And in the same function body, change the two calls (around line 487 and 490):

```cpp
  MLXWinograd::InputTransform   inBest =
      searchInputTransform(inSeed, batchSize, nnYLen, nnXLen, modelInfo, full, logger);
  if(logger != nullptr) logger->write("Tuning output untransform...");
  MLXWinograd::OutputUntransform outBest =
      searchOutputUntransform(outSeed, batchSize, nnYLen, nnXLen, modelInfo, full, logger);
```

to:

```cpp
  MLXWinograd::InputTransform   inBest =
      searchInputTransform(inSeed, batchSize, nnYLen, nnXLen, modelInfo, full, useFP16, logger);
  if(logger != nullptr) logger->write("Tuning output untransform...");
  MLXWinograd::OutputUntransform outBest =
      searchOutputUntransform(outSeed, batchSize, nnYLen, nnXLen, modelInfo, full, useFP16, logger);
```

- [ ] **Step 4.6: Update existing tuner test seedOverride call site**

The existing search-works test in `runMLXWinotunerTests` calls `loadOrAutoTune` (around line 1084). Inspect with:

```bash
grep -n "loadOrAutoTune\|defaultFileName" cpp/tests/testnn.cpp
```

For every reported call to `loadOrAutoTune` in `cpp/tests/testnn.cpp`, add `/*useFP16=*/false` as the second-to-last argument (immediately before the `seedOverride` argument). For every call to `defaultFileName` in `cpp/tests/testnn.cpp` (other than the new fp16 round-trip subtest added in Step 4.1), add `/*useFP16=*/false` as the last argument.

- [ ] **Step 4.7: Verify build and tests pass**

Run:
```bash
cd cpp && ninja && ./katago runnnlayertests 2>&1 | tail -30
```

Expected: includes `defaultFileName dtype suffix OK: tunemlxwino1_gpuAppleSilicon_x19_y19_c384_mv13_fp32.txt vs tunemlxwino1_gpuAppleSilicon_x19_y19_c384_mv13_fp16.txt` and `Done`.

- [ ] **Step 4.8: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinotuner.cpp cpp/tests/testnn.cpp
git commit -m "SP3 Task 4: tuner cache filename gains _fp16/_fp32 dtype suffix

defaultFileName(...) and loadOrAutoTune(...) now require a bool useFP16
parameter. Filename pattern is now
  tunemlxwino<V>_gpu<GPU>_x<X>_y<Y>_c<C>_mv<MV>_<fp16|fp32>.txt
so two ComputeHandles in the same process holding different dtypes
get distinct cache files (spec §3 item 3).

searchInputTransform/searchOutputUntransform and the inner timing
helpers thread useFP16 down so the candidate kernels are measured at
the active precision — fp16 may want different threadgroup geometry
than fp32 because Apple Silicon's half-throughput is ~2x.

Round-trip test asserts the two filenames differ, both contain the
expected dtype substring, and both keep the .txt suffix.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: ComputeHandle wiring + header comment update

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp:1-15` (header comment block)
- Modify: `cpp/neuralnet/mlxbackend.cpp:1121-1156` (ComputeHandle ctor)
- Modify: `cpp/configs/gtp_example.cfg` (around line 525-529, the `mlxUseFP16` block)

**Background:** Wire `useFP16` into the `loadOrAutoTune` call and drop the `&& !useFP16_` gate that currently disables the tuner in fp16 mode. Update the file header comment that claims "FP16 does not improve performance on MLX" — that statement is being overturned by SP3 (verification deferred to Task 8's acceptance run). The config block's user-facing comment about `mlxUseFP16` updates here too so the next build's binary embeds the new text.

- [ ] **Step 5.1: Drop `&& !useFP16_` gate; pass `useFP16_` to `loadOrAutoTune`**

In `cpp/neuralnet/mlxbackend.cpp:1132-1156`, replace the existing ComputeHandle ctor body block:

```cpp
    // Determine tuner params: either run the autotuner, or use baked SP1 defaults.
    MLXWinogradTuneParams tuneParams;
    if(mlxWinogradEnabled() && mlxWinotunerEnabled() && !useFP16_) {
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels   = loadedModel.modelDesc.trunk.trunkNumChannels;
      mi.midNumChannels     = loadedModel.modelDesc.trunk.midNumChannels;
      mi.maxConvChannels3x3 = std::max({
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
          /*reTune=*/mlxWinotunerForce(),
          /*seedOverride=*/nullptr);
    }
```

with:

```cpp
    // Determine tuner params: either run the autotuner, or use baked SP1 defaults.
    // SP3: tuner runs at every precision so fp16 gets its own cache file.
    MLXWinogradTuneParams tuneParams;
    if(mlxWinogradEnabled() && mlxWinotunerEnabled()) {
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels   = loadedModel.modelDesc.trunk.trunkNumChannels;
      mi.midNumChannels     = loadedModel.modelDesc.trunk.midNumChannels;
      mi.maxConvChannels3x3 = std::max({
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
          /*reTune=*/mlxWinotunerForce(),
          /*useFP16=*/useFP16_,
          /*seedOverride=*/nullptr);
    }
```

Two changes: drop `&& !useFP16_` from the if-condition, and pass `/*useFP16=*/useFP16_` (positioned before `seedOverride` per the new signature).

- [ ] **Step 5.2: Update mlxbackend.cpp file-header comment**

In `cpp/neuralnet/mlxbackend.cpp:1-15`, replace lines 6-7:

```cpp
 * Supports FP16 (half precision) and FP32 computation with NHWC memory layout.
 * FP32 is used by default (FP16 does not improve performance on MLX).
```

with:

```cpp
 * Supports FP16 (half precision) and FP32 computation with NHWC memory layout.
 * FP16 Winograd uses selective fp32 accumulation at the matmul reduction and
 * BatchNorm intermediate (spec docs/superpowers/specs/2026-05-20-mlx-winograd-fp16-design.md).
 * `mlxUseFP16 = auto` resolves to fp16 after SP3 acceptance lands.
```

- [ ] **Step 5.3: Update gtp_example.cfg comment block**

In `cpp/configs/gtp_example.cfg:525-529` (the `mlxUseFP16` block), inspect with:

```bash
sed -n '520,535p' cpp/configs/gtp_example.cfg
```

Then replace the three comment lines and the commented config line. Use this Edit string match — the existing text:

```
# Whether to use FP16 (half precision) for neural net evaluation.
# FP16 uses less memory but does not improve performance on MLX.
```

becomes:

```
# Whether to use FP16 (half precision) for neural net evaluation on MLX.
# FP16 uses less memory; on Apple Silicon with SP3's Winograd path it is also
# faster than FP32. Set `false` only if you need bit-for-bit FP32 reproducibility.
```

- [ ] **Step 5.4: Verify build and existing tests pass**

Run:
```bash
cd cpp && ninja && ./katago runtests && ./katago runnnlayertests 2>&1 | tail -20
```

Expected: all existing tests pass. We do not add a unit test for this task — Task 5 is integration wiring; functional behavior is exercised by Task 8's `testgpuerror`. The runtests + runnnlayertests pass proves no regression.

- [ ] **Step 5.5: Commit**

```bash
git add cpp/neuralnet/mlxbackend.cpp cpp/configs/gtp_example.cfg
git commit -m "SP3 Task 5: ComputeHandle wires useFP16 into tuner; comments updated

ComputeHandle ctor:
  - Drops the '&& !useFP16_' gate that previously disabled the tuner
    in fp16 mode. The tuner now runs at every precision (per spec §3
    item 3 — fp16 gets its own _fp16.txt cache file).
  - Passes useFP16_ as the new loadOrAutoTune useFP16 argument.

File-header comment (mlxbackend.cpp:1-15): the claim 'FP16 does not
improve performance on MLX' is updated to reflect SP3's outcome
(verification deferred to Task 8 acceptance run).

gtp_example.cfg mlxUseFP16 block: comment updated to point users at
the SP3 behavior; the actual auto-resolution flip ships in Task 8.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Bench harness — env-vars + paired-t output

**Files:**
- Modify: `cpp/tools/bench_mlx_honest.sh` (full rewrite)

**Background:** Spec §7 requires paired-t on per-rep deltas, not independent CIs. Spec §4 introduces `BENCH_MLX_FP16` / `BENCH_METAL_FP16` env-vars that flip `mlxUseFP16` / `metalUseFP16` in the config used by the run.

- [ ] **Step 6.1: Rewrite `bench_mlx_honest.sh`**

Replace the entire content of `cpp/tools/bench_mlx_honest.sh` with:

```bash
#!/usr/bin/env bash
# Honest paired benchmark for KataGo MLX/Metal backends.
# - Interleaved A/B/A/B/..., warmup discard, cooldown between reps.
# - Output stats: per-rep deltas + paired-t 95% CI on the mean delta.
#
# Usage:
#   bench_mlx_honest.sh <bin_A> <bin_B> <model.bin.gz> [reps] [cooldown_s]
#
# Env-vars (SP3):
#   BENCH_A_LABEL    Label printed for backend A (default: "A").
#   BENCH_B_LABEL    Label printed for backend B (default: "B").
#   BENCH_A_FP16     If 1, force `*UseFP16 = true` in the config A sees.
#   BENCH_B_FP16     If 1, force `*UseFP16 = true` in the config B sees.
#   BENCH_A_FP32     If 1, force `*UseFP16 = false` in the config A sees.
#   BENCH_B_FP32     If 1, force `*UseFP16 = false` in the config B sees.
#   BENCH_CONFIG     Override default config path.
#
# The per-bin config is materialized as a temp file via sed; the original
# gtp_example.cfg is not modified.
set -euo pipefail

BIN_A="$1"; BIN_B="$2"; MODEL="$3"
REPS="${4:-6}"; COOL="${5:-30}"
A_LABEL="${BENCH_A_LABEL:-A}"; B_LABEL="${BENCH_B_LABEL:-B}"
DEFAULT_CFG="$(dirname "$0")/../configs/gtp_example.cfg"
BASE_CFG="${BENCH_CONFIG:-$DEFAULT_CFG}"

TMPDIR_BENCH="$(mktemp -d)"
OUT="$TMPDIR_BENCH/bench_raw.txt"; : > "$OUT"
CFG_A="$TMPDIR_BENCH/cfg_a.cfg"
CFG_B="$TMPDIR_BENCH/cfg_b.cfg"
echo "Raw output -> $OUT"

# Materialize per-bin configs. `sed` uncomments the relevant *UseFP16 line and
# replaces its value. Supports cudaUseFP16 / openclUseFP16 / mlxUseFP16 /
# metalUseFP16. The match is permissive (handles `# foo = auto` and
# `foo = true` alike).
materialize_cfg() {
  local out="$1" want16="$2" want32="$3"
  cp "$BASE_CFG" "$out"
  if [[ "$want16" == "1" ]]; then
    # Force every *UseFP16 setting to true (covers all backends; harmless
    # for backends not actually used by this run).
    sed -i.bak -E 's|^[#[:space:]]*((cuda|opencl|mlx|metal)UseFP16)[[:space:]]*=.*|\1 = true|g' "$out"
    rm -f "${out}.bak"
  fi
  if [[ "$want32" == "1" ]]; then
    sed -i.bak -E 's|^[#[:space:]]*((cuda|opencl|mlx|metal)UseFP16)[[:space:]]*=.*|\1 = false|g' "$out"
    rm -f "${out}.bak"
  fi
}

materialize_cfg "$CFG_A" "${BENCH_A_FP16:-0}" "${BENCH_A_FP32:-0}"
materialize_cfg "$CFG_B" "${BENCH_B_FP16:-0}" "${BENCH_B_FP32:-0}"

run_one() { # $1=label $2=bin $3=cfg -> echoes visits/sec
  local label="$1" bin="$2" cfg="$3" log
  log="$("$bin" benchmark -model "$MODEL" -config "$cfg" -t 16 -half-batch-size 2>&1)"
  echo "===== $label =====" >> "$OUT"; echo "$log" >> "$OUT"
  local line; line="$(echo "$log" | grep -oE 'visits/s = [0-9]+\.[0-9]+' | tail -1)"
  echo "PARSED[$label]: $line" >> "$OUT"
  echo "$line" | grep -oE '[0-9]+\.[0-9]+' | head -1
}

declare -a SA=() SB=()
for ((i=0;i<=REPS;i++)); do          # i=0 is warmup, discarded
  a=$(run_one "${A_LABEL} r$i" "$BIN_A" "$CFG_A"); sleep "$COOL"
  b=$(run_one "${B_LABEL} r$i" "$BIN_B" "$CFG_B"); sleep "$COOL"
  if (( i>0 )); then SA+=("$a"); SB+=("$b"); fi
  echo "rep $i: ${A_LABEL}=$a ${B_LABEL}=$b"
done

# Paired-t on per-rep delta = B - A.
python3 - "${A_LABEL}" "${B_LABEL}" "${SA[@]}" -- "${SB[@]}" <<'PY'
import sys, statistics as st, math
args = sys.argv[1:]
sep = args.index("--")
a_label = args[0]; b_label = args[1]
a = [float(x) for x in args[2:sep]]
b = [float(x) for x in args[sep+1:]]
assert len(a) == len(b), f"unequal lengths: {len(a)} vs {len(b)}"
n = len(a)
deltas = [bi - ai for ai, bi in zip(a, b)]
mean_a = st.mean(a); mean_b = st.mean(b)
d_bar  = st.mean(deltas)
s_d    = st.stdev(deltas) if n >= 2 else 0.0
se     = s_d / math.sqrt(n) if n >= 1 else 0.0
# t critical for 95% two-sided CI, n-1 dof. Table values up to n=20.
t_table = {
  1:12.706, 2:4.303, 3:3.182, 4:2.776, 5:2.571, 6:2.447, 7:2.365, 8:2.306,
  9:2.262, 10:2.228, 11:2.201, 12:2.179, 13:2.160, 14:2.145, 15:2.131,
  16:2.120, 17:2.110, 18:2.101, 19:2.093, 20:2.086,
}
t_crit = t_table.get(max(n-1, 1), 1.96)
ci_half = t_crit * se
ci_lower = d_bar - ci_half
ci_upper = d_bar + ci_half
print("---------------------------------------------")
print(f"{a_label:<8}: mean={mean_a:.2f}")
print(f"{b_label:<8}: mean={mean_b:.2f}")
print(f"Per-rep deltas ({b_label} - {a_label}):")
for i, d in enumerate(deltas, 1):
    print(f"  rep {i}: d={d:+.3f}")
print(f"Paired N={n}, d_bar={d_bar:+.3f}, s_d={s_d:.3f}, SE={se:.3f}")
print(f"Paired 95% CI on d_bar: [{ci_lower:+.3f}, {ci_upper:+.3f}] (t_crit={t_crit:.3f})")
print(f"CI_lower={ci_lower:+.3f}")
PY

echo "(raw audit: $OUT)"
echo "(config A: $CFG_A, config B: $CFG_B)"
```

Key points:
- The script's contract changes from "Metal vs MLX" to generic A vs B; the orchestrator (Task 7) sets labels and fp16/fp32 flags.
- Paired-t CI lower bound printed on a line `CI_lower=±NN.NNN` — Task 7 greps this line.
- No PASS/FAIL printed by the harness; the orchestrator decides PASS/FAIL based on the lower bound.

- [ ] **Step 6.2: Smoke-test the new harness without running a real bench**

Run with bogus inputs to check argument parsing and config materialization:

```bash
chmod +x cpp/tools/bench_mlx_honest.sh
# Don't actually run reps — just check materialization with REPS=0 (one warmup, no measurement)
# This will print a python error about empty samples; that's expected and proves we got that far.
# Use BENCH_A_FP16 to force fp16 in the materialized config.
TMP=$(mktemp -d)
echo "#!/bin/bash" > "$TMP/fakekatago"
echo 'echo "visits/s = 100.00"' >> "$TMP/fakekatago"
chmod +x "$TMP/fakekatago"
BENCH_A_LABEL=Metal BENCH_B_LABEL=MLX BENCH_A_FP16=1 BENCH_B_FP16=1 \
  cpp/tools/bench_mlx_honest.sh "$TMP/fakekatago" "$TMP/fakekatago" /tmp/nonexistent.bin.gz 1 0 \
  2>&1 | tail -25
```

Expected: prints `rep 0: Metal=100.00 MLX=100.00`, then `rep 1: Metal=100.00 MLX=100.00`, then the paired-t block. Also prints `(config A: <path>)` and `(config B: <path>)`. Open one of those configs and verify the `mlxUseFP16` line was changed to `= true`:

```bash
grep -E "(mlx|metal)UseFP16" $(ls -td /tmp/tmp.*/cfg_a.cfg | head -1) 2>/dev/null | head -5
```

Expected: lines like `mlxUseFP16 = true` and `metalUseFP16 = true` (not commented out, not auto).

- [ ] **Step 6.3: Commit**

```bash
git add cpp/tools/bench_mlx_honest.sh
git commit -m "SP3 Task 6: bench harness — env-var fp16 hooks + paired-t output

Replaces independent CIs with paired-t on per-rep deltas (spec §7
statistical methodology). The A/B/A/B/... pairing is paired data;
paired-t controls for thermal drift that independent CIs would
falsely flag.

New env-vars BENCH_A_FP16, BENCH_B_FP16, BENCH_A_FP32, BENCH_B_FP32
materialize a per-bin temp config with the *UseFP16 lines forced
(handles cuda/opencl/mlx/metal in one sed). BENCH_A_LABEL, BENCH_B_LABEL,
BENCH_CONFIG provide further hooks for the SP3 acceptance orchestrator.

Output ends with a line 'CI_lower=±NN.NNN' so the orchestrator can
grep the gate value. PASS/FAIL is no longer decided by this script —
that's the orchestrator's job in Task 7.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Acceptance orchestrator script

**Files:**
- Create: `cpp/tools/bench_sp3_acceptance.sh`

**Background:** Spec §7 requires two paired-t arms plus `testgpuerror`. Spec §5 lays out the bench flow. This script orchestrates both arms back-to-back and emits a single overall PASS/FAIL.

- [ ] **Step 7.1: Create the orchestrator script**

Create `cpp/tools/bench_sp3_acceptance.sh` with content:

```bash
#!/usr/bin/env bash
# SP3 acceptance gate: runs both paired-t arms and testgpuerror.
#
# Arm A: Metal-fp16 vs MLX-fp16   (parity: paired CI_lower on (MLX - Metal) >= 0)
# Arm B: MLX-fp32   vs MLX-fp16   (strict: paired CI_lower on (MLX_fp16 - MLX_fp32) > 0)
# Accuracy: testgpuerror with mlxUseFP16=true vs eigen reference.
#
# Usage:
#   bench_sp3_acceptance.sh <metal_katago> <mlx_katago> <model.bin.gz> <eigen_ref.json> [reps] [cooldown_s]
set -euo pipefail

METAL_BIN="$1"; MLX_BIN="$2"; MODEL="$3"; EIGEN_REF="$4"
REPS="${5:-6}"; COOL="${6:-30}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Arm A: Metal-fp16 vs MLX-fp16
echo "===== Arm A: Metal-fp16 vs MLX-fp16 ====="
ARM_A_LOG="$(mktemp)"
BENCH_A_LABEL=MetalFp16 BENCH_B_LABEL=MlxFp16 \
BENCH_A_FP16=1          BENCH_B_FP16=1 \
  "$HERE/bench_mlx_honest.sh" "$METAL_BIN" "$MLX_BIN" "$MODEL" "$REPS" "$COOL" \
  | tee "$ARM_A_LOG"
CI_A="$(grep -oE 'CI_lower=[+-][0-9]+\.[0-9]+' "$ARM_A_LOG" | tail -1 | cut -d= -f2)"
if [[ -z "$CI_A" ]]; then echo "FATAL: Arm A CI_lower not parsed"; exit 2; fi
echo

# Arm B: MLX-fp32 vs MLX-fp16
echo "===== Arm B: MLX-fp32 vs MLX-fp16 ====="
ARM_B_LOG="$(mktemp)"
BENCH_A_LABEL=MlxFp32 BENCH_B_LABEL=MlxFp16 \
BENCH_A_FP32=1        BENCH_B_FP16=1 \
  "$HERE/bench_mlx_honest.sh" "$MLX_BIN" "$MLX_BIN" "$MODEL" "$REPS" "$COOL" \
  | tee "$ARM_B_LOG"
CI_B="$(grep -oE 'CI_lower=[+-][0-9]+\.[0-9]+' "$ARM_B_LOG" | tail -1 | cut -d= -f2)"
if [[ -z "$CI_B" ]]; then echo "FATAL: Arm B CI_lower not parsed"; exit 2; fi
echo

# Accuracy: testgpuerror
echo "===== Accuracy: testgpuerror (mlxUseFP16 = true) ====="
ACC_LOG="$(mktemp)"
ACC_CFG="$(mktemp).cfg"
cp "$HERE/../configs/gtp_example.cfg" "$ACC_CFG"
sed -i.bak -E 's|^[#[:space:]]*mlxUseFP16[[:space:]]*=.*|mlxUseFP16 = true|' "$ACC_CFG"
rm -f "${ACC_CFG}.bak"
"$MLX_BIN" testgpuerror -model "$MODEL" -config "$ACC_CFG" -reference-file "$EIGEN_REF" \
  | tee "$ACC_LOG"

# Parse worst-case winrate and score errors. testgpuerror's exact output format
# can vary; we look for lines containing "winrate" and "score" with numeric
# values. The orchestrator extracts the largest absolute error of either.
python3 - "$ACC_LOG" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
winrate_errs = [float(m.group(1)) for m in re.finditer(r'winrate[^\d-]*([0-9]*\.?[0-9]+(?:e[+-]?[0-9]+)?)', log, re.I)]
score_errs   = [float(m.group(1)) for m in re.finditer(r'score[^\d-]*([0-9]*\.?[0-9]+(?:e[+-]?[0-9]+)?)', log, re.I)]
w_max = max(winrate_errs) if winrate_errs else None
s_max = max(score_errs)   if score_errs   else None
print(f"WINRATE_MAX={w_max}")
print(f"SCORE_MAX={s_max}")
PY
ACC_W="$(grep -oE 'WINRATE_MAX=[0-9.e+-]+' "$ACC_LOG" | tail -1 | cut -d= -f2 || echo 0)"
ACC_S="$(grep -oE 'SCORE_MAX=[0-9.e+-]+'   "$ACC_LOG" | tail -1 | cut -d= -f2 || echo 0)"

# Gate decisions
PASS_A="$(awk -v c="$CI_A" 'BEGIN { print (c+0 >= 0) ? "PASS" : "FAIL" }')"
PASS_B="$(awk -v c="$CI_B" 'BEGIN { print (c+0 > 0) ? "PASS" : "FAIL" }')"
PASS_ACC="$(awk -v w="$ACC_W" -v s="$ACC_S" 'BEGIN { print (w+0 < 0.001 && s+0 < 0.01) ? "PASS" : "FAIL" }')"

echo "==========================================="
echo "SP3 acceptance summary"
echo "  Arm A (MLX-fp16 - Metal-fp16) CI_lower = $CI_A   [$PASS_A]"
echo "  Arm B (MLX-fp16 - MLX-fp32)   CI_lower = $CI_B   [$PASS_B]"
echo "  Accuracy max winrate err = $ACC_W (limit 1e-3)   [$PASS_ACC]"
echo "  Accuracy max score   err = $ACC_S (limit 1e-2)"
echo "==========================================="

if [[ "$PASS_A" == "PASS" && "$PASS_B" == "PASS" && "$PASS_ACC" == "PASS" ]]; then
  echo "OVERALL: PASS — all three gates satisfied."
  exit 0
fi
echo "OVERALL: FAIL"
exit 1
```

- [ ] **Step 7.2: Smoke-test the orchestrator with the fake katago**

Run the same fake-katago technique used in Task 6 to verify the orchestrator parses harness output and emits the summary block correctly. The accuracy gate will fail (fake katago doesn't emit testgpuerror format) — that's expected; we're testing the parser, not the actual gate.

```bash
chmod +x cpp/tools/bench_sp3_acceptance.sh
TMP=$(mktemp -d)
echo '#!/bin/bash' > "$TMP/fakekatago"
echo 'echo "visits/s = 500.00"' >> "$TMP/fakekatago"
chmod +x "$TMP/fakekatago"
echo "{}" > "$TMP/fake_ref.json"
# Touch a fake model file (path checked, content unused by fake binary)
: > "$TMP/fake_model.bin.gz"
cpp/tools/bench_sp3_acceptance.sh "$TMP/fakekatago" "$TMP/fakekatago" "$TMP/fake_model.bin.gz" "$TMP/fake_ref.json" 1 0 2>&1 | tail -20 || true
```

Expected: prints `SP3 acceptance summary` with Arm A and Arm B lines showing `CI_lower=±0.000` (since fake bench always returns 500.00), and an OVERALL line. Verify the script reached the summary without a parse FATAL.

- [ ] **Step 7.3: Commit**

```bash
git add cpp/tools/bench_sp3_acceptance.sh
git commit -m "SP3 Task 7: acceptance orchestrator (two paired-t arms + testgpuerror)

bench_sp3_acceptance.sh orchestrates:
  Arm A: Metal-fp16 vs MLX-fp16, paired CI_lower on (MLX - Metal) >= 0
  Arm B: MLX-fp32   vs MLX-fp16, paired CI_lower on (MLX_fp16 - MLX_fp32) > 0
  Acc  : testgpuerror with mlxUseFP16=true vs Eigen reference,
         max winrate err < 1e-3, max score err < 1e-2

Emits an SP3 acceptance summary block with per-gate PASS/FAIL and an
overall verdict. Exit 0 iff all three gates PASS.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Acceptance run + Auto→fp16 flip + traceability commit

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp:1319` (Auto resolution flip)
- Modify: `cpp/configs/gtp_example.cfg` (mlxUseFP16 line update)
- New: empty traceability commit

**Background:** This task runs the real acceptance gate. The Auto→fp16 flip and the traceability commit are gated on the gate passing.

- [ ] **Step 8.1: Build fresh binaries for both backends**

```bash
cd cpp

# Metal binary
rm -rf CMakeCache.txt CMakeFiles
cmake -G Ninja -DUSE_BACKEND=METAL && ninja
cp katago /tmp/katago_metal_sp3
ls -la /tmp/katago_metal_sp3

# MLX binary (SP3)
rm -rf CMakeCache.txt CMakeFiles
cmake -G Ninja -DUSE_BACKEND=MLX && ninja
cp katago /tmp/katago_mlx_sp3
ls -la /tmp/katago_mlx_sp3

# Eigen binary (for reference if eigen_reference_b18.json needs regenerating)
rm -rf CMakeCache.txt CMakeFiles
cmake -G Ninja -DUSE_BACKEND=EIGEN -DEIGEN3_INCLUDE_DIRS=/opt/homebrew/opt/eigen@3/include/eigen3 && ninja
cp katago /tmp/katago_eigen_sp3
ls -la /tmp/katago_eigen_sp3
```

- [ ] **Step 8.2: Ensure Eigen reference exists**

```bash
ls -la cpp/eigen_reference_b18.json
```

If missing, generate it once:

```bash
cd cpp
# Use the model file in your environment — adjust path as needed.
MODEL_FILE="$HOME/.katago/networks/b18c384nbt-uec.bin.gz"
test -f "$MODEL_FILE" || { echo "Model file missing: $MODEL_FILE"; exit 1; }
/tmp/katago_eigen_sp3 testgpuerror -model "$MODEL_FILE" -config configs/gtp_example.cfg \
  -reference-file eigen_reference_b18.json
ls -la eigen_reference_b18.json
```

Expected: file exists, size > 0.

- [ ] **Step 8.3: Run the acceptance gate**

```bash
cd cpp
MODEL_FILE="$HOME/.katago/networks/b18c384nbt-uec.bin.gz"
test -f "$MODEL_FILE" || { echo "Model file missing: $MODEL_FILE"; exit 1; }
tools/bench_sp3_acceptance.sh /tmp/katago_metal_sp3 /tmp/katago_mlx_sp3 \
  "$MODEL_FILE" eigen_reference_b18.json 6 30 \
  2>&1 | tee /tmp/sp3_acceptance.log
echo "exit=$?"
```

Expected: `OVERALL: PASS` and exit 0. If FAIL, do NOT proceed to Step 8.4. Instead:
- If Arm A FAIL or Arm B FAIL: thermal drift, kernel regression, or insufficient reps. Re-run with `REPS=10`. If still FAIL, file a spec amendment documenting the empirical numbers.
- If accuracy FAIL: examine `/tmp/sp3_acceptance.log` for the testgpuerror full output. The spec §6 escalation path is "find the layer where the first nonfinite/large-error sample originates" — start with the value head matmul (often the most numerically sensitive).

- [ ] **Step 8.4: Flip Auto→fp16 resolution**

In `cpp/neuralnet/mlxbackend.cpp:1319`, find:

```cpp
  bool useFP16 = (context->useFP16Mode == enabled_t::True);
```

Replace with:

```cpp
  // SP3 (gated on acceptance gate pass): Auto resolves to fp16. Users who
  // need bit-for-bit fp32 reproducibility set `mlxUseFP16 = false` explicitly.
  bool useFP16 = (context->useFP16Mode != enabled_t::False);
```

- [ ] **Step 8.5: Update gtp_example.cfg `mlxUseFP16` line**

In `cpp/configs/gtp_example.cfg`, find the line:

```
# mlxUseFP16 = auto
```

(it's the active default per Task 5's comment update — should be uncommented or commented depending on prior state; inspect with `grep -n mlxUseFP16 cpp/configs/gtp_example.cfg`).

Replace with the same line annotated:

```
# auto resolves to fp16 on MLX as of SP3 (Apple Silicon Winograd validated).
# mlxUseFP16 = auto
```

(Keep the `mlxUseFP16 = auto` line itself commented, as that is the documented default — leaving it commented means users get the default behavior, which is now fp16.)

- [ ] **Step 8.6: Rebuild and re-run tests**

```bash
cd cpp && ninja && ./katago runtests && ./katago runnnlayertests 2>&1 | tail -10
```

Expected: all tests pass with the new Auto→fp16 default.

- [ ] **Step 8.7: Commit the Auto-flip**

```bash
git add cpp/neuralnet/mlxbackend.cpp cpp/configs/gtp_example.cfg
git commit -m "SP3 Auto -> fp16 flip: mlxUseFP16 = auto now means fp16

useFP16 = (useFP16Mode != enabled_t::False) — so:
  auto / unset  -> fp16 (new default)
  true          -> fp16
  false         -> fp32 (opt-out preserved)

Gated on bench_sp3_acceptance.sh PASS. See preceding acceptance traceability
commit for the numbers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 8.8: Empty traceability commit with gate numbers**

Extract the gate numbers from `/tmp/sp3_acceptance.log` and create an empty commit recording them, mirroring SP1/SP2's traceability style:

```bash
# Extract the numbers (these are the actual gate outputs)
ARM_A_LINE="$(grep 'Arm A.*CI_lower' /tmp/sp3_acceptance.log | tail -1)"
ARM_B_LINE="$(grep 'Arm B.*CI_lower' /tmp/sp3_acceptance.log | tail -1)"
ACC_W_LINE="$(grep 'max winrate err' /tmp/sp3_acceptance.log | tail -1)"
ACC_S_LINE="$(grep 'max score   err' /tmp/sp3_acceptance.log | tail -1)"
echo "$ARM_A_LINE"
echo "$ARM_B_LINE"
echo "$ACC_W_LINE"
echo "$ACC_S_LINE"

# Compose the commit message using the extracted lines.
git commit --allow-empty -m "SP3 acceptance: MLX-fp16 Winograd >= Metal-fp16, > MLX-fp32 (SP2)

  $ARM_A_LINE
  $ARM_B_LINE
  $ACC_W_LINE
  $ACC_S_LINE

Hardware: Apple Silicon (M-series), 19x19, b18c384nbt-uec.
Methodology: paired-t 95% CI on per-rep deltas, A/B/A/B/... interleaved,
warmup discard, ${COOL:-30}s cooldown between reps (spec §7).

Selective fp32 accumulation:
  - MLX steel gemm AccumType=float (mma.h:772 static assert) at the matmul.
  - BatchNorm mergedScale/mergedBias stored fp32; multiply-add-activation
    auto-promotes to fp32; cast back to fp16 at end of apply().

Tuner produced a separate cache file at
  ~/.katago/mlxwinotuning/tunemlxwino1_gpuAppleSilicon_x19_y19_c384_mv13_fp16.txt
with fp16-specific tg0/tg1 geometry; fp32 cache file unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (run by the controller after writing this plan)

**1. Spec coverage**

| Spec section | Tasks |
|--------------|-------|
| §3 item 1 (kernel templatization) | Task 1 |
| §3 item 2 (ConvLayer gate drop) | Task 3 |
| §3 item 3 (tuner cache dtype) | Task 4 + Task 5 (wiring) |
| §3 item 4 (BN fp32 intermediate, REQUIRED) | Task 2 |
| §4 file table | Tasks 1-8 collectively |
| §5 data flow (build + inference + cache key + bench) | Tasks 5, 7 |
| §6 error handling | Inherited via Tasks 1-5 (StringError propagation unchanged); Task 8 escalation path documented in Step 8.3 |
| §7.1 accuracy gate | Task 8 Step 8.3 (testgpuerror) |
| §7.2 Arm A paired-t parity | Task 6 + Task 7 |
| §7.3 Arm B paired-t strict | Task 6 + Task 7 |
| §7 default-flip commit | Task 8 Steps 8.4-8.7 |
| §7 traceability commit | Task 8 Step 8.8 |

All spec sections covered.

**2. Placeholder scan**

No "TBD", no "implement later", no "add validation" — every code step shows complete code or exact command.

**3. Type consistency**

- `BatchNormLayer` ctor param renamed `useFP16` → `useFP16_` (Task 2 Step 2.4) consistent with `ConvLayer` ctor pattern (Task 3 Step 3.3).
- `loadOrAutoTune` argument order: `bool useFP16` immediately before `seedOverride` in declaration (Task 4 Step 4.3) and at the single ComputeHandle call site (Task 5 Step 5.1) and at the test call site (Task 4 Step 4.6).
- `defaultFileName` argument order: `bool useFP16` as the final param in declaration (Task 4 Step 4.3) and the single call site inside `loadOrAutoTune` (Task 4 Step 4.5) and the new test (Task 4 Step 4.1).
- `makeWinogradWeights` and `winogradConv2d` `bool useFP16` as final param with default `false` (Task 1 Steps 1.4-1.5), preserving call-site compatibility for any caller not yet updated.

Consistent.
