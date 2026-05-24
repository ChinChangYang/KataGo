# MLX Backend ANE/CoreML Mask Buffer Fix — Design

**Date:** 2026-05-24
**Branch:** mlx-backend-squash
**Scope:** `cpp/neuralnet/mlxbackend.cpp` only

## Problem

In `NeuralNet::getOutput` (`cpp/neuralnet/mlxbackend.cpp:1747-1768`), the
ANE/CoreML dispatch path unconditionally fills the mask input with `1.0f`:

```cpp
std::vector<float> aneMaskBuf(batchSize * nnXLen * nnYLen, 1.0f);
computeHandle->coremlOnlyHandle.get().apply(
  inputBuffers->spatialInput.data(),
  inputBuffers->globalInput.data(),
  inputBuffers->metaInput.data(),
  aneMaskBuf.data(),
  ...);
```

The accompanying comment justifies this only for `requireExactNNLen=true`,
where the converter is invoked with `optimize_identity_mask=true` and the
generated mlpackage ignores the `input_mask` tensor:

> When `optimizeIdentityMask=true` was passed during CoreML conversion (i.e.,
> `requireExactNNLen=true`), the Swift side bakes the identity mask into the
> mlpackage and ignores this buffer; providing it is still required by the
> Swift ABI.

When `requireExactNNLen=false` (the only configuration that supports a board
smaller than the NN frame, or a non-square board within a square frame, etc.),
the mlpackage is converted with `optimize_identity_mask=false` and **does**
consume `input_mask`. Feeding an all-ones buffer in this case silently produces
wrong policy, value, score, and ownership predictions for any position where
the true mask has zeros — i.e., wherever `nnXLen != boardXSize` or
`nnYLen != boardYSize`.

The GPU/MLX dispatch path is unaffected: it slices channel 0 of the NHWC
spatial input via `mx::slice` (`mlxbackend.cpp:1109, 1171`) and feeds the
sliced tensor directly to the compiled inference function. The unified Metal
backend (different project, `KataGo-CoreML`) is also unaffected: it gathers
the mask into a dedicated `userInputMaskBuffer` member of `InputBuffers`
after NCHW conversion (`metalbackend.cpp:794-795`).

## Goal

When dispatching to the ANE/CoreML path, always pass the true mask — extracted
from channel 0 of the NHWC `spatialInput` — so the result is correct for both
`requireExactNNLen=true` (mlpackage ignores the buffer; no-op) and
`requireExactNNLen=false` (mlpackage consumes it correctly).

Replace the per-call `std::vector` allocation with a persistent member of
`InputBuffers`, mirroring the Metal backend's structure.

## Non-Goals

- No change to the GPU/MLX dispatch path.
- No change to the Swift `CoreMLComputeHandle.apply` ABI.
- No change to the `katagocoreml` converter library or its
  `optimize_identity_mask` option semantics.
- No change to the Metal backend (separate project).
- No new converter tests (the converter already produces correct mlpackages
  for both `optimize_identity_mask` values; the bug is purely in how the MLX
  backend fed the resulting model).

## Data Flow

Spatial input layout in this backend is **NHWC** — enforced at
`mlxbackend.cpp:1685-1686`:

```cpp
if(!inputsUseNHWC)
  throw StringError("MLX backend: inputsUseNHWC = false unsupported");
```

So `inputBuffers->spatialInput` is laid out as
`[batchSize, nnYLen, nnXLen, numInputChannels]`, and the mask is channel 0.

### Before

Per-batch row inside the `for(nIdx ...)` loop
(`mlxbackend.cpp:1723-1745`):

1. Copy global/meta features.
2. `SymmetryHelpers::copyInputsWithSymmetry` writes the row's spatial features
   into `inputBuffers->spatialInput`.

Then, in the ANE branch (`mlxbackend.cpp:1748-1768`):

3. Allocate `std::vector<float> aneMaskBuf(batchSize * nnXLen * nnYLen, 1.0f)`.
4. Pass `aneMaskBuf.data()` to `coremlOnlyHandle.apply`.

### After

Per-batch row inside the same loop:

1. (unchanged) Copy global/meta features.
2. (unchanged) `copyInputsWithSymmetry`.
3. **New**: gather channel 0 of the just-written row from `spatialInput[nIdx]`
   into `inputBuffers->userInputMaskBuffer[nIdx]`, using stride
   `numInputChannels`. Layout of the resulting buffer is
   `[batchSize, nnYLen, nnXLen]` contiguous.

Then, in the ANE branch:

4. Pass `inputBuffers->userInputMaskBuffer.data()` to `coremlOnlyHandle.apply`.
   No transient allocation.

## Components Touched

### `struct InputBuffers` (`mlxbackend.cpp:1464-1525`)

Add:

- `std::vector<float> userInputMaskBuffer;` member.
- `size_t singleMaskElts;` member (for readability and to avoid recomputing
  `nnXLen * nnYLen` at call sites).
- In the constructor: `singleMaskElts = nnXLen * nnYLen;` and
  `userInputMaskBuffer.resize(singleMaskElts * maxBatchSize);`. The vector is
  default-zero-initialized; that's fine because every batch row is fully
  rewritten by the gather before being read.

