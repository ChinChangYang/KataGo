# MLX Backend Comment Cleanup — Design

**Status:** Approved (sections 1-3 per brainstorming, 2026-05-21).
**Scope:** Dead-code / stale-comment cleanup in the MLX backend. No
behavior change beyond one added unit-test case.

## Goal

Three surgical commits that fix plainly broken comments, strip
internal-stage labels from historical comments while preserving their
invariant content, and rewrite the larger block comments in
`mlxwinograd.h` into present-tense API docs. Plus one test case to
close an existing coverage gap.

## Motivation

The MLX backend has gone through five sprint-style rewrites (SP1–SP5) in
the last ~6 weeks, plus the adaptive-scoring rewrite landed this week.
The codebase carries ~25 comment sites that reference internal stage
labels ("SP5 Task 5", "SP3 acceptance", "Tasks 4+; 1 = SP3 behavior")
that no longer mean anything to a reader who didn't live through the
rewrite. Three of those comments are now plainly stale (a "Step 4.2"
pointer with no anchor; missing warmup-comment consistency between
sibling functions; one unused structured-binding name). One unit-test
gap exists where no case exercises `planShapeRotation`'s rounding-repair
branch.

This cleanup keeps every load-bearing invariant the comments are
documenting (Std-only matmul layout, VW=1 / Cfast monomorphism, fp32
merged-BN params, fp16-on-auto, empirical Cfast sweep rationale) and
drops the stage labels that name *when* those invariants became true.
`git blame` still surfaces that history for anyone who needs it.

## Non-Goals

- No structural file splits (mlxbackend.cpp staying at 2210 lines).
- No API surface changes (the 7 `*ForTesting` helpers in
  `mlxwinotuner.h` stay).
- No perf review or benchmark re-runs (comments only, plus one ungated
  unit test addition).
- No cross-backend re-validation (no behavior change).
- No tuning of the adaptive-scoring spec constants
  (`kWorkFractionFloor=0.03`, `kRepFloor=3`, `kMaxShapes=3`).

## Commit 1 — Fix plainly broken items, close rounding-repair test gap

**Files:** `cpp/neuralnet/mlxwinotuner.cpp`

1. **Stale "Step 4.2" pointer at line 1241.** The comment
   `// model walk; see Step 4.2 comment).` refers to a Step-4.2 anchor
   that does not exist anywhere in the codebase (the original plan's
   Step-4.2 section described the call-site comment but no comment was
   actually placed). Replace with a present-tense statement:
   `// model walk; mlxbackend.cpp pre-computes the histogram at model
   load and stores it on ModelInfoForTuning, so the tuner does not
   re-walk the descriptor.`

2. **Unused structured-binding name at lines 728 and 810.** Replace
   `for(const auto& [ch, n] : mi.conv3x3InputHistogram) { ... ch ...}`
   with `for(const auto& p : ...) { ... p.first ...}`. The bound `n` is
   never read, and the `[[maybe_unused]]`-on-structured-binding
   extension isn't portable across older clangs. Same edit on both
   sites.

3. **Missing warmup comment on `scoreInputTransformPerShape` and
   `scoreOutputUntransformPerShape`.** Their sibling functions
   `scoreInputTransform` / `scoreOutputUntransform` carry
   `// Warmup: 1 rep on dominant, discarded.` next to the warmup-rep
   loop. The per-shape variants share the rotation but lack the
   comment, which makes the warmup-loop intent non-obvious. Add the
   identical one-liner.

4. **`planShapeRotation` rounding-repair coverage gap.** Existing test
   cases A–E in `runPlanShapeRotationTests()` never hit the branch
   where `Σ lround(weight_i * 19) ≠ 19` — every case happens to round
   to 19 exactly. Add **Test F: three equal-weight shapes**. Histogram
   `{(100, 1), (100, 1), (100, 1)}`. Each fraction is exactly 1/3 ≈
   0.3333, so `lround(0.3333 * 19) = lround(6.333) = 6` for each shape.
   The pre-repair sum is 18; the repair branch adds +1 to the dominant
   shape's `measureReps`. Final allocation `(7, 6, 6)`. Assertions: sum
   equals `kMeasureReps`=19, dominant shape gets 7, others get 6, all
   ≥ `kRepFloor`=3.

**Risk:** Items 1–3 are comment-only. Item 4 is an ungated unit test
addition; no production code path changes.

**Commit message:** `Fix stale comments and close rounding-repair test gap`

## Commit 2 — De-tag SP/Task historical references

**Files:** `cpp/neuralnet/mlxbackend.cpp`, `cpp/neuralnet/mlxwinograd.h`,
`cpp/neuralnet/mlxwinotuner.cpp`, `cpp/neuralnet/mlxwinotuner.h`.

**Scope:** All SP/Task historical references across the four MLX
backend files — production code, kernel-source string literals, and
test-runner self-documenting comments. A full enumeration during
planning found ~80 sites total: ~30 in `mlxbackend.cpp` (production +
test runners at the bottom), ~25 in `mlxwinograd.h` (struct preambles
+ Metal kernel headers), ~25 in `mlxwinotuner.cpp` (scoring kernels +
test runners), and 1 in `mlxwinotuner.h`. The plan document enumerates
every site; this spec defines the principle.

