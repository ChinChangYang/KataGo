# MLX v15+ Pass Policy Fix — Design

**Status:** Proposed 2026-05-26.

**Branch:** `mlx-ane-policy-optimism-stride-fix` (next commit will land on
this branch).

**Related:**
- `2026-05-25-mlx-ane-policy-optimism-stride-design.md` — fixed the
  NHWC/NCHW stride bug for the *spatial* policy on the ANE branch.
  This spec fixes the *pass* policy, which has a different (deeper)
  bug that the spatial-stride fix left in place.
- `2026-05-24-mlx-ane-nchw-conversion-design.md` — input-side NHWC→NCHW
  transpose for ANE.

## Problem

The MLX backend's `PolicyHead` is incomplete for **modelVersion ≥ 15**.
It implements only the first matmul of the v15+ two-layer pass head
(`gpoolToPassMul`), missing the bias-add, activation, and second matmul
(`gpoolToPassMul2`). It also derives `numPolicyPassChannels` from
`gpoolToPassMul.outChannels` — which for v15+ is the **hidden** width,
not the final pass output width.

These two errors compound into two observable symptoms.

### Symptom 1: MLX/GPU pass logits are wrong for v15+ models

`PolicyHead.apply()` in `cpp/neuralnet/mlxbackend.cpp:911-942` returns
`gpoolToPassMul.apply(pooledFlat)` directly as the pass output. For a
v15+ model that's the hidden activation (e.g., 48 floats), not the pass
logit. The post-processor reads `policyPassSrcBuf[0]` and
`policyPassSrcBuf[1]` — getting `HIDDEN[0]` and `HIDDEN[1]`, not the
actual pass-channel logits.

Empirical reproduction on `b5c192nbt-v16test.bin.gz` (4 policy channels,
hidden = 48), 19×19 rectangle test set:

```
fp32 (unbatched) error vs Eigen topPolicyDelta:
  avg 1.57%  90% 2.62%  99% 12.42%  max 72.80%
batched fp32: same shape (~72% max)
```

Most positions are fine (pass is rarely the top move). The heavy tail
hits the ~4% of positions where Eigen's argmax is the pass position.

### Symptom 2: ANE batched pass logits are garbage for rows ≥ 1

The mlpackage built by `katagocoreml` correctly implements the v15+
two-layer pass and emits a final output of shape `[1, numPolicyChannels]`
(e.g., `[1, 4]`). Swift's `extractOutputs` writes this contiguously into
`policyPass` at offset `batchIndex * numPolicyChannels`
(`cpp/neuralnet/metalbackend.swift:316`). So batch *b* lives in
`policyPass[b*C .. (b+1)*C - 1]`, with `C = numPolicyChannels = 4`.

But the C++ post-processor reads `policyPassData + row *
numPolicyPassChannels` (`cpp/neuralnet/mlxbackend.cpp:1886`). With
`numPolicyPassChannels = gpoolToPassMul.outChannels = 48`:

- row 0 reads `pass[0..1]` — lands inside Swift's `pass[0..3]`. Correct
  pass channels 0 and 1. ✓
- row 1 reads `pass[48..49]` — Swift wrote at `pass[4..7]`, never at
  `pass[48..]`. **Uninitialized / stale data.** ✗
- row *r* reads `pass[r*48 .. r*48+1]` — garbage for `r ≥ 1`.

Empirical reproduction on the same model:

```
ANE rectangle, fp32 unbatched:  max topPolicyDelta 0.00022%  (CLEAN)
ANE rectangle, fp32 batched:    max topPolicyDelta 41.01%   (heavy tail)
ANE size19,    fp32 batched:    max topPolicyDelta 25.03%   (heavy tail)
```

Unbatched batchSize=1 only ever runs row 0 → reads correct pass values.
Batched batchSize > 1 fires the bug on rows 1+. The earlier validation
snapshot misattributed the 25% size-19 number to "FP16 noise on a single
position"; in reality it is **this** bug, deterministic, fp32, and the
same root cause as the 41% rectangle number.

### Root cause

