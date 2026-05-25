# MLX FP16 Weight Materialization — Design

**Status:** Implemented 2026-05-25.

**Branch:** `mlx-backend-squash`.

**Supersedes:** `2026-05-25-mlx-threadlocal-stream-design.md` (wrong
diagnosis; implementation reverted).

## Problem

The 2×GPU + 2×ANE FP16 mux config (per `numNNServerThreadsPerModel=4`
with `deviceToUseThread0/1=0`, `deviceToUseThread2/3=100`,
`mlxUseFP16=true`) crashes on the first MLX/GPU forward pass with:

```
libc++abi: terminating due to uncaught exception of type std::runtime_error:
There is no Stream(gpu, 0) in current thread.
```

The single-thread MLX/GPU FP16 baseline is unaffected. FP32 mux
configs are unaffected. Only multi-GPU-thread FP16 trips it.

Reproduction (HEAD `fb0fcb89` before fix; HEAD with fix completes):

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

MLX 0.31.2 moved per-stream `CommandEncoder` storage from a
process-wide `Device` member (0.30.x) to per-thread
`thread_local std::unordered_map<int, CommandEncoder>`
(`mlx/backend/metal/device.cpp:819-822`). `metal::get_command_encoder`
throws if the encoder for a given stream index is not in the calling
thread's map (`mlx/backend/metal/device.cpp:809-817`). Encoders are
registered only on the thread that called `mx::new_stream` /
`mx::default_stream` (`mlx/backend/metal/eval.cpp:14-19`).

The KataGo MLX backend shares one `Model` instance across all
MLX/GPU server threads in a given `NNEvaluator` via the
`ComputeContext::cachedModels` map (`cpp/neuralnet/mlxbackend.cpp:1416-1421`).
That sharing avoids ~150 MB of duplicate weights per server thread on
a b18c384 model but also means whichever thread wins the
`std::lock_guard` cache race constructs the layer weight arrays.

In FP16 mode, `Conv`, `MatMul`, and `MatBias` layer weights are
produced by `toComputeDtype(arr, true)` =
`mx::astype(arr, mx::float16)` (`cpp/neuralnet/mlxbackend.cpp:225`).
`mx::astype` returns an *unevaluated* MLX op array — its primitive is
stamped with the calling thread's default `Stream` at construction
time. The Winograd-weight helper in `cpp/neuralnet/mlxwinograd.h:135`
has the same pattern.

When a different MLX/GPU server thread later builds a compiled trace
that captures these weight arrays and calls `mx::eval`, MLX
evaluates the captured `AsType` primitives. Each primitive carries the
constructor thread's stream index. `metal::get_command_encoder` looks
that index up in the *current* thread's encoder map, finds nothing,
and throws "There is no Stream(gpu, N) in current thread." where N is
the constructor thread's stream index (0 in the observed failure
because the FP16 nneval was the first to spin up its threads).

FP32 mode never trips this because `toComputeDtype(arr, false)`
returns `arr` directly — leaf arrays carry no primitive and no
stream. The previous "per-thread default stream" fix
(commit `3b760af2`, reverted in `fb0fcb89`) added per-thread streams
but did nothing about the captured cross-thread primitives, so it
made no difference.

### Evidence

Instrumented trace on the failing repro
(`std::this_thread::get_id()` + `mx::default_stream(default_device()).index`
at every MLX entry point) showed:

```
FP16 nneval, thread 0 (defaultStreamIdx=0): getOutput.GPU.exit  OK
FP16 nneval, thread 1 (defaultStreamIdx=1): applyCompiled.THREW
  EXC=There is no Stream(gpu, 0) in current thread.
```

Thread 1 had its own valid stream (index 1) in its encoder map; the
throw refers to stream index **0**, which is thread 0's stream —
thread 0 was the one that constructed the shared FP16 Model and
stamped its `AsType` primitives with stream 0.

## Goal

The 2×GPU + 2×ANE FP16 mux config (and any config with ≥2 MLX/GPU
server threads on FP16) executes forward passes to completion with
cross-backend accuracy in family with the existing single-MLX/GPU
FP16 baseline (max winrate error ≤ ~3% vs the Eigen reference, per
the 2026-05-23 sweep entry of 2.63% in `.claude/MLX_Validation.md`).

## Non-Goals

- **Disable `cachedModels`**: works (each thread gets its own Model
  on its own stream) but costs ~150 MB per extra GPU thread on
  Apple Silicon unified memory.
- **Funnel all MLX work through one dedicated thread**: sidesteps the
  per-thread encoder issue entirely but kills the CPU-side dispatch
  overlap that motivates mux mode.
- **Per-thread default stream registration** (the previous spec): does
  not address the cross-thread captured-primitive bug at all.
- **Tuning mux ratios** or measuring whether 2+2 actually beats 1+1.

## Design

### Components touched

| File | Change |
|---|---|
| `cpp/neuralnet/mlxbackend.cpp` | Add `toComputeDtypeMaterialized` helper that calls `mx::eval` on the `AsType` result; use it at the three layer-weight construction sites (Conv, MatMul, MatBias). Keep `toComputeDtype` as the lazy form for the inference hot path. |
| `cpp/neuralnet/mlxwinograd.h` | Eagerly `mx::eval` the fp16 Winograd-weight `AsType` inside `makeWinogradWeights`. |

