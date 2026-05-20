# SP3 — MLX Winograd fp16 with Selective fp32 Accumulation — Design

**Status:** Approved 2026-05-20.
**Predecessors:** SP1 (`2026-05-19-mlx-winograd-fp32-conv-design.md`) shipped Winograd at fp32. SP2 (`2026-05-20-mlx-winograd-autotuner-design.md`) added the autotuner. This spec covers SP3 — the deferred fp16 follow-up.

---

## 1. Goal

Enable Winograd F(2,3) in fp16 mode on the MLX backend, with selective fp32 accumulation at the matmul reduction step. Land a config-default policy that flips `mlxUseFP16 = auto` to mean fp16, gated on a strict two-arm acceptance test.

The phrase "selective fp32 accumulation" is precise: storage is fp16, kernel-internal arithmetic in the two Winograd transform kernels is fp16, but the batched matmul over `Cin` (the only reduction with overflow risk) accumulates in fp32. MLX's steel gemm uses `AccumType = float` by default with a static assert — we get the fp32 accumulator for free, no explicit cast needed.

## 2. Scope

**In:**
- Drop the `!useFP16` gate on `useWinograd` (`mlxbackend.cpp:195`).
- Templatize the two Winograd Metal kernel sources on `T` (`mx::float16` / `mx::float32`) via MLX's `template_args` API.
- `MLXWinograd::makeWinogradWeights` returns dtype-aware weights (host transform stays fp32 for accuracy, then cast).
- Tuner cache filename gains a `_fp16` / `_fp32` suffix; on first fp16 inference, a fresh tune runs (~30s).
- Update header comment in `mlxbackend.cpp:7` and the config comment in `gtp_example.cfg`'s `mlxUseFP16` block.
- After acceptance gate passes, `enabled_t::Auto` on MLX resolves to fp16 (currently fp32 by `useFP16Mode == enabled_t::True` at `mlxbackend.cpp:1319`).

**Out:**
- F(4,3) larger tiles — fp16 makes F(4,3)'s rounding error worse; the SP1 deferral stands.
- Quantization (int8/int4) — separate sub-project.
- Per-layer mixed-precision policies — the existing whole-graph `bool useFP16` flag is the only knob; no per-layer override.

## 3. Architecture

Single point of dtype dispatch lives at the `ComputeHandle` layer (already does). Everything below — `Model`, `ResidualBlock`, `ConvLayer`, `MatMulLayer`, `BatchNormLayer` — already accepts `bool useFP16`. SP3 only changes the *Winograd* layer's behavior when the flag is true.

Three changes in dependency order:

1. **`mlxwinograd.h` — kernel templatization.**
   - `kWinoInputSource` and `kWinoOutputSource` swap `float` → `T` for storage-typed locals (input tile `d[4][4]`, output `V0..V3`, etc.). Compile-time literals stay `float` — Metal implicitly converts to `T` on assign.
   - `winogradConv2d` signature gains `bool useFP16`. Passes `{{"T", useFP16 ? mx::float16 : mx::float32}}` as `template_args`. Output_dtypes match the dtype.
   - `makeWinogradWeights` signature gains `bool useFP16`; after building the fp32 host array, returns `mx::astype(arr, mx::float16)` if requested. Host transform stays fp32 (one-time, accuracy-critical).
   - Kernel name strings become `wino_input_transform_f16` / `wino_input_transform_f32` (same for output) to avoid JIT-cache collision.

2. **`mlxbackend.cpp` ConvLayer — drop the gate, thread the flag.**
   - Line 195: `useWinograd(!useFP16 && ...)` → `useWinograd(mlxWinogradEnabled() && convYSize==3 && convXSize==3 && dilationY==1 && dilationX==1)`. The `!useFP16` clause goes.
   - Lines 199-201: `makeWinogradWeights(..., useFP16)`.
   - `ConvLayer::apply()` passes `useFP16` to `winogradConv2d`.
   - Header comment (line 7) rewritten to reflect SP3's outcome.

3. **`mlxwinotuner.cpp` / `.h` — dtype-aware cache key.**
   - `MLXWinogradTuner::defaultFileName(...)` gains `bool useFP16`; appends `_fp16` or `_fp32` before `.txt`.
   - `loadOrAutoTune(...)` signature gains `bool useFP16`, threads it through to `defaultFileName` and to the search timing kernel (which calls `winogradConv2d` with the right dtype so geometry is measured at the active precision).
   - Anchor seed `{32,1}/{32,1}` stays — for fp16 the search rediscovers an fp16-optimal geometry from this anchor; the anchor doesn't have to be fp16-optimal.