For `modelVersion ≥ 15`, KataGo's `PolicyHeadDesc`
(`cpp/neuralnet/desc.cpp:1280-1300`) parses a two-layer pass head:

```
gpoolToPassMul  : pooled (g1*3 channels) -> hidden (p1Conv.outChannels)
gpoolToPassBias : hidden bias
passActivation  : ReLU / Mish
gpoolToPassMul2 : hidden -> output (= numPolicyChannels)
```

`desc.cpp:1336-1343` asserts: `gpoolToPassMul.outChannels ==
p1Conv.outChannels` (hidden) and `gpoolToPassMul2.outChannels ==
policyOutChannels` (numPolicyChannels). For `b5c192nbt-v16test` this is
48 vs 4; for `b18c384nbt-humanv0` it is 48 vs 2.

The Metal backend (`cpp/neuralnet/metalbackend.cpp:298-315`) reads all
four layers from `policyHead` and forwards them to Swift's MPSGraph;
Metal's post-processor uses `policyResultChannels = numPolicyChannels`
as the pass stride (`metalbackend.cpp:830`). It is correct.

The MLX backend's `PolicyHead` struct (`mlxbackend.cpp:881-943`)
declares only `gpoolToPassMul` — the other three v15+ layers are simply
absent. Its `apply()` invokes only that one matmul, and the surrounding
`ComputeContext` derives `numPolicyPassChannels` from
`gpoolToPassMul.outChannels`. The two design omissions are coupled:
either alone would produce a buffer-size mismatch.

### Why it escaped review

- The 2026-05-25 `runMLXCoreMLSmokeTest` parity check (`mlxtests.cpp:1219+`)
  runs `getOutput` with batchSize = 1 and asserts only top-1 spatial
  policy index parity. The pass position (index `HW = nnXLen*nnYLen`)
  was never compared; batchSize > 1 never executed; so the v15+ ANE
  bug shape (batched rows ≥ 1 garbage) had no surface area in the test.
- The 2026-05-25 stride-fix validation focused on `topPolicyDelta max`
  on size 19. The 25% residual was attributed to "FP16 noise on a single
  argmax-tied position" — plausible but wrong; it is the same bug
  manifesting only when the pass position is the argmax.
- The cross-backend `testgpuerror` sweep up to this branch did not
  exercise rectangle v15+ on ANE; the 2026-05-23 sweep used a v11
  model (`numPolicyChannels = 1`), which never enters either bug path.
- MLX/GPU v15+ pass policy has been silently wrong since the MLX
  backend was first introduced (`81b00db3`); v15 models are recent
  enough that no one noticed during MLX bring-up.

## Goal

After this fix, on a v15+ model:

1. **MLX/GPU**: pass logits match Eigen reference within ordinary FP
   tolerance. The "pass-position argmax" subset of the heavy tail
   disappears from `testgpuerror`. v16 b5c192 rectangle MLX/GPU
   topPolicyDelta max drops from ~72% to ≤ ~1%.
2. **MLX/ANE batched**: pass logits match Eigen within FP16 tolerance
   for **all** batch rows, not just row 0. v16 b5c192 rectangle ANE
   batched fp32 topPolicyDelta max drops from ~41% to ≤ ~1%; size-19
   ANE batched fp32 drops from ~25% to ≤ ~1%.
3. Pre-v15 models (v8, v11, v12, v13, v14): zero behavior change.
   numPolicyChannels = 1 models do not enter either modified path;
   numPolicyChannels = 2 v12-v14 models still use the single-matmul
   pass (no two-layer code path triggered).

## Non-Goals

- Changing `katagocoreml::KataGoConverter` or the mlpackage MIL graph.
  The converter already produces correct v15+ output (Symptom 2 proves
  this: row 0 reads the correct data; the only issue is the C++ side's
  stride assumption).
- Changing Swift's `extractOutputs` or `copyMultiArray`. Swift's per-
  batch offset (`batchIndex * numPolicyChannels`) is already correct
  for the actual MLMultiArray width; it is the C++ side that drifts.
- Refactoring `numPolicyPassChannels` out of the public-ish ABI between
  `Model`, `ComputeHandle`, and `InputBuffers`. Keep the field, change
  its derivation.
