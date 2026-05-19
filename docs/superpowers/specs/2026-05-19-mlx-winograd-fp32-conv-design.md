# SP1 — Custom Winograd F(2,3) fp32 Convolution Kernel for the MLX Backend

**Date:** 2026-05-19
**Status:** Approved (design)
**Branch:** feature/mlx-backend

## Context

The KataGo-MLX MLX backend currently routes all convolutions through
`mx::conv2d`. A retrospective from a parallel optimization effort established a
proven order of attack for making an fp32 NN backend competitive on Apple
Silicon and then pulling ahead:

1. Replace the generic trunk convolution with a Winograd convolution (the single
   biggest fp32 lever).
2. Autotune the kernel — parameterize launch settings and search rather than
   hand-guess; the only setting that actually moves performance is the data
   layout (channels as the fast axis).
3. Add fp16 with selective fp32 accumulation at the overflow-prone step.
4. Measure honestly throughout — never trust a benchmark number whose parser you
   have not read.

This effort is decomposed into three sub-projects, each with its own
design → plan → build cycle:

| #   | Sub-project                                | Goal                                              |
|-----|--------------------------------------------|---------------------------------------------------|
| SP1 | Custom Winograd fp32 conv kernel (+ harness) | fp32 trunk ties the Metal/MPSGraph backend       |
| SP2 | Autotuner for the Winograd kernel          | Search params; rediscover the known-tuned config  |
| SP3 | fp16 path with selective fp32 accumulation | fp16 pulls clearly ahead at the same accuracy     |

**This document specifies SP1 only.** SP2 and SP3 will be brainstormed and
specified separately.

The tuned parameters are already known from the parallel effort and become
baked-in defaults (and, for SP2, the oracle a correct tuner must rediscover):

- fp32: `tg0=32, tg1=1, vec=1, axis=1`
- fp16 mixed (SP3): `tg0=64, tg1=4, vec=1, axis=1`

where `tg0,tg1` are threadgroup tile dimensions, `vec` is vectorization width
(1 = scalar), and `axis=1` means **channel-fast** (channels are the innermost
loop) — this is the load-bearing knob; the rest were noise in the parallel
effort's search.

## Goal

Replace `mx::conv2d` for the 3×3 stride-1 dilation-1 **trunk** convolutions with
a custom Winograd **F(2,3)** Metal kernel built via `mx::fast::metal_kernel`,
integrated into the existing MLX lazy graph and `mx::compile` cache, fp32 only.
Deliver an honest-measurement harness as the acceptance gate.

**SP1 is accepted only when MLX-fp32 visits/sec ≥ the Metal backend**, read from
raw benchmark output under a thermally-robust paired methodology (below).

## Design

### 1. Graph integration

A new `ConvLayer` code path: for convolutions that are **3×3, stride 1,
dilation 1, and in the trunk**, route through a custom Winograd kernel built
with `mx::fast::metal_kernel`. All other convolutions (1×1, head convs, any
strided/dilated conv) stay on `mx::conv2d` — Winograd does not help 1×1 and
adds risk elsewhere.

`mx::fast::metal_kernel(name, input_names, output_names, source, header,
ensure_row_contiguous, atomic_outputs)` returns a `CustomKernelFunction`
callable as
`(inputs, out_shapes, out_dtypes, grid, threadgroup, template_args, init,
verbose, stream)`. The returned op produces MLX arrays in the lazy graph, so it
participates unchanged in the existing `mx::compile` flow. The compile-cache key
tuple gains a discriminator for `useWinograd` and the active `WinogradConfig` so
fp32/Winograd vs fallback variants do not collide.

A config flag **`mlxUseWinograd`** (default **on**) forces the `mx::conv2d`
fallback for A/B correctness testing and as a runtime safety valve.

### 2. Winograd math — F(2,3), ported not invented

Variant: **F(2,3)** — 2×2 output tiles, 4×4 input tiles (input tile size
= output 2 + kernel 3 − 1 = 4). This matches KataGo's battle-tested OpenCL
backend default `DEFAULT_WINOGRAD_3X3_TILE_SIZE = 4` (the `4` is the input-tile
dimension). The B/G/A transform constants and tiling structure are **ported from
KataGo OpenCL's `openclkernels.cpp` `winograd3x3TileSize=4` path** — these are
the F(2,3) matrices.

Stages, each a graph op (kept separate in SP1; `mx::compile` schedules them —
fusion is explicitly out of SP1 scope):

1. **Weight transform** `G · g · Gᵀ`: 3×3 → 4×4 per (inChannel, outChannel).
   Computed **once at `ConvLayer` construction** (weights are constant); the
   4×4-domain weights are stored on the layer.
2. **Input transform** `Bᵀ · d · B`: each overlapping 4×4 input patch
   (stride 2) → 4×4 transformed.
3. **Batched GEMM**: elementwise over the 16 tile positions, `[tiles × inC] ×
   [inC × outC]` accumulating into `[tiles × outC]`.