**Principle (rules of engagement):**

1. **Keep the invariant, drop the stage label.** If a comment states an
   invariant ("output kernel is monomorphic on VW=1"), keep it. Strip
   the parenthetical or prefix that names *when* the invariant became
   true ("SP5 Task 3:", "(SP4 Task 5 / SP5 Task 4)", "after Task 5+").
2. **Pure-history comments get deleted.** If the comment is entirely
   "SPx Task N: <axis> removed" and the surrounding code already
   reflects that the axis is gone, the comment carries no surviving
   information and should be deleted.
3. **Test-comment SP/Task tags are stage labels, not invariants.**
   `// SP4 Task 3: WPT=1, 4, 8 must produce bit-identical output.` has
   "WPT=1, 4, 8 must produce bit-identical output" as the invariant
   (the test's purpose); "SP4 Task 3" is the stage label. Strip.
4. **Specific engineering rationale survives.** "(empirical sensitivity
   sweep showed <1% delta)" stays even when its SP/Task tag is
   dropped. The rationale is engineering judgment that a future
   contributor would otherwise have to re-derive.
5. **Block comments at `mlxwinograd.h:12-15`, `:161-171`, `:291-302`
   are out of scope for Commit 2.** They need full rewrite, not
   in-place de-tag — that's Commit 3.

The plan document enumerates every site with concrete before/after
text so the implementer doesn't have to apply the principle from
scratch.

**Risk:** Comment-only diff. No build/test impact.

**Commit message:** `De-tag historical SP/Task references in MLX comments`

## Commit 3 — Rewrite historical block comments

**Files:** `cpp/neuralnet/mlxwinograd.h` only.

Three block sites that are too dense for the in-place de-tag pattern of
Commit 2 because they describe what the tunable knobs *are* in terms of
when each one was added or removed.

### Block 1 — `mlxwinograd.h:12-15` (struct preamble)

**After:**
```cpp
// Per-stage launch-geometry configs. Input transform exposes
// (tg0, tg1, wpt, vw, gridOrder); output untransform exposes (tg0, tg1, wpt).
// The output kernel is monomorphic on VW=1, GRID_ORDER=Cfast, and the
// matmul layout is monomorphic on Std for both stages.
```

### Block 2 — `mlxwinograd.h:161-171` (input kernel header)

**After:**
```cpp
// F(2,3) input transform kernel: NHWC T input -> [16, Ntiles, C] T output.
// The matmul layout is monomorphic on Std ([16, Ntiles, C]).
// Template args (JIT-substituted via MLX template_args):
//   T              — float or half (precision)
//   WPT            — tiles per thread
//   VW             — vector width for packed loads
//   GRID_ORDER     — 0=Cfast (C is fast axis), 1=Tfast (Ntiles fast)
// Grid:
//   Cfast: (ceil(C/VW), ceil(Ntiles/WPT), 1)
//   Tfast: (Ntiles,     ceil(C/WPT),      1)
```

### Block 3 — `mlxwinograd.h:291-302` (output kernel header)

**After:**
```cpp
// F(2,3) output untransform kernel: [16, Ntiles, outC] T input -> NHWC T output.
// Template args (JIT-substituted via MLX template_args):
//   T              — float or half (precision)
//   WPT            — tiles per thread
// Grid: (Cout, ceil(Ntiles/WPT), 1).
// nhwc input array carries the [N,H,W,outC] dims because metal_kernel only
// exposes *_shape for inputs, not outputs.
// The output kernel is monomorphic on VW=1, GRID_ORDER=Cfast, and matmul
// layout=Std. (GRID_ORDER=Cfast was chosen from an empirical sensitivity
// sweep showing <1% delta vs Tfast; the other two are structural.)
```

**Choices explicit in this rewrite:**

- Block 3 preserves the empirical Cfast-vs-Tfast sensitivity-sweep
  rationale. That's engineering judgment a future contributor would
  otherwise have to re-derive.
- Block 2 keeps both Cfast and Tfast grid descriptions because
  `GridOrder` is still tunable for input. Block 3 only describes Cfast
  because the output kernel is monomorphic on Cfast.
- Dropping `WPT=1 = SP3 behavior` parentheticals — `WPT=1` is implied
  by the default value in the struct definitions.

**Risk:** Comment-only, no build/test impact.

**Commit message:** `Rewrite MLX winograd block comments in present tense`

## Testing

- `./katago runtests` — sanity check, no behavior change expected.
- `./katago runnnlayertests` — sanity check on the layer paths.
- `runMLXWinotunerTests` (called by `runnnlayertests` when the MLX
  backend is built) — exercises the new Test F in
  `runPlanShapeRotationTests()`.

No cross-backend `testgpuerror` re-run needed (no behavior change).
No benchmark re-run needed.

## Out of Scope (Possible follow-ups)

- API surface trim (the 7 `*ForTesting` helpers in `mlxwinotuner.h`).
- File splits (mlxbackend.cpp at 2210L, mlxwinotuner.cpp at 1741L,
  mlxwinograd.h at 473L with substantial inline impl).
- Tuning the adaptive-scoring spec constants
  (`kWorkFractionFloor`/`kRepFloor`/`kMaxShapes`).
- More benchmark samples (current snapshot is 2 samples).
- Marking PR #16 as ready for review.