- Adding a v15+ model to the standing `gpu_error_reference_files/` set
  for the continuous sweep. Useful follow-up; out of scope for this
  fix's minimum diff.

## Design

### Components touched

| File | Change | Approx LoC |
|---|---|---:|
| `cpp/neuralnet/mlxbackend.cpp` — `PolicyHead` struct | Add `gpoolToPassBias`, `passActivation`, `gpoolToPassMul2` field declarations and constructor initializers; gated on `modelVersion >= 15` in the ctor body for the two new matmul/bias layers since they are not parsed for pre-v15. | ~20 |
| `cpp/neuralnet/mlxbackend.cpp` — `PolicyHead::apply()` | After `gpoolToPassMul`, for `modelVersion >= 15`, add bias, activation, then `gpoolToPassMul2`. Mirrors `desc.cpp` parsing order. | ~10 |
| `cpp/neuralnet/mlxbackend.cpp` — `Model::numPolicyPassChannels` initializer | Compute from `policyHead.gpoolToPassMul2.outChannels` when `modelVersion >= 15`, else from `gpoolToPassMul.outChannels`. | ~3 |
| `cpp/neuralnet/mlxtests.cpp` — `runMLXCoreMLSmokeTest` parity check | Extend to (a) run `getOutput` with batchSize ≥ 2 — driving the batched ANE path — and (b) compare the pass-policy value (index `nnXLen*nnYLen`), not only top-1 spatial index. Closes the CI gap. | ~25 |

Total functional diff ≈ 35 lines; test diff ≈ 25 lines. No public API.

### `PolicyHead` struct change

Mirror `desc.cpp:1289-1299`. The v15+ fields are unconditionally
constructed; for pre-v15 the underlying `MatMulLayerDesc` /
`MatBiasLayerDesc` / `ActivationLayerDesc` default-constructed instances
have all-zero or empty weight arrays, so the inner `MatMulLayer` etc.
constructors must tolerate this — or the new fields must be wrapped in
`std::optional` and only populated when `modelVersion >= 15`.

The cleaner choice is `std::optional<MatMulLayer> gpoolToPassMul2;`
(and similarly for bias/activation). Construction:

```cpp
gpoolToPassMul(desc.gpoolToPassMul, useFP16),
gpoolToPassBias(modelVersion >= 15
                  ? std::optional<MatBiasLayer>(MatBiasLayer(desc.gpoolToPassBias, useFP16))
                  : std::nullopt),
passActivationType(modelVersion >= 15 ? desc.passActivation.activation : 0),
gpoolToPassMul2(modelVersion >= 15
                  ? std::optional<MatMulLayer>(MatMulLayer(desc.gpoolToPassMul2, useFP16))
                  : std::nullopt)
```

(Naming follows existing `MatMulLayer`/`MatBiasLayer`/etc. conventions in
the same file. `passActivationType` stored as `int` to match the existing
`p1Activation` pattern at `policyHead.cpp:933`.)

### `PolicyHead::apply()` change

Current code:

```cpp
mx::array policyPass = gpoolToPassMul.apply(pooledFlat);
```

Replace with:

```cpp
mx::array policyPass = gpoolToPassMul.apply(pooledFlat);
if(modelVersion >= 15) {
  policyPass = gpoolToPassBias->apply(policyPass);
  policyPass = applyActivation(policyPass, passActivationType);
  policyPass = gpoolToPassMul2->apply(policyPass);
}
```

`applyActivation` is the existing helper at `mlxbackend.cpp:250`.
`MatBiasLayer::apply` is the same helper used by `gpoolToBiasMul`'s
caller path; if no per-element apply method exists, replace with the
inline equivalent (`return x + biasArr` with proper broadcast).

### `numPolicyPassChannels` initializer change

Current:

```cpp
numPolicyPassChannels(desc.policyHead.gpoolToPassMul.outChannels),
```

Replace with:

```cpp
numPolicyPassChannels(desc.modelVersion >= 15
                        ? desc.policyHead.gpoolToPassMul2.outChannels
                        : desc.policyHead.gpoolToPassMul.outChannels),
```

