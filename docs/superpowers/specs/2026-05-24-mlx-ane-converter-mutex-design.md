# MLX ANE Converter Mutex — Design

**Status:** Approved 2026-05-24.

**Branch:** `mlx-backend-squash`.

## Problem

The MLX backend allows per-thread mux dispatch between MLX/GPU (`gpuIdx
= 0`) and CoreML/ANE (`gpuIdx = 100`), but a mux config with **two or
more ANE threads** crashes at startup:

```
libc++abi: terminating due to uncaught exception of type std::runtime_error:
MLX backend 3: Core ML model conversion failed:
[MIL StorageWriter]: Metadata written to different offset than expected.
```

Reproduction (confirmed 2026-05-24, HEAD `64304cdb`):

```bash
cd cpp
./katago testgpuerror \
  -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize 19 \
  -override-config "requireMaxBoardSize=True, numNNServerThreadsPerModel=4, \
    deviceToUseThread0=0, deviceToUseThread1=0, \
    deviceToUseThread2=100, deviceToUseThread3=100, mlxUseFP16=true" \
  -reference-file tests/results/gpu_error_reference_files/\
kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt
```

### Root cause

Each ANE server thread calls
`NeuralNet::createComputeHandle` → `ComputeHandle` ctor →
`createCoreMLOnlyHandleIfNeededMLX` →
`convertAndCreateCoreMLOnlyHandleMLX` →
`CoreMLConversion::convertModelToTemp` →
`katagocoreml::KataGoConverter::convert` (`cpp/neuralnet/mlxbackend.cpp:120`).
The `katagocoreml` converter embeds the coremltools MIL writer, which
holds process-global writer state and is not reentrant — two threads
entering concurrently corrupt the `.mlpackage` storage offsets and
throw.

There is no mutex around this call. The MLX backend does have other
mutexes (`cachedModelsMutex` line 1253, `compiledFuncsMutex` line 1300)
but they protect runtime caches, not handle construction.

### Prior art

The Metal backend faces the exact same race because its ANE mux path
calls the same `katagocoreml::KataGoConverter::convert`. Metal solves
it with a file-static mutex held during the entire `ComputeHandle`
construction:

```cpp
// cpp/neuralnet/metalbackend.cpp:442
static mutex computeHandleMutex;

// cpp/neuralnet/metalbackend.cpp:586-591
ComputeHandle* handle = nullptr;
{
  lock_guard<mutex> lock(computeHandleMutex);
  handle = new ComputeHandle(context, loadedModel, inputsUseNHWC,
                              gpuIdx, serverThreadIdx,
                              requireExactNNLen, maxBatchSize);
}
return handle;
```

Metal explicitly does **not** cache the converted `.mlpackage` —
each ANE thread converts independently; the mutex just serializes the
converter call. The handle construction is once-per-server-thread at
process startup, so serializing it is operationally free.

## Goal

The 2×GPU + 2×ANE FP16 mux config documented in commits `64304cdb`
(MLX example block in `gtp_example.cfg` / `analysis_example.cfg` /
`match_example.cfg` / `contribute_example.cfg`) becomes functional.

Cross-backend accuracy on the canonical b18c384 19×19 case stays in
family with the existing single-ANE baseline
(max FP16 winrate error ≤ ~1% vs Eigen reference;
the 2026-05-24 single-ANE snapshot recorded 0.545%).

## Non-Goals

- **Convert-once cache.** Avoiding the duplicate conversion when
  multiple ANE threads exist would require sharing the `.mlpackage` (or
  its compiled artifact) across threads, plus reasoning about temp-file
  lifetime and concurrent `MLModel.load` semantics. Out of scope for
  this fix; the cost is paid once at startup.
- **Removing the converter from the runtime dependency chain.** Pre-
  converting `.mlpackage` files as part of the build/install would
  eliminate the race by removing the problem, but is a different
  project (touches Python tooling, packaging, model distribution).
- **Per-thread CoreML compute units.** Tuning whether each ANE thread
  prefers ANE-only vs CPU+ANE engine selection. Existing Swift
  `CoreMLComputeHandle` behavior is preserved.
- **GPU-side parallelism.** The MLX/GPU path is not blocked by this
  race; this fix incidentally serializes its setup too (same as Metal),
  but that's at startup only.

## Design

### Components touched

