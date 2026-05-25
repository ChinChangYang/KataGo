# MLX Per-Thread Default Stream — Design

**Status:** SUPERSEDED 2026-05-25 by
`2026-05-25-mlx-fp16-weight-materialization-design.md`. The hypothesis
below — that MLX 0.31.2's `default_stream()` throws on unregistered
threads — was wrong. `default_stream()` lazy-creates per thread (see
`mlx/stream.cpp:40-50`); the throw site is
`metal::get_command_encoder` failing to find an encoder for a stream
that was created on a *different* thread. The shared `cachedModels`
hands a Model constructed on thread A to thread B, and any unevaluated
fp16 weight `AsType` primitives on that Model carry thread A's stream.
Eager-eval'ing fp16 weights at construction is the fix. The
implementation following this spec (commit `3b760af2`) was reverted in
`fb0fcb89` and did not address the actual bug.

**Status (historical):** Approved 2026-05-25.

**Branch:** `mlx-backend-squash`.

## Problem

After the converter-mutex fix (commit `acbd0f04`), the 2×GPU + 2×ANE FP16
mux config documented in the example configs no longer crashes during
`ComputeHandle` construction. It now crashes on the **first FP16 forward
pass** through the MLX/GPU path:

```
libc++abi: terminating due to uncaught exception of type std::runtime_error:
There is no Stream(gpu, 0) in current thread.
```

Reproduction (confirmed 2026-05-25, HEAD `acbd0f04`):

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

Captured raw log:
`cpp/tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_mux2g2a.txt`.
FP32 single + batched evals complete; the next phase ("Running
evaluations using current config", i.e. FP16) throws on the first call.

### Root cause

MLX 0.31.2 introduced thread-local default streams
(`stream.h:28-32`). `mx::default_stream(Device)` now throws
`std::runtime_error("There is no Stream(<device>, <i>) in current
thread.")` if the calling thread never registered a default stream for
that device. Op call sites in MLX look up the default stream when no
explicit stream is provided.

`mlxbackend.cpp` never calls `mx::new_stream`,
`mx::set_default_stream`, or `mx::new_thread_local_stream` — every MLX
op uses the implicit thread-local default. KataGo's NNEvaluator
spawns real `std::thread` server threads in `nneval.cpp:393`. Each
server thread runs both `createComputeHandle` (`nneval.cpp:437`) and
the `getOutput` loop (`nneval.cpp:570`); both invoke MLX ops on a
thread that has no default stream registered for it.

A single-thread evaluator works because the one thread that does
MLX work happens to have a stream (likely installed during MLX global
init on whichever thread imported it). Mux configs with ≥2 GPU server
threads expose the gap on every secondary thread.

### Prior art

The Metal backend binds an `id<MTLCommandQueue>` per server thread
inside `ComputeHandle`; every op submission targets that queue
explicitly. CUDA/OpenCL backends similarly bind a context per thread.
MLX has been getting away with implicit thread-local defaults that
only worked for the main thread; the 0.31.2 change made the gap
fatal.

## Goal

The 2×GPU + 2×ANE FP16 mux config (and any other config with ≥2 MLX/GPU
server threads) executes forward passes to completion. Cross-backend
accuracy on the canonical b18c384 19×19 case stays in family with the
existing single-MLX/GPU FP16 baseline (max winrate error ≤ ~3% vs
Eigen reference; `.claude/MLX_Validation.md` records 2.63% from the
2026-05-23 sweep).

Each MLX/GPU server thread owns its own MLX `Stream` so that the
MLX scheduler's per-stream `StreamThread` worker (`scheduler.h:19-65`)
gives true CPU-side dispatch overlap between server threads. This is
what enables the 2×GPU+2×ANE mux to outperform the 1×GPU+1×ANE
baseline in nnEvals/s.

## Non-Goals

- **Explicit `Stream` parameters at every MLX op call site.** Equivalent
  scheduling, much larger diff (every op site changes), no throughput
  benefit. The thread-local default already routes ops to the
  per-thread stream.
- **Single-MLX-worker restructuring.** Funneling all MLX work through
  one dedicated thread would eliminate the per-thread stream question
  entirely but kill the CPU-dispatch overlap that mux mode exists to
  exploit. Throughput regression.
- **Cleanup of per-thread streams on server thread destruction.**
  Server threads in the typical engine processes (gtp, analysis,
  benchmark) live for the entire process lifetime; cleanup happens at
  Scheduler destruction. Documented as known-acceptable leak for
  test workloads that create and destroy many NNEvaluators.
- **Tuning the optimal mux ratio.** Whether 2×GPU+2×ANE outperforms
  3×ANE, 2×GPU+1×ANE, etc. is a measurement question for a separate
  benchmark pass.

## Design

### Components touched

| File | Change |
|---|---|
| `cpp/neuralnet/mlxbackend.cpp` | Add file-static `ensureMLXDefaultStreamForCurrentThread()` helper using `thread_local bool` latch. Call from the GPU branches of `NeuralNet::createComputeHandle` and `NeuralNet::getOutput`. |

Diff scope is approximately 15 lines.

### The helper

```cpp
// Register a per-thread default MLX stream on first call from a given thread.
// MLX 0.31.2's mx::default_stream(Device) is thread-local and throws if the
// calling thread never registered one — which is what happens to NNEvaluator's
// std::thread server threads. Without this, the first GPU forward pass on a
// server thread throws "There is no Stream(gpu, 0) in current thread."
// Giving each server thread its own Stream also enables CPU-side dispatch
// overlap between threads (each Stream owns its own StreamThread worker).
static void ensureMLXDefaultStreamForCurrentThread() {
  thread_local bool initialized = false;
  if(!initialized) {
    mx::set_default_stream(mx::new_stream(mx::default_device()));
    initialized = true;
  }
}
```

Placement: near the file-static `MLX_MUX_GPU` / `MLX_MUX_ANE` constants
at `mlxbackend.cpp:56-57`, alongside the converter mutex added in
commit `acbd0f04`.

### Call sites

Both gated on `gpuIdx == MLX_MUX_GPU` so ANE threads don't spin up
unused MLX streams:

1. **`NeuralNet::createComputeHandle`** — *before* acquiring the
   converter mutex `lock_guard`, so the ctor's MLX model construction
   and Winograd tuner invocations have a default stream available and
   the mutex's critical section stays minimal (the mutex is only for
   the CoreML converter race). Stream registration is per-thread and
   needs no serialization.

