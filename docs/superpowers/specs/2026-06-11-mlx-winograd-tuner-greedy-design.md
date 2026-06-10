# MLX Winograd autotuner — sensitivity-ordered greedy coordinate descent

- **Date:** 2026-06-11
- **Status:** Design approved; pending implementation plan
- **Branch:** `feature/mlx-app-migration`
- **Component:** `cpp/neuralnet/mlxwinotuner.cpp` (+ a DEBUG measurement harness in the iOS app)

## 1. Problem

On the iPad mini 6 (A15), selecting the MLX/GPU backend makes the **Loading screen take
more than 15 s** on a cache miss / forced Re-tune. The dominant suspect is the Winograd
autotuner.

**Root cause (why it's slow):** the tuner is **synchronization-bound, not compute-bound.**
Its inner primitive (`timeOneInputTransform` / `timeOneOutputUntransform`) builds one lazy
kernel node and calls `mx::eval` — a dispatch that **blocks the CPU until the GPU drains.**
The coarse sweep does this for every candidate × every rep: ~240 candidates ×
(1 warm-up + 7 reps) ≈ **1,920 synchronous `mx::eval` calls per net.** The transform
kernels are tiny (microseconds of GPU work), so each call's wall-time is dominated by the
fixed dispatch/round-trip latency (~ms on the A15), not the kernel. Cost ≈
`N_evals × sync_latency`. Reducing reps/grid (already done) scales `N_evals` only linearly;
it does not attack the per-eval floor.

**Already shipped/queued (context, not part of this work):**
- Coarse rep budget (7) + trimmed coarse grid + Fast/Full + Re-tune UI — committed `ed7415a8`.
- Cross-net shape **memo** so the main net and the human SL net (both b18c384, identical
  3×3-conv shapes) tune **once** per session, not twice — uncommitted on the branch.

## 2. Goals & non-goals

**Success metric:** the **whole Loading screen** (model load + first-eval JIT + tuner) is
**< 15 s** on the iPad. Working assumption: the Winograd sweep is the dominant slice; the
in-code timing (§5) confirms it actually shrinks the screen below 15 s. If it somehow does
not, the remaining components (model load / JIT / second-net load) are a **separate
follow-up**, out of scope here.

**Scope:** the **tuner search algorithm only** — replace the exhaustive coarse search with a
faster search. No changes to model loading, JIT, or net deferral in this spec.

**Quality bar ("minimal performance loss"):** the new search's winner must have a measured
**transform time within 5 %** of the exhaustive grid's winner (kernel-level; a fraction of a
percent end-to-end given the documented broad plateau where geometry moves ≤1.5 %
end-to-end). Validated once, in code, on the iPad.

**Non-goals:** the wide-grid operator path (`./katago tuner -full`), the cache format
(`VERSION=3`), the memo, and the Fast/Full + Re-tune UI all stay unchanged. A
user-selectable MLX/GPU board size is explicitly future work (see §8).

## 3. Approach

**Sensitivity-ordered greedy coordinate descent** over the existing coarse axes, reusing the
existing per-candidate scorer unchanged. Chosen over batched-reps and prior-pruning because
it is the simplest high-leverage win, is self-correcting (keeps measuring uphill), and is
safe on a broad plateau (a local optimum ≈ global). Batched reps remain a documented escape
hatch if greedy alone is insufficient.

## 4. Design

### 4.1 Scope & architecture

The change is confined to the **coarse (`full=false`) path** of `mlxwinotuner.cpp`:

- Replace the exhaustive Cartesian enumeration inside `flatSweepInput` / `flatSweepOutput`
  with a greedy coordinate-descent search over the **same** axes and **same** coarse value
  sets, reusing `scoreInputTransform` / `scoreOutputUntransform` **unchanged** (same per-shape
  rotation, same median-of-7 reps). Only *which* candidates get measured changes.
- `full=true` keeps the exhaustive wide grid — unchanged. `buildInputCandidatesForTesting` /
  `buildOutputCandidatesForTesting` stay (used by the full path and tests).