### `NeuralNet::getOutput` (`mlxbackend.cpp:1700-1790`)

Inside the existing `for(int nIdx = 0; nIdx < batchSize; nIdx++)` loop, after
`copyInputsWithSymmetry`:

```cpp
// Extract mask (channel 0) from NHWC spatial input into the dedicated
// contiguous mask buffer required by the Swift CoreMLComputeHandle ABI.
// Cheap (one gather over numInputChannels stride; dwarfed by the forward
// pass). When the mlpackage was converted with optimize_identity_mask=true
// (i.e., requireExactNNLen=true) it ignores this buffer, but populating it
// unconditionally avoids a silent-misprediction footgun when the converter
// was invoked with optimize_identity_mask=false.
const int numChannels = computeHandle->numInputChannels;
float* dstMask = inputBuffers->userInputMaskBuffer.data()
               + inputBuffers->singleMaskElts * nIdx;
const float* srcSpatial = rowSpatialInput;  // already NHWC, channel 0 first
for(int i = 0; i < (int)inputBuffers->singleMaskElts; i++) {
  dstMask[i] = srcSpatial[i * numChannels];
}
```

In the ANE branch, replace:

```cpp
std::vector<float> aneMaskBuf(batchSize * nnXLen * nnYLen, 1.0f);
computeHandle->coremlOnlyHandle.get().apply(
  ...,
  aneMaskBuf.data(),
  ...);
```

with:

```cpp
computeHandle->coremlOnlyHandle.get().apply(
  ...,
  inputBuffers->userInputMaskBuffer.data(),
  ...);
```

Update the surrounding comment to reflect the new invariant ("mask is always
the real per-row mask extracted from channel 0; the mlpackage ignores it iff
it was converted with `optimize_identity_mask=true`").

## Error Handling & Invariants

- **NHWC layout** is already enforced at handle creation; the gather assumes
  it. No new check needed.
- **Buffer capacity**: `userInputMaskBuffer` is sized for `maxBatchSize`; the
  precondition `batchSize <= maxBatchSize` is already asserted in `getOutput`.
- **Thread safety**: `InputBuffers` is per-eval-thread (same pattern as every
  other backend); no locking needed.
- **Channel-0 == mask**: a KataGo input-encoding invariant
  (`NNInputs::fillRowV7` etc. write the validity mask into channel 0). Stable
  across all model versions targeted by this backend.

## Testing

The MLX backend recognizes the same gpuIdx convention as Metal:
`deviceToUseThread0=0` selects `MLX_MUX_GPU`, `deviceToUseThread0=100`
selects `MLX_MUX_ANE` (`mlxbackend.cpp:56-57`). The existing
`cpp/rungpuerrortest.sh` already drives many `requireMaxBoardSize=False`
configurations on multiple board sizes (9, 13, 19, 10x14, "rectangle"),
which is exactly the surface this bug breaks.

### Pre-fix repro

Build MLX backend and run the existing script in ANE mode against a
non-19×19 case with `requireMaxBoardSize=False`. Lines 55-56 of the script
already cover this:

```
./katago testgpuerror -model "$MODEL2" -config configs/gtp_example.cfg \
    -boardsize 13 \
    -override-config "requireMaxBoardSize=False, deviceToUseThread0=100"
```

Before the fix this should show large winrate/score/ownership drift on the
13×13 board versus the Eigen reference; after the fix, drift should fall
back into the same band as the MLX GPU path on the same model.

### Post-fix manual validation

1. Rebuild: `cd cpp && cmake -G Ninja -DUSE_BACKEND=MLX && ninja`.
2. Run the full sweep in both modes: invoke `rungpuerrortest.sh` adapted
   for MLX (replace `metalDeviceToUseThread0=100` with
   `deviceToUseThread0=100`, since MLX uses the generic key). Compare ANE
   results against the existing references under
   `cpp/tests/results/gpu_error_reference_files/` produced by the Eigen
   build.
3. Run `./katago benchmark` on the ANE path to confirm no perceptible
   throughput regression (the channel-0 gather is O(B·H·W), bounded by
   `maxBatchSize * nnYLen * nnXLen` per call — dwarfed by the forward
   pass).
4. Update `.claude/MLX_Validation.md` with the new numbers and date, per
   the "When to re-run" checklist in `CLAUDE.md`.

### Automated regression

Adapt `cpp/rungpuerrortest.sh` so the MLX backend can drive it the same
way the Metal backend does today — the cleanest hook is changing the
`ane`-mode `EXTRA_OVERRIDE` to use `deviceToUseThread0=100` instead of
`metalDeviceToUseThread0=100` (the generic key works for both backends).
This folds MLX-ANE coverage into the existing cross-backend sweep without
a parallel script. No changes needed to `mlxtests.cpp` — the bug is in
the production dispatch path, not in any unit-level layer.

## Rollout

Single commit on the current branch (`mlx-backend-squash`). No config flags,
no deprecation, no migration. The only behavioral change is "ANE results are
now correct in the `requireExactNNLen=false` configuration."

## Open Questions

None.