2. **`NeuralNet::getOutput`** — at the top of the GPU branch
   (the `else` arm at `mlxbackend.cpp:1822-1823`), before
   `applyCompiled`. Redundant safety; cheap after first call (one
   thread_local bool read).

The redundancy is intentional and ~free: if any future refactor
moves the first MLX op off the ctor path, `getOutput` is still
covered.

### Why `thread_local bool` (not `std::call_once` or similar)

- `std::call_once` is for once-per-program initialization; we need
  once-per-thread.
- The `thread_local` storage class plus a bool guard is the minimal
  per-thread idempotence latch. The variable's destructor runs at
  thread exit; the bool itself carries no resources.
- An alternative form using `thread_local const bool done = []{...}();`
  is equivalent (the lambda runs exactly once per thread on first
  entry by the C++ standard) but less obvious to readers. Sticking
  with the explicit `if` form.

### Header

`<mutex>` is already included (`mlxbackend.cpp:32`). MLX's
`<mlx/stream.h>` is included transitively via `<mlx/mlx.h>`. No new
includes needed.

## Error Handling

`mx::new_stream(mx::default_device())` is not documented to throw for
the default device on Apple Silicon (`stream.h:35`). If it ever did,
the exception unwinds out of the helper with `initialized` still
`false`, so the next call retries. No partial state.

ANE-path call into `katagocoreml::KataGoConverter::convert` and into
Swift `CoreMLComputeHandle.apply()` does not touch MLX op signatures
and does not consult any MLX default stream. ANE threads remain
unaffected by this change.