| File | Change |
|---|---|
| `cpp/neuralnet/mlxbackend.cpp` | Add file-static `std::mutex computeHandleMutex;`. Wrap `new ComputeHandle(...)` in `NeuralNet::createComputeHandle` with `std::lock_guard<std::mutex>` on that mutex. |

Diff scope is approximately 5 lines.

### Mutex placement

- **Scope:** file-static at the top of `cpp/neuralnet/mlxbackend.cpp`
  near other file-statics (e.g., the `MLX_MUX_GPU` / `MLX_MUX_ANE`
  constants at lines 56–57). Mirrors `metalbackend.cpp:442`.
- **Lock duration:** held only during the `new ComputeHandle(...)`
  call at the end of `NeuralNet::createComputeHandle`. Releases via
  RAII (`lock_guard`) on normal return or exception unwind.
- **Why not narrower (converter-only):** locking the whole ctor adds
  zero practical cost (called once per server thread at process
  startup) and also serializes any other not-yet-known shared setup
  state inside the ctor — including the MLX Winograd tuner, which
  currently logs concurrently from multiple threads
  (`MLX tuner conv3x3 distribution: ...` appearing twice in the
  pre-fix log).
- **Why not member of `ComputeContext`:** `ComputeContext` already
  carries per-instance mutexes for runtime caches; adding a setup
  mutex there would deviate from Metal. File-static keeps the diff
  identical to the prior-art pattern.

### Header

`<mutex>` is already included at `cpp/neuralnet/mlxbackend.cpp:32`. No
new include needed.

## Error Handling

`lock_guard` releases on exception unwind, so the existing throw paths
inside `ComputeHandle` construction (e.g., the converter's own throw at
`mlxbackend.cpp:128`, or the gpuIdx validation throw at line 1683) are
unchanged. Other threads waiting on the mutex acquire it after the
exception is unwound, so a failed conversion on one thread does **not**
deadlock the others; each will get its own (possibly also failing)
attempt.

## Performance

- **Inference path:** unaffected. Mutex is not held during forward
  passes.
- **Startup:** ANE thread setup goes from "parallel and broken" to
  "serial and working." On the b18c384 19×19 case the CoreML
  conversion takes a few seconds; for 2 ANE threads that's ~2× the
  single-ANE startup time, paid once per process.
- **GPU-only configs:** unaffected in steady state; setup is also
  serialized, but a 1-thread GPU-only config has nothing to serialize.

## Testing

1. **Negative repro (must pass).** Re-run the `testgpuerror` command
   from the Problem section. Expectation: completes without throwing,
   produces error metrics for both FP32 and FP16 vs the Eigen
   reference.
2. **Accuracy.** Confirm 2+2 mux FP16 max winrate error vs Eigen
   reference is within the same band as the single-ANE 2026-05-24
   baseline (0.545% on this case). Tolerance: ≤ 1.0% max winrate
   error.
3. **Regression — unit tests.** `./katago runtests` and
   `./katago runnnlayertests` should produce the same pass set as
   before the change.
4. **Regression — single-thread default.** A no-override
   `testgpuerror` run (single GPU thread, the default) should produce
   identical numbers to pre-fix (mutex is uncontended).
5. **Optional smoke.** A short `./katago analysis` run with the 2+2
   mux config to confirm steady-state operation (no deadlock, both
   GPU and ANE handles dispatching).

Result files land under `cpp/tests/results/gpu_error_results/` with
suffixed names so they can coexist with the prior runs:

- `..._size19_mux2g2a.txt` — the 2+2 post-fix run
- `..._size19_mux1g1a.txt` — the 1+1 control already on disk

## Rollout

- Single commit on `mlx-backend-squash` branch.
- No config changes — the mux 2×GPU + 2×ANE example block already
  shipped in commit `64304cdb` becomes functional.
- No `.claude/MLX_Validation.md` update is strictly required by this
  spec, but the validation snapshot should be refreshed after testing
  to record post-fix 2+2 numbers alongside the existing 1×ANE entry.

## Future Work (out of scope)

- **Convert-once cache** — see Non-Goals. Would help when N_ANE > 2 or
  when process startup latency starts to matter.
- **Mutex scope narrowing** — if the MLX Winograd tuner is later
  confirmed reentrant, the lock could be moved to just the converter
  call. Not worth the risk now; profile first.
- **Lift the converter race upstream** — file an issue with
  coremltools / `katagocoreml` so other consumers don't have to
  serialize externally.