- `loadOrAutoTune` and its callers, the memo, the UI, and the cache format/`VERSION=3` are
  untouched. The greedy search lives behind the existing `flatSweepInput`/`flatSweepOutput`
  signatures.

### 4.2 The algorithm: sensitivity-ordered greedy coordinate descent

**Axes & values (reuse the coarse sets):**
- Input: `tg0{16,32,64,128}`, `tg1{1,2,4,8}`, `wpt{1,2,4}`, `vw{1,2,4}`, `gridOrder{Cfast,Tfast}`.
- Output: `tg0{16,32,64,128}`, `tg1{1,2,4,8}`, `wpt{1,2,4}`.

**Sensitivity study (one-time, dev, on the A15 — "prior performance study"):** a
one-factor-at-a-time (OFAT) probe from the baked default — vary each axis across its values
with the others held at default, record the score *range* that axis induces. That range is
the axis's main-effect sensitivity (~16 measurements). Output: axes ranked by sensitivity,
**baked into the code as a documented constant** (re-derived only if the value sets change).
The shipped tuner never runs the exhaustive grid.

**Hypothesized ranking (study confirms/reorders):**
- Input: `gridOrder` (Cfast vs Tfast memory pattern — usually the biggest swing) > `tg0`
  (threadgroup size / occupancy) > `tg1` > `wpt` (ILP; high values rarely win) > `vw`
  (vectorization; only 3 values).
- Output: `tg0` > `tg1` > `wpt`.

**Descent:** seed at the baked default (input `{32,1,1,1,Cfast}`, output `{32,1,1}`) — already
valid, already scored as the baseline, and the always-valid floor. Sweep axes in the fixed
sensitivity order, highest first: for the current axis, hold the others at the current best,
score every *valid* value, lock in the lowest-scoring one. After a full pass, repeat if
anything changed; stop on convergence (a no-change pass) or at **`maxPasses = 3`** (it
converges earlier in practice). One input pass ≈ 11 new candidates; ~2 passes ≈ **~25–30
candidates vs 240.**

**gridOrder/vw coupling resolves itself:** because `gridOrder` is high-sensitivity it is locked
*before* `vw` is explored, so `vw` is always swept under a fixed gridOrder and the
Tfast→`vw=1` constraint needs no special-casing (each value is still checked with
`isInputCandidateValid` against the current other axes).

**Robustness & determinism:** best-so-far stays seeded with the default, so if every value on
an axis is invalid/throws, that axis keeps its current value and the result still passes
`isValid()`. Fixed axis order (the sensitivity constant), fixed value order, ties keep the
incumbent ⇒ deterministic ⇒ reproducible cache. Scoring is the unchanged median-of-7
`scoreInputTransform`.

**Expected:** input+output together ≈ 1,920 → ~250–300 evals (~6–7×).

### 4.3 Quality gate & testability

**Quality gate (one-time, dev, iPad):** on the app's shape (b18c384 → c384, 37×37, fp16), run
**both** exhaustive and greedy on the same shape and require the greedy winner's transform
time **within 5 %** of the exhaustive winner. Cross-check on the Mac optionally. Runs during
development via the study harness (§4.4), not at load.

**Testability — callback refactor:** extract the greedy search into a **pure core** that takes
a scoring callback `double score(candidate)` instead of calling the GPU directly. The
GPU-backed scorers become the production callback; the search logic is then **unit-tested
GPU-free** with a synthetic scoring function:
- converges to a planted optimum,
- only ever proposes valid candidates (respects the `vw`/gridOrder coupling),
- is deterministic (same input → same winner),
- terminates within `maxPasses`.

Existing tuner tests (`planShapeRotation`, candidate enumeration, filename, v3 round-trip)
stay as-is.

### 4.4 Instrumentation & automated measurement harness

Goal: capture every tuner measurement on the iPad with **zero manual interaction.**