**Selective fp32 accumulation — where it actually lives:**
- Matmul stage (`mx::matmul(V_fp16, U_fp16)`): MLX's `/opt/homebrew/include/mlx/backend/metal/kernels/steel/gemm/gemm.h:35` uses `AccumType = typename AccumHelper<T>::accum_type`, `transforms.h:58` defines `typedef float accum_type`, and `mma.h:772` static-asserts `is_same_v<AccumType, float>`. Fp32 accumulation is automatic; no code change.
- Input/output transform kernels: 4-element fp16 sum chains. No overflow risk.
- BatchNorm `mergedScale * input + mergedBias`: fp16, unchanged from pre-SP3.

**Data flow (steady state):**
```
fp16 NHWC input
  → [inputTransform kernel, T=half] → fp16 [16, Ntiles, C]
  → [mx::matmul, fp16 in, fp32 accum, fp16 out] → fp16 [16, Ntiles, Cout]
  → [outputUntransform kernel, T=half] → fp16 NHWC output
```

## 4. Components & Files

| File | Change |
|------|--------|
| `cpp/neuralnet/mlxwinograd.h` | Templatize kernel sources on `T`; `winogradConv2d` and `makeWinogradWeights` gain `bool useFP16`; kernel names suffixed `_f16`/`_f32` |
| `cpp/neuralnet/mlxbackend.cpp` | Drop `!useFP16` gate on `useWinograd`; thread `useFP16` through `ConvLayer::apply` → `winogradConv2d` and through `makeWinogradWeights`; update header comment |
| `cpp/neuralnet/mlxwinotuner.h` | Add `bool useFP16` param to `defaultFileName(...)`, `loadOrAutoTune(...)` |
| `cpp/neuralnet/mlxwinotuner.cpp` | Filename: append `_fp16`/`_fp32` before `.txt`; pass dtype into the timing path so the search times kernels at the active precision |
| `cpp/neuralnet/mlxbackend.cpp` (ComputeHandle ctor) | Pass `useFP16` into `loadOrAutoTune`; the existing `mlxWinotunerEnabled() && !useFP16` gate becomes `mlxWinotunerEnabled()` (tune at every precision) |
| `cpp/neuralnet/mlxbackend.cpp` (line 1319) | Final commit (gated on acceptance) flips `Auto` resolution: `(... == True)` → `(... != False)` |
| `cpp/tests/testnn.cpp` | Extend `Tests::runMLXWinotunerTests()` with fp16 round-trip; extend Winograd layer tests with an fp16 axis |
| `cpp/configs/gtp_example.cfg` | Update the `mlxUseFP16 = auto` comment to reflect new policy ("auto enables fp16 Winograd via SP3") |
| `cpp/tools/bench_mlx_honest.sh` | New env-var hooks `BENCH_MLX_FP16=1`, `BENCH_METAL_FP16=1` that materialize a temp config with the right `*UseFP16` line |
| `cpp/tools/bench_sp3_acceptance.sh` (new) | Orchestrates both gate arms back-to-back, plus `testgpuerror` |

**Test surface:**
- `runnnlayertests` adds an fp16 axis to `testEvaluateConvLayer`, `testEvaluateResidualBlock`, `testEvaluateGlobalPoolingResidualBlock`.
- `runMLXWinotunerTests` gains fp16 round-trip and fp16 search-works.
- `testgpuerror` (manual, with `eigen_reference_b18.json`) is the cross-backend accuracy gate.

## 5. Data Flow

### Build time (first inference in fp16 mode)

```
ComputeContext ctor (homeDataDirOverride, logger)
  ↓
ComputeHandle ctor (useFP16=true)
  ↓
  if mlxWinogradEnabled() && mlxWinotunerEnabled():
    MLXWinogradTuner::loadOrAutoTune(
      modelInfo, homeDataDir, useFP16=true, logger)
    ↓
    fileName = "tunemlxwino1_gpuAppleSilicon_x19_y19_c384_mv13_fp16.txt"
    if exists and valid → load, return  (cache hit, ~0 ms)
    else:
      seedOverride = {32,1}/{32,1}              (SP1 baked default)
      searchInputTransform(useFP16=true, seedOverride)   (~15s, 45 valid)
      searchOutputUntransform(useFP16=true, seedOverride) (~10s, 25 valid)
      save → return tuneParams                  (cache cold, one-time ~30s)
  ↓
  Model ctor (desc, tuneParams, useFP16=true)
    ↓ threads tuneParams + useFP16 into every ConvLayer
    ↓ ConvLayer ctor: useWinograd=true; makeWinogradWeights(weights, useFP16=true)
      → host transform fp32 → mx::astype(arr, mx::float16) → fp16 [16, Cin, Cout]
```

