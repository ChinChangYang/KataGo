# SP4 — Aggressive F(2,3) Autotuner for MLX Winograd fp16

**Status**: Design
**Date**: 2026-05-20
**Branch**: `feature/mlx-backend`
**Builds on**: SP3 (fp16 Winograd, `36a88189`)

## Goal

Expand the MLX Winograd autotuner from a 2-D `(tg0, tg1)` sweep into a 6-axis hierarchical search, so the tuner can reach materially better launch geometries on the same F(2,3) algorithm without changing the algorithm itself. Stay within fp16 mode. Hold the SP3 accuracy gate.

## Non-goals

Explicitly out of scope for SP4:

- F(4,3) larger tile (separate SP — different algorithm)
- Fusing BN/ReLU/residual-add into the output untransform kernel (separate SP)
- Custom Metal GEMM to bypass MLX steel gemm's fp32 accumulator (aborted SP4-original)
- Tuning MLX's matmul tile params (not exposed by MLX public API)
- Cross-machine cache sharing
- Search-strategy variants (simulated annealing, Bayesian opt, etc.)
- Multi-batch tuning

## Architecture

### Current state (SP3)

Two custom Metal kernels around an `mx::matmul`:

```
input (NHWC fp16)
  └─ wino_input_transform_f16   [grid=(C, Ntiles, 1), threadgroup=(tg0, tg1, 1)]
       └─ T tensor [16, Ntiles, C]
            └─ mx::matmul(T, Uw)              # Uw is [16, C, Cout] fp16
                 └─ M tensor [16, Ntiles, Cout]
                      └─ wino_output_untransform_f16   [grid=(Cout, Ntiles, 1), tg=(tg0, tg1, 1)]
                           └─ output (NHWC fp16)
```

Tuner searches only `(tg0, tg1)` per stage. 48 candidates × 2 stages.

### SP4: 6 axes total

Four per-stage axes, one stage-shared axis, one global axis:

| Axis | Scope | Domain | What it controls |
|---|---|---|---|
| `tg0` | per-stage | `{1, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 160, 192, 256, 384, 512, 1024}` (17 values) | Fast-axis threadgroup dim |
| `tg1` | per-stage | `{1, 2, 4, 5, 8, 10, 16, 20, 25, 32, 40, 50, 64, 100, 128}` (15 values) | Slow-axis threadgroup dim |
| `wpt` | per-stage | `{1, 2, 4, 8}` | Tiles (or channels) processed per thread |
| `vw` | per-stage | `{1, 2, 4}` (scalar / half2 / half4) | Vector width for packed loads/stores |
| `gridOrder` | stage-shared | `{Cfast = (C, Ntiles, 1), Tfast = (Ntiles, C, 1)}` | Grid-axis order — fast axis identity |
| `matmulOrient` | global | `{std, tpd}` | Matmul operand layout (see below) |

`tg1` non-full mode drops to `{1, 2, 4, 8, 10, 16, 25, 32, 50, 100}` (10 values). This also fixes the pre-existing inconsistency where the output stage's non-full `tg1` set skipped `8`.

### Couplings (drive the search strategy in §Search)

- `(wpt, vw)` — tight. Vector packing happens inside the WPT loop body. Searched jointly.
- `(tg0, tg1)` — tight. Threadgroup occupancy and shared-mem tile span move together. Searched jointly.
- `(wpt/vw)` × `(tg0/tg1)` — loose. Searched separably, with one refinement pass.
- `gridOrder` — stage-shared within an orientation. Both stages must agree because input's output layout is output's input layout. Not searched per-stage.
- `matmulOrient` — global. Reshapes both stages' I/O *and* the host filter array. Outermost loop.

### Kernel template instantiation

`wpt`, `vw`, and `gridOrder` become MLX `template_args` alongside the existing `T` (dtype) arg:

```cpp
std::vector<std::pair<std::string, mx::fast::TemplateArg>> templArgs = {
  {"T",         dtype},                  // existing
  {"WPT",       wpt},                    // new — int
  {"VW",        vw},                     // new — int
  {"GRID_ORDER", gridOrder == Cfast ? 0 : 1}  // new — int
};
```

Each `(T, WPT, VW, GRID_ORDER)` combination is a separately JIT-compiled Metal kernel. JIT cache is populated lazily — only the configs the tuner actually times get compiled. After tuning, exactly one combination per stage is used for the rest of the process lifetime. Kernel name suffix is `wino_input_transform_f16_w<WPT>_v<VW>_g<0|1>` so MLX's kernel cache keys differ across instantiations.

