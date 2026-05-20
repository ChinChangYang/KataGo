# SP5 — MLX Winograd Tuner Simplification Design

**Status:** Draft for review

**Predecessor:** SP4 — Aggressive F(2,3) Autotuner ([spec](2026-05-20-mlx-winograd-aggressive-tuning-design.md))

## Goal

Simplify the MLX Winograd tuner by deleting search axes that empirical measurement shows do not influence performance, and by collapsing the SP4 hierarchical (Joint-A → Joint-B → refine, wrapped in a 4-way outer combo) search algorithm into a flat per-stage sweep.

## Motivation

SP4 added six tunable axes — `tg0`, `tg1`, `wpt`, `vw`, `gridOrder`, `matmulOrient` — and a hierarchical search algorithm to explore them within a 180 s cold-start budget. Post-merge experience surfaced two problems:

1. **Three of the six axes never moved off their SP3-equivalent default** on either fp16 or fp32 of the `b18c384nbt` reference model. The kernel template branches and the C++ types that carry them are dead weight.
2. **The outer 4-way wrapper produced a ~30 % cold-start regression rate** by picking Tfast erroneously when timing noise crossed the Joint-B threshold. SP4 mitigated by widening the end-to-end repetition count but did not remove the root cause.

An empirical sensitivity sweep on `b18c384nbt-uec-20221121b.bin.gz` (19×19, batch 1, single thread, v=400, n=3, 2 reps per config) measured the cost of forcing each "supposedly flat" axis to its alternative value:

| Axis flipped | fp16 Δ nps | fp32 Δ nps | Verdict |
|---|---|---|---|
| `matmulOrient` (Std → Tpd) | **−12.0 %** | **−7.5 %** | Sensitive; Std always wins |
| Output `gridOrder` (Cfast → Tfast) | +0.9 % | +0.7 % | Insensitive |
| Output `vw` (1 → 2) | +2.4 % | −2.8 % | Insensitive |
| Input `gridOrder` (Cfast → Tfast) | −3.0 % | **+8.5 %** | Sensitive; **disagrees across dtypes** |

The input-stage `gridOrder` finding is a surprise: SP4 picked Cfast for fp32 input, but Tfast is +8.5 % faster on a controlled flip. That is a real tuner bug — but it is a *tuning-quality* bug, not a *simplification* bug. SP5 keeps the axis searched and defers the fp32 bugfix to a follow-up (SP6).

## Scope

**In scope:**
- Delete three search axes (`matmulOrient`, output `gridOrder`, output `vw`) and all kernel template branches, C++ types, tuner-state fields, cache-format slots, and tests that reference them.
- Flatten the search algorithm to a single per-stage sweep over the remaining axes.
- Bump cache schema to v3; old v2 files are not migrated.
- Replace `bench_sp4_acceptance.sh` with `bench_sp5_acceptance.sh`.

**Explicitly out of scope:**
- Fixing the fp32 input-gridOrder mispick (deferred to SP6).
- Changing search-table value ranges (`inputTg0Values`, `inputTg1Values`, `outputTg0Values`, `outputTg1Values`, `wptValues`, `vwValues` remain as in SP4).
- Adding new model-size coverage (b15c192 / b28c512 / b40c256 sensitivity sweeps).

## Architecture

### Axes after SP5

| Axis | Search? | Values | Where it lives |
|---|---|---|---|
| Input `tg0` | yes | `inputTg0Values` (17 entries) | per-stage sweep |
| Input `tg1` | yes | `inputTg1Values` (15 entries) | per-stage sweep |
| Input `wpt` | yes | `{1, 2, 4, 8}` | per-stage sweep |
| Input `vw` | yes | `{1, 2, 4}` | per-stage sweep |
| Input `gridOrder` | yes | `{Cfast, Tfast}` | per-stage sweep |
| Output `tg0` | yes | `outputTg0Values` (17 entries) | per-stage sweep |
| Output `tg1` | yes | `outputTg1Values` (15 entries) | per-stage sweep |
| Output `wpt` | yes | `{1, 2, 4, 8}` | per-stage sweep |
| Output `vw` | **no** — hardcoded 1 | — | kernel template constant |
| Output `gridOrder` | **no** — hardcoded Cfast | — | kernel template constant |
| `matmulOrient` | **no** — hardcoded Std | — | weight-layout constant in `makeWinogradWeights` |

### Data model

```cpp
struct InputTransformParams  { int tg0, tg1, wpt, vw; GridOrder gridOrder; };
struct OutputUntransformParams { int tg0, tg1, wpt; };
struct MLXWinogradTuneParams { InputTransformParams input;
                               OutputUntransformParams output; };
```

