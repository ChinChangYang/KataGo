# MLX Backend ANE/CoreML NHWC → NCHW Conversion Fix — Design

**Date:** 2026-05-24
**Branch:** mlx-backend-squash
**Scope:** `cpp/neuralnet/mlxbackend.cpp` only

## Problem

`NeuralNet::getOutput` in the MLX backend keeps `spatialInput` in **NHWC**
layout — required by the MLX/GPU dispatch path, which constructs an `mx::array`
with explicit `{batchSize, nnYLen, nnXLen, numInputChannels}` shape at
`mlxbackend.cpp:1101` and `mlxbackend.cpp:1163`. NHWC is also enforced at
handle creation (`mlxbackend.cpp:1689-1690`), so this is a hard invariant for
the GPU path.

The Swift `CoreMLComputeHandle.apply()` on the ANE dispatch path, however,
allocates each batch row as

```swift
let spatialArray = try MLMultiArray(
    shape: [1, numInputChannels, nnYLen, nnXLen],
    dataType: .float32)
memcpy(spatialPtr, spatialInput.advanced(by: batchIndex * spatialSize),
       spatialSize * MemoryLayout<Float32>.size)
```

(see `cpp/neuralnet/metalbackend.swift:143-154` in the sibling KataGo-CoreML
repo, which produces the `KataGoSwift` binary this backend links). The default
`MLMultiArray` strides for shape `[1, C, H, W]` are NCHW, and the call is a
raw `memcpy` of `C*H*W` floats per row.

Today the MLX backend passes `inputBuffers->spatialInput.data()` (NHWC bytes)
into a buffer the Swift side interprets as NCHW. Every channel gets aliased to
the wrong position in the tensor. Symptom observed during the mask-fix
validation sweep on 2026-05-24: 50–99% winrate error on **every** ANE
invocation, including `requireExactNNLen=true` configurations where the mask
fix should be a no-op. The mask fix (`375a520c`) is independently correct but
masked behind this layout bug, which dominates the error.

The Metal backend (separate project) does not have this problem — its
`MetalProcess::processRowData` runs `convertNCHW` after
`copyInputsWithSymmetry`, so its `userInputBuffer` is already NCHW for both
the Metal/GPU path and the ANE path (`metalbackend.cpp:785-790,794-795`).

## Goal

On the ANE dispatch path, hand the Swift ABI an NCHW-layout spatial buffer.
Keep `spatialInput` NHWC for the MLX/GPU path. The two layouts are isolated in
separate buffers within `InputBuffers`; the dispatch branch picks the right
one.

The post-mask-fix per-row strided gather into `userInputMaskBuffer` collapses
to a contiguous `memcpy` after this change, because channel 0 (the validity
mask) lives at the start of each NCHW row.

## Non-Goals

- No change to the MLX/GPU dispatch path.
- No change to the Swift `CoreMLComputeHandle.apply` ABI.
- No change to the `katagocoreml` converter library.
- No change to the Metal backend or `metalbackend.cpp`'s shared `convertNCHW`
  helper (different project; sibling reference only).
- No change to `nninterface.h` / `NeuralNet::createInputBuffers` ABI
  (a cross-backend interface; would be widening the surface to fix a
  single-backend bug).

## Data Flow

### Buffer layout after this change

| Buffer | Layout | Populated by | Read by |
|---|---|---|---|
| `spatialInput` | NHWC `[B, H, W, C]` | `copyInputsWithSymmetry` (unchanged) | MLX/GPU path only |
| `userInputBufferNCHW` | NCHW `[B, C, H, W]` | per-row transpose, ANE branch only | Swift `apply()` |
| `userInputMaskBuffer` | packed `[B, H, W]` | `memcpy` of NCHW row's first `H*W` floats, ANE branch only | Swift `apply()` |

### Per-row data flow — ANE path

```
inputBufs[nIdx]->rowSpatialBuf
        |
        v   copyInputsWithSymmetry
spatialInput[nIdx]  (NHWC)
        |
        v   strided transpose (HW outer, C inner)
userInputBufferNCHW[nIdx]  (NCHW)
        |
        v   memcpy first HW floats
userInputMaskBuffer[nIdx]
```