### `matmulOrient` and host-side filter layout

`matmulOrient = std`:
- Input transform output: `[16, Ntiles, C]`
- Filter `Uw`: `[16, C, Cout]` (current SP3 layout from `makeWinogradWeights`)
- Matmul: `[16, Ntiles, C] @ [16, C, Cout] → [16, Ntiles, Cout]`

`matmulOrient = tpd`:
- Input transform output: `[16, C, Ntiles]`
- Filter `Uw`: `[16, Cout, C]` (transposed at `makeWinogradWeights` time)
- Matmul: `[16, Cout, C] @ [16, C, Ntiles] → [16, Cout, Ntiles]`
- Output untransform reads `m[(p * outC + oc) * Ntiles + tileIdx]` instead of `m[(p * Ntiles + tileIdx) * outC + oc]`

The orient is picked by the tuner once per `ConvLayer` construction. Filter is built in the chosen orientation; no runtime branching in the hot path.

### Cache schema

Plain-text format extended (keeps SP2/SP3 prefix style):

```
VERSION=2
#global
matmulOrient=std
gridOrder=Cfast
#inputTransform
tg0=32 tg1=2 wpt=4 vw=4
#outputUntransform
tg0=16 tg1=4 wpt=2 vw=4
```

(`gridOrder` lives in `#global` because it is stage-shared.)

Cache filename gains an orient suffix mirroring SP3's `_fp16/_fp32` pattern:

```
mlxwinograd_<gpuName>_<nnX>x<nnY>_c<trunkC>_v<modelVer>_fp16_or<std|tpd>.txt
```

This way retunes for the other orientation don't stomp.

SP3 cache files (without the new fields) are detected via the `VERSION=` line (SP3 had no version line). On schema mismatch, the loader logs `"SP4 schema mismatch — retuning"` and triggers a cold-start search. No partial-value migration.

## Search

### Strategy: hierarchical with joint passes

```
for matmulOrient in {std, tpd}:                          # 2 outer
  for gridOrder in {Cfast, Tfast}:                       # 2 middle
    for stage in {input, output}:                        # 2 stages independent under fixed orient/gridOrder
      # Joint pass A — tight (wpt, vw) coupling
      sweep (wpt, vw) ∈ valid-pairs at SP3-default (tg0=32, tg1=1)   # ≤12 cfgs
      keep top-3

      # Joint pass B — tight (tg0, tg1) coupling, retimed per top-(wpt,vw)
      for each of top-3 (wpt, vw):
        sweep (tg0, tg1) ∈ valid-pairs                       # ~200 cfgs
      keep best (wpt, vw, tg0, tg1) per stage

      # Refinement — one coordinate-descent pass
      sweep each axis individually around the winner          # ~40 cfgs

    # End-to-end verification — single wall-time measurement
    time full winogradConv2d with chosen (input-cfg, output-cfg)  # 1 cfg

pick the (matmulOrient, gridOrder) combo with the best end-to-end time
```

### Cost budget

| Step | Configs |
|---|---|
| Joint pass A per stage | ≤12 |
| Joint pass B per stage | 3 × ~200 = 600 |
| Refinement per stage | ~40 |
| End-to-end per outer combo | 1 |
| **Per stage per (orient, gridOrder)** | **~652** |
| × 2 stages × 2 gridOrders × 2 orients | **~5216** |