### Inference time (steady state)

```
input: fp16 NHWC [N, H, W, Cin]
  ↓ ConvLayer::apply
    ↓ winogradConv2d(input, Uw_fp16, Cout, inCfg, outCfg, useFP16=true)
      Stage 1: metal_kernel("wino_input_transform_f16",
                            template_args={{"T", mx::float16}},
                            output_dtypes={mx::float16},
                            grid=(C, Ntiles, 1),
                            threadgroup=(inCfg.tg0, inCfg.tg1, 1))
        → V: fp16 [16, Ntiles, C]
      Stage 2: mx::matmul(V_fp16, Uw_fp16)
        → MLX steel gemm: reads fp16, accumulates fp32, writes fp16
        → M: fp16 [16, Ntiles, Cout]
      Stage 3: metal_kernel("wino_output_untransform_f16",
                            template_args={{"T", mx::float16}},
                            output_dtypes={mx::float16},
                            grid=(Cout, Ntiles, 1),
                            threadgroup=(outCfg.tg0, outCfg.tg1, 1))
        → output: fp16 NHWC [N, H, W, Cout]
```

### Cache key flow

```
makeCacheKey(batchSize, nnXLen, nnYLen, useMask, hasMeta, useFP16, tuneParams)
  → "...b{N}_x{X}_y{Y}_um{0/1}_hm{0/1}_fp{16/32}-it{tg0}x{tg1}-ou{tg0}x{tg1}"
```

Two ComputeHandles in the same process with different `useFP16` resolve to *different* tuneParams (different cache file → potentially different geometry) and *different* cache keys, so the Model objects don't collide.

### Acceptance bench flow

```
bench_sp3_acceptance.sh
  → Arm A: bench_mlx_honest.sh BENCH_MLX_FP16=1 BENCH_METAL_FP16=1
           (interleaved A/B/A/B, 7 reps, warmup-discard)
  → Arm B: bench_mlx_honest.sh BENCH_MLX_FP16=1 BENCH_MLX_FP32_REFERENCE=1
           (Metal disabled; MLX-fp16 vs MLX-fp32 interleaved)
  → testgpuerror -model b18c384nbt-uec.bin.gz -config gtp_example.cfg
                 -reference-file eigen_reference_b18.json
                 with mlxUseFP16=true
  → Report: { armA: {metalFp16Mean, mlxFp16Mean, delta, CI, pass},
              armB: {mlxFp32Mean, mlxFp16Mean, delta, CI, pass},
              accuracy: {winrateError, scoreError, pass} }
  → Overall PASS iff all three pass
```

## 6. Error Handling and Edge Cases

**Kernel JIT compile failure.** Existing SP2 error path (`StringError` propagation from `winogradConv2d`) handles `mx::fast::metal_kernel` throws. The first fp16 Winograd call after the gate is dropped uses the same path as fp32 — no new error machinery.

**Tuner cache file collision.** Stale `tunemlxwino1_*.txt` (pre-SP3, no dtype suffix) on disk: the SP3 loader looks for `_fp32.txt` / `_fp16.txt` and won't find it. Cold-tune runs once per dtype. We do *not* add a migration step — file is tiny, regenerating costs 30s, and silent format upgrades risk applying stale fp32 geometry to fp16. Documented as "first-run cost on upgrade."

**MLX 0.31.2 metal_kernel template_args.** Verified `TemplateArg = std::variant<int, bool, Dtype>` in `/opt/homebrew/include/mlx/fast.h:57`. Passing `{{"T", mx::float16}}` is well-formed. If the wrapper-generated kernel signature doesn't substitute `T` correctly, JIT compile errors surface at first inference — fail-fast, no silent miscompute. Task 1's first step is a smoke test that proves the templated kernel runs and matches the non-templated fp32 baseline within fp32 round-trip error.

**Auto-resolution change is a user-visible default flip.** The final commit changes `mlxbackend.cpp:1319` from `useFP16Mode == enabled_t::True` to `useFP16Mode != enabled_t::False`. Any user with `mlxUseFP16 = auto` (or commented-out, which defaults to auto) starts running fp16 on next launch. Documented in the `gtp_example.cfg` block. Users who require fp32 set `mlxUseFP16 = false` explicitly. The flip lives in a *separate, final commit* gated on the acceptance gate — clean revert target.

**Accuracy edge cases.**
- The b18c384 model has 25 residual blocks deep; fp16 round-trip error compounds. The matmul fp32 accumulation contains this, but the BatchNorm and activation chains stay fp16. Empirical validation via `testgpuerror`'s tolerances (< 0.1% winrate, < 0.01 score) is the only end-to-end check.
- If `testgpuerror` fails, the response is *not* to widen tolerances. The remedy is: cast `BatchNormLayer::apply`'s intermediate `mergedScale * x + mergedBias + activation` chain to fp32, store fp16. Conservative fallback only if needed.