## Performance

The whole point of this fix (beyond correctness) is throughput:

- **Per-stream CPU-side dispatch.** Each MLX `Stream` owns a
  `StreamThread` (`scheduler.h:19-65`) — a background `std::thread`
  that dequeues op submissions. With one Stream per server thread,
  two server threads' op submissions can run on two distinct
  StreamThread workers concurrently, instead of serializing on a
  shared default stream's single worker.
- **Per-stream Metal command queue.** Each Stream gets its own Metal
  command queue, enabling fine-grained driver-level interleaving of
  GPU work between server threads. With a shared default stream,
  the driver only sees one queue and must serialize submission
  order even when GPU compute units are idle.
- **ANE × GPU device parallelism.** Independent of streams; already
  works through the converter mutex fix in commit `acbd0f04`.
  This fix preserves it.

**Inference-path cost:** one `thread_local bool` read per call to
`getOutput` after the first call from a given thread. Effectively
free.

**Memory cost:** one MLX `Stream` + one `StreamThread` per MLX/GPU
server thread. For a 2-GPU-thread mux config, that's 2 additional
background threads. Apple's per-thread overhead is ~stack + minimal
kernel structures; immaterial relative to model weight memory.

## Testing

| # | Test | Pass criterion |
|---|---|---|
| 1 | Negative repro: rerun the failing 2×GPU+2×ANE FP16 `testgpuerror` command from the Problem section | Completes without throwing; produces FP16 winrate/score error metrics vs. the Eigen reference |
| 2 | Cross-backend accuracy | Max FP16 winrate error ≤ ~3% vs Eigen reference (matches the 2026-05-23 MLX/GPU FP16 baseline of 2.63%) |
| 3 | Regression — `./katago runtests` | Same pass set as pre-fix |
| 4 | Regression — `./katago runnnlayertests` (14 tests) | All pass, including `runMLXCoreMLSmokeTest` |
| 5 | Regression — single-thread default `testgpuerror` | Numbers in the same range as the post-converter-mutex baseline (max winrate err ~1%) |
| 6 | Throughput smoke — `./katago benchmark` with the 2×GPU+2×ANE config vs. 1×GPU+1×ANE on the b18c384 model | 2×GPU+2×ANE nnEvals/s > 1×GPU+1×ANE nnEvals/s (validates per-thread stream parallelism, not just "didn't crash") |

Test #6 is the throughput acceptance gate. If 2+2 does not beat 1+1,
the per-thread stream registration may not be reaching MLX correctly
(or this hardware is not throughput-bound by CPU dispatch overlap and
the user should be redirected to a single-thread config).

Result files land under `cpp/tests/results/gpu_error_results/` with
suffixed names so they coexist with prior runs:

- `..._size19_mux2g2a.txt` (overwrite; this run is the post-fix
  repro of the same scenario)
- `..._size19_mux1g1a.txt` (1+1 control, already on disk)

## Rollout

- Single commit on `mlx-backend-squash` branch.
- No config changes — the mux 2×GPU + 2×ANE example block already
  shipped in commit `64304cdb` becomes functional.
- `.claude/MLX_Validation.md` updated post-fix with the 2+2
  accuracy + throughput numbers alongside the existing 1+1 entry
  (per CLAUDE.md, this file stays untracked).

## Future Work (out of scope)

- **Benchmark mux ratios.** Quantify whether 2+2 beats 1+1, 3-ANE,
  2-GPU-only, etc. on this hardware.
- **Profile `StreamThread` overhead.** If the per-stream background
  threads become a bottleneck (unlikely at these thread counts),
  evaluate switching to `mx::new_thread_local_stream` (the
  MLX-blessed thread-local variant) and explicit `ThreadLocalStream`
  in op signatures.
- **Cleanup on server-thread exit.** Add a matching
  `mx::clear_streams()` if test workloads that churn NNEvaluators
  start to show meaningful Stream leaks.