`enum class MatmulOrient` is deleted. `enum class GridOrder` is retained for the input stage only.

### Kernel templates

- Input kernel: `<T, WPT, VW, GRID_ORDER>` (was 5 args in SP4).
- Output kernel: `<T, WPT>` (was 5 args in SP4).

The Tfast branch in `kWinoOutputSource`, the Tpd branch in `kWinoInputSource`, and the VW>1 read paths in the output kernel are all deleted.

### Search algorithm

Replaces SP4's Joint-A / Joint-B / refine / outer-combo cascade with one flat sweep per stage:

```
tuneInput(C, Ntiles, useFP16) -> InputTransformParams:
  best = None
  for go in {Cfast, Tfast}:
    for tg0 in inputTg0Values, tg1 in inputTg1Values:
      for wpt in wptValues, vw in vwValues:
        cand = {tg0, tg1, wpt, vw, go}
        if not isInputCandidateValid(cand, C, Ntiles): continue
        t = timeOneInputTransform(cand, useFP16)   # 5-rep median
        if best is None or t < best.time: best = cand
  return best

tuneOutput(C, Ntiles, useFP16) -> OutputUntransformParams:
  best = None
  for tg0 in outputTg0Values, tg1 in outputTg1Values:
    for wpt in wptValues:
      cand = {tg0, tg1, wpt}
      if not isOutputCandidateValid(cand, C, Ntiles): continue
      t = timeOneOutputUntransform(cand, useFP16)
      if best is None or t < best.time: best = cand
  return best
```

Model-aware validity helpers (`isInputCandidateValid`, `isOutputCandidateValid`) are kept and called inline.

### Cache schema v3

`MLX_WINO_TUNER_VERSION = 3`. Filename: `tunemlxwino3_gpu{NAME}_x{X}_y{Y}_c{C}_mv{MV}_{fp16|fp32}.txt`.

```
VERSION=3
#inputTransform
tg0=<int> tg1=<int> wpt=<int> vw=<int> gridOrder=<0|1>
#outputUntransform
tg0=<int> tg1=<int> wpt=<int>
```

Three non-comment lines (was 4 in v2). The `#global` section is dropped entirely. Output line drops `vw` and `gridOrder`.

`makeCacheKey()` schema:
```
{gpu}-x{X}-y{Y}-c{C}-mv{MV}-fp{16|32}-it[tg0={a}-tg1={b}-wpt={c}-vw={d}-g{e}]-ou[tg0={f}-tg1={g}-wpt={h}]
```

### isValid invariants

```cpp
bool MLXWinogradTuneParams::isValid() const {
  if (input.tg0 <= 0 || input.tg1 <= 0 || input.tg0 * input.tg1 > 1024) return false;
  if (output.tg0 <= 0 || output.tg1 <= 0 || output.tg0 * output.tg1 > 1024) return false;
  if (input.wpt < 1 || input.vw < 1) return false;
  if (output.wpt < 1) return false;
  if (input.gridOrder == GridOrder::Tfast && input.vw != 1) return false;
  return true;
}
```

## Deletions

### `cpp/neuralnet/mlxwinograd.h`
- `enum class MatmulOrient` and all references.
- The Tpd branch in `kWinoInputSource` (matmul write path for `[16, C, Ntiles]` layout).
- The Tfast branch in `kWinoOutputSource` (the entire `if (GRID_ORDER == 1)` clause).
- VW template parameter on output kernel and the VW>1 read paths in `kWinoOutputSource`.
- `makeWinogradWeights(orient)` parameter — collapse to Std-only `[16, Cin, Cout]` layout.
- `winogradConv2d` parameter list: remove `matmulOrient`.

### `cpp/neuralnet/mlxwinotuner.{h,cpp}`
- `MLXWinogradTuneParams::matmulOrient` field + serialization.
- `MLXWinogradTuneParams::gridOrder` (the global, top-level field) — input gridOrder lives on `InputTransformParams` only.
- `OutputUntransformParams::vw` field + serialization.
- `OutputUntransformParams::gridOrder` field + serialization.
- All Joint-A/B/refine helpers: `jointPassA_collect`, `jointPassA_Input`, `jointPassA_Output`, `jointPassB_collect`, `jointPassB_Input`, `jointPassB_Output`, `refineInput`, `refineOutput`.
- `kJointPassACollapseThreshold` constant.
- 4-way outer-combo wrapper in `loadOrAutoTune`.
- Per-stage `gridOrder` encoding in `makeCacheKey` for the output stage.