At ~15 ms/config (SP2's existing microbench harness — 5 warmup + 9 timed reps, median): **~78 s cold-start wall-time**. Hard alert at 180 s.

### Why not naive Cartesian

Raw 6-axis Cartesian after validity filters: ~7200 configs ≈ 108 s with no anti-local-optimum benefit over the hierarchical structure. Hierarchical search saves ~30 s while keeping the tight-coupling guarantees.

### Anti-local-optimum guardrails

1. Joint passes for `(wpt, vw)` and `(tg0, tg1)` — 2-D grids, not 1-D coordinate sweeps.
2. Top-3 carry-through after Joint A — a `(wpt, vw)` that's 5% slower at default `(tg0, tg1)` may win after retiming under a different `(tg0, tg1)`.
3. End-to-end measurement at the outer level — catches matmul-reshape cost shifts that per-stage microbenches cannot see.

### Validity filtering during enumeration

Removed before timing (not skipped during sweep):

- `tg0 * tg1 > 1024` (Metal threadgroup cap) — existing
- `vw ∈ {2, 4}` requires the fast-axis dim to be divisible by `vw`. For the current model, this prunes `vw=4` combos where `C/Cout/Ntiles` along the fast axis isn't divisible by 4.
- `wpt > 1` does not require divisibility — kernels include a tail guard so any `wpt` is valid for any shape; the tail thread cost is amortized.
- `(vw, gridOrder)` combos where the chosen fast axis can't be vectorized are dropped.

The loop never dispatches an invalid combo. No `+∞ ms` placeholder times in the search.

### Seed and reTune

| Scenario | Behavior |
|---|---|
| Cold cache | Full hierarchical search ~78 s |
| Cache hits all fields with matching `VERSION=2` | Load and use, no search |
| SP3 cache (no `VERSION` line) | Log "SP4 schema mismatch — retuning", cold-start |
| `reTune=true` | Full search, ignore cache |
| `seedOverride` (test-only) | Skip Joint A/B; run refinement only. Used by the search-converges-from-bad-seed test. |

## Acceptance

All five gates must hold for SP4 to ship:

### 1. Correctness preserved

- `./katago runtests` passes.
- `./katago runnnlayertests` passes.
- `./katago testgpuerror -model <b18c384>.bin.gz -reference-file eigen_reference_b18.json` shows winrate error < 0.1% and score error < 0.01. SP3 fp16 bar, unchanged.

### 2. Performance gate (paired-t over SP3 MLX-fp16)

Reuse the SP3 acceptance orchestrator with two arms:

- **Arm A**: SP3-tuned MLX-fp16 (cache from SP3 commit `36a88189`)
- **Arm B**: SP4-tuned MLX-fp16 (cache freshly generated by SP4 tuner)

Same b18c384 model, same hardware, same `numSearchThreads`, same arm length.

Pass condition: **Arm B throughput > Arm A throughput at p < 0.05**. No minimum effect size — "expand search space" might land on the SP3 config on some hardware; that's acceptable as long as it doesn't regress. Statistical equivalence (CI bounds contain 0) is also a pass.

### 3. Tuner sanity test

Extends the existing SP2 search-converges-from-bad-seed test:

- Seed: `(wpt=8, vw=1, tg0=1, tg1=1, gridOrder=Tfast)` — deliberately poor.
- Assert: refinement pass moves to a config that beats the seed by ≥ 30% per-stage time.

Catches regressions where the search silently fails to explore new axes.

### 4. Cache schema migration is graceful

Automated test:

1. Place an SP3-format cache file (no `VERSION=` line) at the expected path.
2. Invoke `loadOrAutoTune`.
3. Assert: log contains `"SP4 schema mismatch — retuning"`, cold-start search runs, new file is written with `VERSION=2` and all six fields populated.

### 5. Tuner wall-time bound

Cold-start search must complete in < 180 s on the developer machine (M-series, b18c384). Target is 78 s. Above 180 s the gate fails — indicates a pruning bug or enumeration leak.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `vw=4` half4 loads break alignment ABI silently | medium | wrong-result | testgpuerror gate + a bit-for-bit unit test comparing scalar vs vw=4 output on a synthetic input |
| Joint pass B re-times top-3 when they're nearly identical | medium | +20% search time | If top-3 stage times within 2%, collapse to top-1 (logged) |
| `matmulOrient=tpd` duplicates `makeWinogradWeights` logic | high | code complexity | Single function with a layout enum; chooses output stride at filter-array-write time. Construction-time decision, no runtime branch. |
| Coordinate-descent refinement misses a global optimum that joint passes also missed | low | suboptimal config | Top-K carry-through is the guardrail; accept this tradeoff for bounded search time |
| `tg0=1024` invalid on some older M1 variants (threadgroup mem limit) | low | tuner crash | Per-candidate dispatch errors are caught and treated as `+∞ ms`; search continues |
| Optimum doesn't transfer across M1 Pro / M2 Max / M4 | high | none | Cache key already includes `gpuName`; per-machine retune is expected behavior |
| ~78 s first-run latency for users | high | UX friction | Already accepted in SP2; keep existing log message |

## What "done" looks like

- `MLXWinogradTuneParams` carries 4 per-stage fields (`tg0, tg1, wpt, vw`) plus 2 globals (`gridOrder, matmulOrient`).
- Kernels are template-instantiated on `(T, WPT, VW, GRID_ORDER)`.
- Cache file uses `VERSION=2` schema; cache filename gains `_or<std|tpd>` suffix.
- SP3 caches trigger a clean retune with a clear log line.
- One-shot `cmake -G Ninja -DUSE_BACKEND=MLX && ninja && ./katago benchmark …` reproduces the perf gate locally.
- SP3 acceptance orchestrator extended with the SP4 arm; both arms run paired-t.