1. **`MLXTuneExperimentView` (launch-arg-gated, `#if DEBUG`).** The app root renders this
   instead of the picker/game UI when launched with `--mlx-tune-experiment` (via
   `ProcessInfo.processInfo.arguments`). On appear it **auto-runs** (no tap): forces MLX/GPU
   (device 0) + `reTune=true` for the built-in net and starts `KataGoHelper.runGtp(...)`
   headlessly on a background thread, driving one fresh tune. It shows status/results on
   screen and mirrors them to stderr. Launched via
   `devicectl process launch --console … --mlx-tune-experiment`; the tuner runs during engine
   init, logs, then the harness marks "done" and the process is terminated.
2. **Permanent `[MLX-TUNE]` line** — per-stage + total ms + `considered=N` (candidate count).
   The production by-code measurement, captured the same way. Low-noise single line (the
   tuner runs only on a cache miss / Re-tune); KataGo's logger writes nowhere on iOS
   (`logToStderr=false`), so stderr is the only on-device signal.
3. **Study/acceptance dump (compile-gated `MLX_TUNE_STUDY`).** When defined, one tuner
   invocation runs **both** exhaustive and greedy and dumps every candidate's
   `(axis values, score)` + both winners + the within-5 % delta. One harness run yields the
   per-axis sensitivity ranking (to bake the order) and the greedy-vs-exhaustive acceptance
   check. Not in shipped builds.

### 4.5 Error handling & edge cases

- **Invalid candidates** → skipped via the existing `try/catch` around scoring; never fatal.
- **All-invalid axis** → keeps the current value; result always passes `isValid()` (backstop).
- **Termination** → converge on a no-change pass, else stop at `maxPasses`.
- **Determinism** → reproducible cache (fixed order + tie-break).
- **gridOrder/vw coupling** → handled by ordering + per-value validation.
- **Harness** → headless, terminable via `devicectl`/`--terminate-existing`; does not arm the
  crash-recovery sentinel (dev path).
- **Degenerate model shape** → existing `planShapeRotation` asserts, unchanged.

## 5. Verification flow (no user help)

`xcodebuild` (device, Debug) → `devicectl install` →
`devicectl process launch --console --mlx-tune-experiment` → harness auto-runs → read stderr
(`[MLX-TUNE]` timing + `considered=N`; study dump for sensitivity + 5 % acceptance) →
implement greedy with the derived order → re-run the harness → confirm the tuner ms dropped,
the 5 % gate holds, and the Loading screen is < 15 s. Iterate without manual interaction.

## 6. Implementation outline

1. Add the OFAT sensitivity study + the exhaustive/greedy study dump (compile-gated) and the
   extended `[MLX-TUNE]` line.
2. Add the `MLXTuneExperimentView` headless harness (DEBUG, launch-arg).
3. Run the harness on the iPad → derive the sensitivity order + confirm sync-bound diagnosis.
4. Refactor the greedy search into a callback-based pure core; implement
   sensitivity-ordered coordinate descent for input and output; wire it into the coarse path.
5. Unit-test the search core (GPU-free).
6. Re-run the harness → confirm 5 % gate + Loading < 15 s.

## 7. Risks

- **Greedy lands off-plateau** → mitigated by the 5 % acceptance gate (validated, not assumed)
  and the seeded-default floor.
- **Sync-overhead is not actually the bottleneck** (e.g. JIT/model-load dominates) → the
  harness's first run reveals this before any algorithm change; if so, this spec's fix is
  insufficient and the remainder is a separate effort (per §2).
- **Sensitivity ranking is shape-specific** → the app has a single shape (b18c384, 37×37); the
  ranking is derived for it. Noted, acceptable.

## 8. Future work (out of scope)

- User-selectable **MLX/GPU max board size** (like the CoreML/NE picker) so the tuner and NN
  buffers optimize for the board actually played (e.g. 19×19) instead of the hardwired 37.
  Captured in memory `project_mlx_gpu_user_board_size_future`.
- **Batched reps** as a further sync-amortizing lever if greedy alone is insufficient.