### `cpp/neuralnet/mlxbackend.cpp`
- `matmulOrient` field on `ConvLayer`.
- `MatmulOrient orient` parameter threaded through `ResidualBlock`, `GlobalPoolingResidualBlock`, `NestedBottleneckResidualBlock`, `BlockVariant`, `Trunk`, `PolicyHead`, `ValueHead`.
- `Model::Model` reading of `tuneParams.matmulOrient`.

### `cpp/tests/testnn.cpp`
- Std-vs-Tpd equivalence tests (fp32, fp16, Tfast×Tpd combo).
- Output Cfast-vs-Tfast bit-identity test + output Tfast tail-guard.
- Output VW equivalence tests (vw=1/2/4 on output).
- Joint-A top-3 sort order test, Joint-A/B Output tests.
- SP4 bad-seed convergence test (the failure mode is structurally impossible after SP5).
- v2-format roundtrip test, cache version-mismatch test.

### `cpp/tools/`
- `bench_sp4_acceptance.sh` removed; replaced by `bench_sp5_acceptance.sh`.

## Additions

### `cpp/tests/testnn.cpp`
1. **v3 roundtrip** — write/load a v3 `MLXWinogradTuneParams`, verify all 7 fields survive. Two cases: input gridOrder=Cfast and gridOrder=Tfast.
2. **v3 isValid invariants** — assert false for wpt=0, vw=0, Tfast+VW>1, tg0·tg1>1024.
3. **Flat-sweep convergence test** — set up `(C=64, Ntiles=64, fp16)`, call new `tuneInput`/`tuneOutput`, assert returned params are isValid() and the winner's timing is ≤ any default-seed candidate's timing. Gated behind `KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST=1`.
4. **Output-kernel monomorphic test** — verify the output kernel JIT-compiles without `VW`/`GRID_ORDER` template args; verify bit-identical output vs the SP4 baseline (VW=1, Cfast) for a fixed input.

### `cpp/tools/bench_sp5_acceptance.sh`
Three gates, structured like SP4's harness:
- **Arm A (perf parity):** SP5-fp16 vs SP4-fp16 paired-t. Pass: `CI_lower(SP5 − SP4) ≥ −2%`. (Small regression budget for axes we removed despite local non-zero deltas.)
- **Wall-time:** cold-start tuner with `trash`-cleared cache directory completes in < 120 s. (Was 180 s in SP4.)
- **Accuracy:** `testgpuerror -reference-file eigen_reference_b18.json` exits 0.

## Tests Retained

- WPT bit-for-bit equivalence (1/4/8) + tail-guard at Ntiles=100, WPT=8.
- Input Cfast-vs-Tfast bit-identity + input Tfast tail-guard (C=67, WPT=8).
- Input VW bit-for-bit equivalence (vw=1/2/4 on fp16 Cfast).
- Candidate enumeration validity (C=64, C=66 with vw=4 filtered, Tfast forces vw=1) — input only.
- `isValid()` branch tests for wpt=0, vw=0, Tfast+VW>1.

## Validation Strategy

**Pre-merge gates** (all must pass):

| Gate | Command | Pass criterion |
|---|---|---|
| Build | `cmake -G Ninja -DUSE_BACKEND=MLX && ninja` | exit 0, no new warnings |
| Unit tests | `./katago runtests && ./katago runnnlayertests` | exit 0 |
| Long sweep | `KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST=1 ./katago runnnlayertests` | exit 0 |
| Acceptance | `cpp/tools/bench_sp5_acceptance.sh` | all three sub-gates PASS |

**Empirical post-merge sanity check:**

The v3 fp16 cache for b18c384 should reproduce (within ±1 tg-step / ±1 wpt-step) the SP4 winners on the axes that remain:
- input `(tg0, tg1, wpt, vw, gridOrder) ≈ (32, 1, 1, 2, Cfast)`
- output `(tg0, tg1, wpt) ≈ (32, 2, 1)`

A different `wpt` or `vw` would be a regression flag. The known fp32 input-gridOrder mispick from the sensitivity sweep is expected to persist and will be addressed in SP6.

## Risk Register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Flat sweep exceeds 120 s cold-start budget | Low (math: ~70 s on b18c384) | Acceptance gate fails loudly; fall back to coarser tg tables before re-attempting |
| `MatmulOrient` removal misses a call site across 5 layer types | Medium | Compile error catches all non-default args; spec reviewer subagent re-checks |
| User confusion from leftover v2 cache files | Low | Different filename suffix; old files remain untouched. Note in commit message |
| fp32 input-gridOrder mispick worsens after refactor | Low — same algorithm picks same value | SP6 will address; SP5 acceptance gate measures parity, not improvement |

## Open Questions

None. All design decisions have been resolved via the four clarifying questions during brainstorming.