Diff scope ≈ 25 lines (helper + comment + four call-site swaps).

### The helper

```cpp
// Convert array to compute dtype and materialize the result.
//
// Use this for STATIC layer weights cached on a shared Model (the
// `cachedModels` map shares a single Model instance across all
// MLX/GPU server threads). Without the eval, fp16 weights are
// unevaluated AsType primitives stamped with the constructor thread's
// MLX Stream; any other thread that later evals a compiled graph that
// captures these weights throws "There is no Stream(gpu, N) in current
// thread." with N = the constructor thread's stream index. MLX
// 0.31.2's command encoders live in `thread_local` storage per
// `metal/device.cpp:819-822`, so a stream created on thread A is
// unreachable from thread B.
static mx::array toComputeDtypeMaterialized(const mx::array& arr, bool useFP16) {
  if(!useFP16) return arr;
  mx::array result = mx::astype(arr, mx::float16);
  mx::eval(result);
  return result;
}
```

The lazy `toComputeDtype` stays for the inference hot path
(`Model::applyArrays` lines 1061-1068 cast per-batch inputs to fp16
inside the compiled trace — eager-eval'ing would force a stream sync
per inference and kill throughput).

### Call sites switched to the materialized form

| Site | Was | Now |
|---|---|---|
| `ConvLayer` non-Winograd weights | `toComputeDtype(...)` | `toComputeDtypeMaterialized(...)` |
| `MatMulLayer::createWeights` | `toComputeDtype(arr, useFP16)` | `toComputeDtypeMaterialized(arr, useFP16)` |
| `MatBiasLayer::createBias` | `toComputeDtype(arr, useFP16)` | `toComputeDtypeMaterialized(arr, useFP16)` |
| `MLXWinograd::makeWinogradWeights` (fp16 branch) | bare `mx::astype` | `mx::astype` then `mx::eval` |

`BatchNormLayer::mergedScale` / `mergedBias` are constructed via
`createArray1D` from raw `std::vector<float>` data and stay fp32
regardless of `useFP16`, so they're leaf arrays already — no change
needed.

### Why "materialize the weight" is the right cut

Materializing turns the fp16 weight into a realized constant tensor.
Subsequent traces that capture it see realized data — the `AsType`
primitive is consumed during the constructor-thread `mx::eval` and is
no longer in the graph. Different threads can evaluate the captured
weight freely; nothing in the graph references the constructor
thread's stream.

The cost is paid once at Model construction: one `astype` + one
`mx::eval` per layer weight, on a single thread, under the existing
`cachedModelsMutex`. Cold-start latency goes up by roughly the time
to fp16-cast each layer weight. For a b18c384 model that's about
~140 MB of fp32 weights → ~70 MB of fp16 output. Single-threaded
fp16 cast on Apple Silicon clocks well under a second; immaterial
relative to the model load (`loadOrAutoTune` + tuning sweep) the
construction already does.

## Error Handling

`mx::eval(arr)` propagates exceptions from the constructor thread's
MLX runtime if the cast itself ever fails. There's no partial state:
the `mx::array result` local lives only on the stack; if eval
throws, the layer constructor unwinds normally and the cache slot
stays unpopulated.

## Performance

Inference path is unchanged. Each fp16 layer weight is materialized
once at Model construction (under the cache mutex); subsequent forward
passes see realized constants in the compiled trace. No extra stream
syncs, no per-batch cost. Throughput characteristics inherit
unchanged from the single-thread FP16 baseline; mux configs now
actually function instead of crashing.

## Testing

| # | Test | Pass criterion | Status |
|---|---|---|---|
| 1 | Repro: 2×GPU + 2×ANE FP16 `testgpuerror` (Problem section) | Completes; cross-backend FP16 winrate err in family with the 2026-05-23 baseline (≤ ~3% vs Eigen) | PASS (max 0.78%) |
| 2 | `./katago runtests` | All pass | PASS |
| 3 | `./katago runnnlayertests` (14 configs) | All pass, including `runMLXCoreMLSmokeTest` | PASS |
| 4 | Single-thread MLX FP16 `testgpuerror` | Numbers in family with baseline | PASS (max 1.08%) |

Mux 2g2a result saved to
`cpp/tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_mux2g2a.txt`.
Throughput-benchmark of 2+2 vs 1+1 is deferred to a separate pass
(it depends on workload and is not a correctness gate).

## Rollout

- Single commit on `mlx-backend-squash` branch covering both
  `mlxbackend.cpp` and `mlxwinograd.h`.
- No config changes — the example mux block from commit `64304cdb`
  becomes functional.
- `.claude/MLX_Validation.md` updated with the 2+2 FP16 numbers; that
  file stays untracked per CLAUDE.md.

## Future Work (out of scope)

- Benchmark 2+2 vs 1+1 vs other mux ratios; record nnEvals/s in the
  validation snapshot.
- Audit other backends (Metal) for the same shared-cache cross-thread
  weight-primitive issue if they ever adopt a model cache.
- Track upstream MLX for a `materialize_constants()` helper on
  `mx::array` that would express intent more directly than a bare
  `mx::eval`.