**Tuner search-works test for fp16.** SP2's existing `runMLXWinotunerTests` search-works test runs at fp32 (anchor seed `{1,1}` proves the search beats a bad seed). For SP3, we replicate with `useFP16=true`. Same threshold (`≤ 0.8 × bad-seed`), same `≤ 1.05 × optimum`. The threshold's hardware basis (Apple Silicon coalesces sub-SIMD threadgroups) is precision-independent.

**bench harness env-vars.** `bench_mlx_honest.sh` shells `katago` with a config-file path. SP3 introduces `BENCH_MLX_FP16` / `BENCH_METAL_FP16` env-vars that the script reads and uses to materialize a temporary config (`sed` the relevant `*UseFP16` line) before invoking `katago`. Failure to materialize the temp config raises a clear shell error.

## 7. Acceptance Gate

SP3 PASSES if and only if all three of the following hold on Apple Silicon (M-series) hardware with the b18c384nbt-uec.bin.gz model at 19×19:

### 7.1 Accuracy (testgpuerror vs Eigen reference)

`./katago testgpuerror -model b18c384nbt-uec.bin.gz -config gtp_example.cfg -reference-file eigen_reference_b18.json` with `mlxUseFP16 = true` reports:
- Average winrate error < 0.1 % (1e-3 absolute).
- Average score error < 0.01 (1e-2 absolute).

These tolerances mirror CLAUDE.md's documented working tolerance for a proper cross-backend test.

### 7.2 Arm A — MLX-fp16 ≥ Metal-fp16

`bench_sp3_acceptance.sh` Arm A reports MLX-fp16 mean throughput ≥ Metal-fp16 mean throughput.

CI-aware: lower CI bound of MLX-fp16 ≥ lower CI bound of Metal-fp16, OR delta of means > sum of CI half-widths.

### 7.3 Arm B — MLX-fp16 > MLX-fp32 (SP2 baseline, strict)

`bench_sp3_acceptance.sh` Arm B reports MLX-fp16 mean throughput strictly greater than MLX-fp32 mean throughput.

CI-aware: lower CI bound of MLX-fp16 > upper CI bound of MLX-fp32 (strict, non-overlapping CIs).

### Asymmetry rationale

Arm B is the *justification* for the engineering effort. If fp16 doesn't strictly improve over fp32 on MLX with non-overlapping CIs, there's no reason to default users to fp16 — fp32 is more accurate at no perf cost. Arm A is *parity*: MLX-fp16 must be competitive with Apple's Metal at the same precision tier, not necessarily strictly faster. Allowing Arm A to be ≥ (rather than >) lets us merge if MLX-fp16 lands within Metal-fp16's CI band — a tie worth taking given the architectural cost already paid.

### Calibration discipline (inherited from SP2)

Apple Silicon's Metal driver coalesces sub-SIMD threadgroups. Empirical search-works dynamic range is ~1.5× (not textbook 2×). The `≤ 0.8 × bad-seed` threshold in the search-works fp16 test inherits SP2's hardware-realistic calibration; not re-derived.

### Default-flip commit (gated)

If all three gates pass, the *final* commit changes `mlxbackend.cpp:1319` from `useFP16Mode == enabled_t::True` to `useFP16Mode != enabled_t::False` and updates the `gtp_example.cfg` `mlxUseFP16` block comment to: `# auto: fp16 (default, SP3-validated faster than fp32 on Apple Silicon)`.

If any gate fails, the implementation lands without the auto-flip; this spec is amended to document which gate failed and the empirical numbers; user-explicit `mlxUseFP16 = true` still works but auto stays fp32.

### Traceability commit

Empty commit titled `SP3 acceptance: MLX-fp16 Winograd >= Metal-fp16, > MLX-fp32 (SP2)` with gate numbers — mirrors SP1's `468883f5` and SP2's `6097808d` style.

## 8. Deferred (out of scope, future SP)

- **F(4,3) larger tiles.** F(4,3) reduces FLOPs further but amplifies rounding error; fp16 makes this worse. SP1 deferred this; SP3 keeps it deferred.
- **Quantization (int8 / int4).** Separate sub-project; needs different kernels and a calibration pipeline.
- **Per-layer mixed-precision policies.** Today's `bool useFP16` is whole-graph. A future SP could add per-layer overrides (e.g., keep value-head logits fp32) if testgpuerror reveals a specific accuracy hot-spot. Not needed unless 7.1 fails.