4. **Output transform** `Aᵀ · m · A`: 4×4 → 2×2 output tile.

Variable board sizes (7×7–19×19): pad the spatial extent up to a multiple of
**2** with zeros, mirroring the OpenCL backend's tiling. Existing mask handling
around the conv is preserved.

**Rationale for F(2,3) over F(4,3):** F(2,3)'s transform matrices have small,
well-scaled entries; F(4,3)'s are larger and ill-scaled, amplifying
floating-point error. The KataGo design doc explicitly lists F(2×2,3×3) as
having "lower numerical risk than F(4×4,3×3)." F(2,3) still gives ~2.25× fewer
multiplies than direct convolution — most of the benefit, less of the risk —
and this stability margin directly de-risks SP3 (fp16), where F(4,3)'s extra
error would be punishing in half precision. It also mirrors the governing
philosophy: copy a mature, trusted implementation rather than innovate on tile
size. F(4,3) is **not foreclosed** — tile size is a parameterized seam and a
deferred SP2 autotuner dimension, not a permanent ceiling.

### 3. Config struct (parameterized now, searchable in SP2)

```c
struct WinogradConfig { int tg0, tg1, vec, axis, tileSize; };
// fp32 default: { 32, 1, 1, 1, /* F(2,3) input tile */ 4 }
```

- `tg0, tg1` → the call-time `threadgroup` tuple.
- `vec, axis, tileSize` → `template_args` (compile-time kernel
  specialization). `axis=1` selects the channel-fast buffer layout for the
  transform/GEMM tiles — the load-bearing knob.
- Defaults baked to the known-tuned fp32 values. SP2's search must rediscover
  them (the known values are the oracle).

### 4. Files

- **`cpp/neuralnet/mlxwinograd.h`** (new, header-only) — `WinogradConfig`,
  F(2,3) B/G/A constants, Metal kernel source strings, kernel-builder helpers.
  Keeps the already-1518-line `mlxbackend.cpp` focused.
- **`cpp/neuralnet/mlxbackend.cpp`** — `ConvLayer` Winograd path, weight
  pre-transform at construction, compile-cache key discriminator,
  `mlxUseWinograd` flag wiring.
- **`cpp/CMakeLists.txt`** — add `mlxwinograd.h` to MLX backend sources.
- **`cpp/tools/bench_mlx_honest.sh`** (new) — honest-measurement harness.

### 5. Honest-measurement harness (acceptance gate, not optional)

`cpp/tools/bench_mlx_honest.sh` compares the **Metal backend** vs **MLX-fp32**
with a thermally-robust paired methodology:

- **Paired / interleaved design** — alternate A/B/A/B (Metal, MLX-fp32, …) for
  N repetitions rather than all-A-then-all-B, so thermal drift hits both
  backends symmetrically and cancels in the paired delta.
- **Warmup discard** — drop the first run of each backend (cold caches / clock
  ramp); only steady-state runs count toward the verdict.
- **Cooldown between runs** — a fixed sleep between every benchmark invocation
  so each starts from a comparable thermal state.
- **Variance + CI reported** — for each backend and for the paired delta, print
  mean ± stdev and 95% CI alongside the raw per-run lines, so it is directly
  visible that the fp32-vs-Metal signal is far larger than the run-to-run /
  thermal noise band.
- Each run: `./katago benchmark -model <model>.bin.gz -config
  configs/gtp_example.cfg -t 16 -half-batch-size`. Single pinned thread count
  (`-t 16`) — no thread sweep, so no slowest/fastest parser ambiguity. Full raw
  stdout of every run is dumped to a file; the parsed lines are echoed next to
  the extracted visits/sec so the number is auditable.

**Acceptance gate:** paired MLX-fp32 ≥ Metal, with the paired delta's 95% CI
excluding "MLX slower", read from the raw output — never a lone point estimate.

### 6. Correctness validation

- `./katago runnnlayertests` passes (convolution layer reference test).
- `./katago testgpuerror -model <NETWORK>.bin.gz -config gtp_example.cfg
  -reference-file eigen_reference_b18.json` shows **small non-zero** errors
  (typically < 0.1% winrate, < 0.01 score) — **not** all-zero. All-zero means
  the backend is being compared against itself (no/failed reference file), not
  a real cross-backend test.
- Winograd-on vs Winograd-off (`mlxUseWinograd=false` → `mx::conv2d`) output
  diff within fp32 tolerance.

### 7. Non-goals (explicitly out of SP1 scope)

- fp16 / mixed precision — SP3.
- The autotuner search loop and tuned-config persistence — SP2.
- F(4,3) or larger tiles — a deferred SP2 autotuner dimension.
- Kernel-stage fusion (input-transform + GEMM + output-transform) — later
  optimization; SP1 keeps stages as separate graph ops and leaves clean
  parameterization seams for SP2.