This makes the C++ stride equal to the actual final-output width on
both code paths, matching Swift's `numPolicyChannels`-based offset on
the ANE path **and** the new `gpoolToPassMul2` output width on the
MLX/GPU path. The assertion at `mlxbackend.cpp:1868`
(`singlePolicyPassResultElts == numPolicyPassChannels`) still holds
because `singlePolicyPassResultElts` is derived from the same field.

### Why these three changes must land together

- Implementing `gpoolToPassMul2` alone (without fixing
  `numPolicyPassChannels`) makes the MLX/GPU `memcpy` at
  `mlxbackend.cpp:1170` read past the end of `policyPass.data<float>()`:
  it would copy `batchSize * 48 * sizeof(float)` bytes from a `(batch,
  4)`-sized array. Buffer over-read.
- Fixing `numPolicyPassChannels` alone (without implementing
  `gpoolToPassMul2`) makes MLX/GPU under-copy: only the first 4
  floats per row of the still-48-wide hidden output would land in the
  buffer, scrambling pass values across rows. Worse than the current
  state.
- The smoke-test addition (parity at batchSize ≥ 2 with pass-position
  comparison) gives CI signal that the fix actually addresses the
  empirical bug; without it, a future regression of this class would
  again ship undetected.

### Smoke-test extension

Build the existing `runMLXCoreMLSmokeTest` parity block with a
second NNResultBuf (batchSize = 2), assert pass-position parity
(`outAne.policyProbs[nnXLen * nnYLen]` vs
`outGpu.policyProbs[nnXLen * nnYLen]`) within FP16 tolerance, and assert
both batch rows agree (catches the row-≥-1-garbage shape directly).

Gating stays: modelVersion ≥ 12 (numPolicyChannels ≥ 2 required for the
optimism postprocessor), metaEncoderVersion == 0 (test uses
hasRowMeta = false).

## Testing

| # | Test | Pre-fix | Pass criterion |
|---|---|---:|---|
| 1 | `testgpuerror` v16 b5c192 sizerect ANE batched fp32 | 41.01% topPolicyDelta max | ≤ 1% max |
| 2 | `testgpuerror` v16 b5c192 sizerect MLX/GPU fp32 | 72.80% max | ≤ 1% max |
| 3 | `testgpuerror` v16 b5c192 size19 ANE batched fp32 | 25.03% max | ≤ 1% max |
| 4 | `testgpuerror` humanv0 v15 sizerect ANE & MLX/GPU | re-measure first | ≤ 1% max each |
| 5 | `testgpuerror` b18 v11 sizerect ANE & MLX/GPU | clean | unchanged |
| 6 | `./katago runnnlayertests` with `MLX_COREML_TEST_MODEL=models/b5c192nbt-v16test.bin.gz` | smoke passes | smoke passes AND new batched-pass parity asserts pass |
| 7 | `./katago runtests` | passes | passes |

After validation, update `.claude/MLX_Validation.md`: correct the
2026-05-25 snapshot's misattribution of the 25% size-19 figure to
"FP16 noise," and record post-fix numbers for the v15+ rectangle cases.

## Rollout

Single commit (or two — separate the C++ functional change from the
smoke-test extension if that helps review) on
`mlx-ane-policy-optimism-stride-fix`. No config changes. No public ABI
changes. Existing v11 / pre-v15 workflows unchanged.

## Future Work (out of scope)

- Add `b5c192nbt-v16test.bin.gz` (or any v15+ model) to
  `cpp/tests/results/gpu_error_reference_files/` so the standing
  cross-backend GPU-error sweep covers the v15+ pass class
  unconditionally, not only when `MLX_COREML_TEST_MODEL` points at one.
- Audit MLX backend for other v15+-only architectural pieces the
  initial port may have stubbed. The trunk's nested-bottleneck blocks
  and any other modelVersion-gated parsing paths in `desc.cpp` are the
  obvious candidates to spot-check against the Metal backend.
- Generalize the smoke-test parity helper so it can compare arbitrary
  output positions (pass, score-value, ownership) across paths, not
  just spatial top-1. Would shorten this kind of bug's mean-time-to-CI-
  signal.