### Per-row data flow — MLX/GPU path (unchanged)

```
inputBufs[nIdx]->rowSpatialBuf
        |
        v   copyInputsWithSymmetry
spatialInput[nIdx]  (NHWC)
        |
        v   mx::array(..., {B,H,W,C}) + mx::slice
MLX kernels
```

## Components Touched

All changes are in `cpp/neuralnet/mlxbackend.cpp`. No header or ABI changes.

### `struct InputBuffers` (`mlxbackend.cpp:1464-1529`)

Add member next to the existing `userInputMaskBuffer`:

```cpp
std::vector<float> userInputBufferNCHW;
```

In the constructor, after the existing `spatialInput.resize(...)`:

```cpp
userInputBufferNCHW.resize(singleInputElts * maxBatchSize);
```

Default-zero-initialized. Every row is fully overwritten on the ANE path
before being read, so leftover zeros are never observed. Cost: ~1 MB/thread
typical (b18c384nbt @ maxBatch=32, C=22, 19×19); ~4 MB/thread at maxBatch=128.
GPU threads allocate but never touch it — deliberate trade-off to keep the
constructor signature unchanged (the cross-backend `createInputBuffers` ABI
does not see the compute handle's mux mode).

### `NeuralNet::getOutput` (`mlxbackend.cpp:1704-1810`)

Inside the existing `for(int nIdx = 0; nIdx < batchSize; nIdx++)` loop,
**replace** the current mask-extraction block at `mlxbackend.cpp:1750-1768`
with a path-aware block:

```cpp
if(computeHandle->coremlOnlyHandle) {
  // ANE path: transpose this row NHWC -> NCHW into the dedicated staging
  // buffer that Swift CoreMLComputeHandle.apply consumes (it allocates
  // MLMultiArray with shape [1, C, H, W] and raw memcpys the row), and
  // lift the validity mask (channel 0) as one contiguous H*W copy from
  // the start of the converted row.
  //
  // The MLX/GPU path never touches userInputBufferNCHW.
  const int C = computeHandle->numInputChannels;
  const size_t HW = inputBuffers->singleMaskElts;          // nnXLen * nnYLen
  float* rowNCHW = inputBuffers->userInputBufferNCHW.data()
                 + inputBuffers->singleInputElts * nIdx;
  const float* rowNHWC = rowSpatialInput;                  // [H*W, C]
  for(int c = 0; c < C; c++) {
    float* dstCh = rowNCHW + (size_t)c * HW;
    for(size_t hw = 0; hw < HW; hw++) {
      dstCh[hw] = rowNHWC[hw * C + c];
    }
  }
  float* dstMask = inputBuffers->userInputMaskBuffer.data()
                 + inputBuffers->singleMaskElts * nIdx;
  std::memcpy(dstMask, rowNCHW, HW * sizeof(float));
}
```

The previous unconditional strided mask gather is gone. The MLX/GPU path
reads channel 0 directly via `mx::slice(input, {0,0,0,0}, {B,H,W,1})`
(`mlxbackend.cpp:1107-1109, 1169-1171`) and never reads
`userInputMaskBuffer`, so dropping the GPU-side gather is safe and removes
dead work from that hot path.

In the ANE dispatch (`mlxbackend.cpp:1772-1787`), swap the spatial pointer:

```cpp
computeHandle->coremlOnlyHandle.get().apply(
  inputBuffers->userInputBufferNCHW.data(),   // was: inputBuffers->spatialInput.data()
  inputBuffers->globalInput.data(),
  inputBuffers->metaInput.data(),
  inputBuffers->userInputMaskBuffer.data(),
  inputBuffers->policyResults.data(),
  inputBuffers->policyPassResults.data(),
  inputBuffers->valueResults.data(),
  inputBuffers->scoreValueResults.data(),
  inputBuffers->ownershipResults.data(),
  batchSize);
```

Update the surrounding comment block (the one that today references
`metalbackend.cpp:1007`) to state the new invariant:
"`spatialInput` is always NHWC for the MLX/GPU path;
`userInputBufferNCHW` is the row-transposed view that Swift's NCHW ABI
consumes."

## Error Handling & Invariants

- **NHWC layout** is enforced at handle creation (`mlxbackend.cpp:1689-1690`).
  The transpose assumes it; no new check needed.
- **`singleInputElts == C * H * W`** is already asserted at
  `mlxbackend.cpp:1722`. `userInputBufferNCHW` reuses this size constant so
  the sizing is automatically right.
- **`batchSize <= maxBatchSize`** is asserted at `mlxbackend.cpp:1711`.
  Sizing for `maxBatchSize` makes all NCHW writes in-bounds.
- **Channel-0 == mask** is a KataGo input-encoding invariant (`NNInputs::fillRowV7`
  etc. write the validity mask into channel 0). Stable across every model
  version this backend targets. Already relied on by the mask fix in
  `375a520c`.
- **Thread safety**: `InputBuffers` is per-eval-thread (same pattern as every
  other backend); no locking needed.

## Performance

Transpose cost per row: `C*H*W` strided reads + `C*H*W` linear writes. For
b18c384nbt at 19×19 with C≈22, that's ~8k floats each way per row — dwarfed
by the ANE forward pass. No FLOPs, just memory traffic, and bounded by
`maxBatchSize * singleInputElts` per `getOutput` call. The benchmark step
in the testing plan confirms there's no perceptible regression.

## Testing

### Pre-fix repro (must fail before, pass after)

The cross-backend `rungpuerrortest.sh` script in `cpp/` drives `testgpuerror`
against the Eigen references already on disk under
`cpp/tests/results/gpu_error_reference_files/` (naming pattern
`<model-basename>_size<board>.txt`). For an isolated quick repro, the
b18c384nbt v11 model with its 19×19 reference is the smallest
self-contained invocation:

```bash
cd cpp && cmake -G Ninja -DUSE_BACKEND=MLX && ninja
./katago testgpuerror \
  -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize 19 \
  -override-config "requireMaxBoardSize=True, deviceToUseThread0=100" \
  -reference-file tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt
```

Pre-fix: max winrate error in tens of percent (the layout bug dominates,
observed 50–99% during the mask-fix sweep on 2026-05-24).
Post-fix: should fall into the same band as the MLX/GPU path against the
same reference (≪ 0.1% FP32; standard half-precision tolerance if the
converter emitted a half-precision mlpackage).

### Post-fix validation

1. **Rebuild**: `cd cpp && cmake -G Ninja -DUSE_BACKEND=MLX && ninja`.
2. **Targeted spot-check**: run two configurations explicitly —
   `requireExactNNLen=true` (mlpackage has `optimize_identity_mask=true`;
   the mask buffer is ignored, so this proves the layout fix in isolation)
   and `requireExactNNLen=false` with a 13×13 board (proves layout fix
   composes correctly with the mask fix).
3. **Full sweep**: `./rungpuerrortest.sh ane` (already wired backend-agnostic
   in commit `40b75328`). All 30 invocations should pass the same
   thresholds the MLX/GPU sweep passes against the same Eigen references
   under `cpp/tests/results/gpu_error_reference_files/`.
4. **Throughput sanity**:
   `./katago benchmark -model <model>.bin.gz -override-config "deviceToUseThread0=100" -half-batch-size`.
   Confirm the per-row transpose adds no perceptible overhead.
5. **Snapshot update**: refresh `.claude/MLX_Validation.md` with the new
   ANE accuracy + throughput numbers per the "When to re-run" checklist
   in `CLAUDE.md`. Do not commit (file is untracked by design).

### No new unit tests

The bug lives in the production dispatch path, not in any layer-level
kernel. `mlxtests.cpp` (which exercises individual MLX layer ops, not the
Swift dispatch) wouldn't have caught it and won't usefully cover the fix.
The cross-backend `testgpuerror` sweep is the right level of coverage —
it's exactly the surface the bug breaks.

## Rollout

Single commit on `mlx-backend-squash`, sequenced after the mask fix
(`375a520c`) and the `rungpuerrortest.sh` tweak (`40b75328`) already on
the branch. No config flag, no migration, no deprecation. The only
behavioral change is "ANE results are now correct for both
`requireExactNNLen` settings on the MLX backend."

## Open Questions

None.
