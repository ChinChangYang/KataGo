# MLX Backend Comment Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three surgical commits that fix plainly broken comments, strip internal-stage labels (SP1–SP5/Task N) from ~80 historical comment sites while preserving every load-bearing invariant, and rewrite three large block comments in `mlxwinograd.h` into present-tense API docs. Plus one unit-test case closing the `planShapeRotation` rounding-repair coverage gap.

**Architecture:** Comment-only diff except for one ungated unit-test addition and one variable-name change at two sites (unused structured-binding `n` → field-access `p.first`). No header signatures change, no API surface change, no behavior change.

**Tech Stack:** C++17 (MLX backend, AppleClang on Apple Silicon), CMake/Ninja build, KataGo's `testAssert` macro for the unit test.

---

## File Structure

Files modified across the three tasks:

- `cpp/neuralnet/mlxbackend.cpp` (Task 1: none, Task 2: ~30 sites + 2 function renames + 1 comment-reference update, Task 3: none)
- `cpp/neuralnet/mlxwinograd.h` (Task 1: none, Task 2: ~10 single-line sites, Task 3: three block-comment rewrites)
- `cpp/neuralnet/mlxwinotuner.cpp` (Task 1: 4 fixes + 1 new test case, Task 2: ~25 sites including kernel-source comments and test-runner comments, Task 3: none)
- `cpp/neuralnet/mlxwinotuner.h` (Task 1: none, Task 2: 1 site, Task 3: none)

After Task 2 a verification step greps for surviving `\bSP[0-9]+\b|\bTask [0-9]+\b` matches; the only matches allowed afterward are inside test logic that legitimately uses "Task" as a domain word (none expected in current code) or inside the block comments deferred to Task 3.

After Task 3 the verification grep on `mlxwinograd.h` should return zero matches.

---

## Task 1: Fix plainly broken items, close rounding-repair test gap

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (4 in-place comment/binding edits + 1 new test case)

The new test case validates existing behavior (closes a coverage gap, not a behavior change). For the test-addition step we use the modified TDD: add the test, run it, expect PASS on the existing correct implementation; verify the test would catch a regression by mutating the implementation, running, expecting FAIL, then reverting.

### Step 1.1: Read the `runPlanShapeRotationTests` test cases section

Run: `grep -n "Case [A-F]" cpp/neuralnet/mlxwinotuner.cpp`

Expected: lines listing Cases A through E ending around line 1165 (the Case E block). Test F goes after Case E, before the closing `std::cout << "  planShapeRotation OK"` line at 1183.

- [ ] **Step 1.2: Add Test F to runPlanShapeRotationTests**

Open `cpp/neuralnet/mlxwinotuner.cpp` and find the block ending around line 1181:

```cpp
      testAssert(plan[0].measureReps >= plan[1].measureReps);
      testAssert(plan[1].measureReps >= plan[2].measureReps);
    }

    std::cout << "  planShapeRotation OK" << std::endl;
```

Insert a new block between the closing `}` of Case E and the `std::cout` line:

```cpp
    // Case F: 2 shapes with equal work and complementary 0.5 shares —
    // exercises the rounding-repair branch. Input: 200:1, 100:2 (work
    // 200, 200; tied; tie-break by larger C → plan[0]=C=200). Each
    // share is 0.5; lround(0.5*19) = lround(9.5) = 10 each (lround
    // rounds halves away from zero); pre-repair sum = 20; repair:
    // dominant absorbs delta = 19 - 20 = -1; final (9, 10). Both
    // measureReps stay ≥ kRepFloor=3 so floor-bump is a no-op.
    {
      auto plan = MLXWinogradTuner::planShapeRotationForTesting(
          {{200, 1}, {100, 2}});
      testAssert(plan.size() == 2);
      testAssert(plan[0].channels == 200);
      testAssert(plan[1].channels == 100);
      testAssert(plan[0].measureReps + plan[1].measureReps == 19);
      testAssert(plan[0].measureReps == 9);
      testAssert(plan[1].measureReps == 10);
      testAssert(plan[0].measureReps >= 3);
      testAssert(plan[1].measureReps >= 3);
    }
```

- [ ] **Step 1.3: Build and run the test, verify it passes**

Run from `cpp/`:
```bash
cmake -G Ninja -DUSE_BACKEND=MLX && ninja
./katago runnnlayertests 2>&1 | grep -A1 "planShapeRotation"
```
Expected: `  planShapeRotation OK` (Test F asserts succeed silently; the OK line follows the loop).

- [ ] **Step 1.4: Verify the test catches a regression (mutation check)**

Temporarily mutate `mlxwinotuner.cpp:533` from
```cpp
  plan[0].measureReps += (kMeasureReps - sum);
```
to
```cpp
  plan[0].measureReps += 0;  // mutation: skip rounding repair
```
Rebuild and rerun:
```bash
ninja && ./katago runnnlayertests 2>&1 | grep -E "FAIL|planShapeRotation"
```
Expected: `testAssert` failure inside Test F (sum 9+10 should equal 19 but mutation breaks it to ≠19 because lround sum was 20 with no repair; one of the measureReps assertions also fails). **Revert the mutation immediately:**
```cpp
  plan[0].measureReps += (kMeasureReps - sum);
```
Rebuild, rerun, confirm Test F passes again.

- [ ] **Step 1.5: Fix the stale "Step 4.2" comment**

In `cpp/neuralnet/mlxwinotuner.cpp` find:
```cpp
    // Empty input → empty histograms (no assert; this is just the pure
    // core. The mlxbackend.cpp call site asserts non-empty after a real
    // model walk; see Step 4.2 comment).
```
Replace with:
```cpp
    // Empty input → empty histograms (no assert; this is just the pure
    // core. The mlxbackend.cpp call site asserts non-empty after a real
    // model walk; mlxbackend.cpp pre-computes the histogram at model
    // load and stores it on ModelInfoForTuning so the tuner does not
    // re-walk the descriptor).
```

- [ ] **Step 1.6: Fix unused structured-binding `n` at line 727**

In `cpp/neuralnet/mlxwinotuner.cpp` find:
```cpp
  for(const auto& [ch, n] : mi.conv3x3InputHistogram) C = std::max(C, ch);
```
Replace with:
```cpp
  for(const auto& p : mi.conv3x3InputHistogram) C = std::max(C, p.first);
```

- [ ] **Step 1.7: Fix unused structured-binding `n` at line 809**

In `cpp/neuralnet/mlxwinotuner.cpp` find:
```cpp
  for(const auto& [ch, n] : mi.conv3x3OutputHistogram) outC = std::max(outC, ch);
```
Replace with:
```cpp
  for(const auto& p : mi.conv3x3OutputHistogram) outC = std::max(outC, p.first);
```

- [ ] **Step 1.8: Add missing warmup comment to scoreInputTransformPerShape**

In `cpp/neuralnet/mlxwinotuner.cpp` find (around lines 567-569 inside `scoreInputTransformPerShape`):
```cpp
    seed = seed * 1664525u + 1013904223u;
  }
  (void)timeOneInputTransform(cfg, inputs[0], plan[0].channels, useFP16);
```
Replace with:
```cpp
    seed = seed * 1664525u + 1013904223u;
  }

  // Warmup: 1 rep on dominant, discarded.
  (void)timeOneInputTransform(cfg, inputs[0], plan[0].channels, useFP16);
```

- [ ] **Step 1.9: Add missing warmup comment to scoreOutputUntransformPerShape**

In `cpp/neuralnet/mlxwinotuner.cpp` find (around lines 606-609 inside `scoreOutputUntransformPerShape`):
```cpp
    seed = seed * 1664525u + 1013904223u;
  }
  (void)timeOneOutputUntransform(cfg, matmulOuts[0], N, H, W,
                                 plan[0].channels, useFP16);
```
Replace with:
```cpp
    seed = seed * 1664525u + 1013904223u;
  }

  // Warmup: 1 rep on dominant, discarded.
  (void)timeOneOutputUntransform(cfg, matmulOuts[0], N, H, W,
                                 plan[0].channels, useFP16);
```

- [ ] **Step 1.10: Rebuild and run full layer tests**

```bash
ninja && ./katago runnnlayertests 2>&1 | tail -20
```
Expected: ends with `All MLX winograd tuner tests PASSED` (or equivalent — match existing tail).

- [ ] **Step 1.11: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.cpp
git commit -m "$(cat <<'EOF'
Fix stale comments and close rounding-repair test gap

Four cleanup items in mlxwinotuner.cpp:

1. Replace the dangling "see Step 4.2 comment" pointer (no such
   anchor exists) with a present-tense description of the
   mlxbackend.cpp histogram pre-computation.

2. Rewrite the two `for(const auto& [ch, n] : ...)` loops to use
   `for(const auto& p : ...) ... p.first` since `n` was unused and
   `[[maybe_unused]]` on structured bindings is not portable
   across older clangs.

3. Add the missing `// Warmup: 1 rep on dominant, discarded.`
   comment to scoreInputTransformPerShape and
   scoreOutputUntransformPerShape, matching the placement on
   their score-function siblings.

4. Add Test F to runPlanShapeRotationTests covering the
   `Σ lround(weight_i * 19) ≠ 19` rounding-repair branch — the
   existing tests A–E all happen to land on 19 exactly. The
   {(200,1), (100,2)} histogram has tied work tie-broken by C,
   each share is 0.5 → lround(9.5) = 10 each → pre-repair sum
   20 → dominant absorbs -1 → final (9, 10).

Comment-only except for the test addition; behavior unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: De-tag SP/Task historical references

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp` (~30 sites + 2 function renames + 1 declaration-comment update)
- Modify: `cpp/neuralnet/mlxwinograd.h` (~10 single-line sites; block comments deferred to Task 3)
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (~25 sites: kernel-source headers, scoring-function comments, test-runner comments, log strings)
- Modify: `cpp/neuralnet/mlxwinotuner.h` (1 site)

**Principle (from spec):**
1. Keep the invariant the comment documents; drop the stage label.
2. Pure-history comments (no surviving invariant) get deleted.
3. Test-comment SP/Task tags are stage labels; the test's purpose statement is the invariant — keep the purpose, strip the tag.
4. Specific engineering rationale (e.g. "(empirical sensitivity sweep showed <1% delta)") survives.
5. Block comments at `mlxwinograd.h:12-15`, `:161-171`, `:291-302` are deferred to Task 3.

Each step below is a single `Edit` call. Group ordering: file by file, top-down within each file (so later line numbers stay valid as earlier edits don't shift lines — single-line in-place replacements preserve line counts).

### Sub-task 2A: `cpp/neuralnet/mlxbackend.cpp` — production code

- [ ] **Step 2A.1: Edit mlxbackend.cpp:9 (header comment)**

Find:
```cpp
 * `mlxUseFP16 = auto` resolves to fp16 after SP3 acceptance lands.
```
Replace with:
```cpp
 * `mlxUseFP16 = auto` resolves to fp16.
```

- [ ] **Step 2A.2: Edit mlxbackend.cpp:35 (declaration comment, anticipates 2A.18-19 renames)**

Find:
```cpp
// Test-only free functions. runMLXWinogradTests is defined at the bottom of
// this file (alongside runMLXBatchNormFP16Test_SP3 / runMLXConvLayerFP16WinogradTest_SP3).
```
Replace with:
```cpp
// Test-only free functions. runMLXWinogradTests is defined at the bottom of
// this file (alongside runMLXBatchNormFP16Test / runMLXConvLayerFP16WinogradTest).
```

- [ ] **Step 2A.3: Edit mlxbackend.cpp:167**

Find:
```cpp
// Tuner is on by default; KATAGO_MLX_WINOTUNER=0 forces baked SP1 defaults.
```
Replace with:
```cpp
// Tuner is on by default; KATAGO_MLX_WINOTUNER=0 forces baked defaults.
```

- [ ] **Step 2A.4: Edit mlxbackend.cpp:231**

Find:
```cpp
      // SP3: `!useFP16` gate removed — Winograd path now runs in fp16 too.
```
Replace with:
```cpp
      // Winograd path runs in fp16 too (no `!useFP16` gate).
```

- [ ] **Step 2A.5: Edit mlxbackend.cpp:268-269**

Find:
```cpp
  mx::array mergedScale; // Shape: [C], always fp32 (SP3)
  mx::array mergedBias;  // Shape: [C], always fp32 (SP3)
```
Replace with:
```cpp
  mx::array mergedScale; // Shape: [C], always fp32
  mx::array mergedBias;  // Shape: [C], always fp32
```

- [ ] **Step 2A.6: Edit mlxbackend.cpp:275**

Find:
```cpp
  // SP3: mergedScale/mergedBias storage is always fp32 to preserve dynamic
  // range across the 25-block-deep b18c384 chain. The `useFP16` parameter
  // is intentionally ignored. See spec §3 item 4.
```
Replace with:
```cpp
  // mergedScale/mergedBias storage is always fp32 to preserve dynamic
  // range across the 25-block-deep b18c384 chain. The `useFP16` parameter
  // is intentionally ignored.
```

- [ ] **Step 2A.7: Edit mlxbackend.cpp:991**

Find:
```cpp
    // SP3: This raw-output path memcpys policy.data<float>() etc. into the
```
Replace with:
```cpp
    // This raw-output path memcpys policy.data<float>() etc. into the
```

- [ ] **Step 2A.8: Edit mlxbackend.cpp:1189-1191**

Find:
```cpp
    // Determine tuner params: either run the autotuner, or use baked SP1 defaults.
    // SP3: tuner runs at every precision so fp16 gets its own cache file
    // (_fp16.txt suffix). See spec §3 item 3.
```
Replace with:
```cpp
    // Determine tuner params: either run the autotuner, or use baked defaults.
    // Tuner runs at every precision so fp16 gets its own cache file
    // (_fp16.txt suffix).
```

- [ ] **Step 2A.9: Edit mlxbackend.cpp:1382-1386**

Find:
```cpp
  // SP3: Auto resolves to fp16 (gated on acceptance: MLX-fp16 paired-t beat
  // both Metal-fp16 and MLX-fp32 with non-overlapping CIs, and testgpuerror
  // accuracy exit=0). Users who need bit-for-bit fp32 reproducibility set
  // `mlxUseFP16 = false` explicitly. See the traceability commit for the
  // exact gate numbers.
```
Replace with:
```cpp
  // Auto resolves to fp16. The original acceptance gate (MLX-fp16 paired-t
  // beat both Metal-fp16 and MLX-fp32 with non-overlapping CIs, and
  // testgpuerror accuracy exit=0) is preserved in the traceability commit.
  // Users who need bit-for-bit fp32 reproducibility set `mlxUseFP16 = false`
  // explicitly.
```

### Sub-task 2B: `cpp/neuralnet/mlxbackend.cpp` — test runners

- [ ] **Step 2B.1: Rename runMLXBatchNormFP16Test_SP3 (definition at line 1734-1737)**

Find:
```cpp
// SP3 Task 2: directly-asserting unit test for BatchNormLayer fp16 mode.
// Declared here because BatchNormLayer is not in any public header.
// Called from runMLXWinogradTests() (same TU).
void runMLXBatchNormFP16Test_SP3() {
```
Replace with:
```cpp
// Directly-asserting unit test for BatchNormLayer fp16 mode.
// Declared here because BatchNormLayer is not in any public header.
// Called from runMLXWinogradTests() (same TU).
void runMLXBatchNormFP16Test() {
```

- [ ] **Step 2B.2: Rename runMLXConvLayerFP16WinogradTest_SP3 (definition at line 1771-1774)**

Find:
```cpp
// SP3 Task 3: directly-asserting unit test for ConvLayer fp16 Winograd path.
// Declared here because ConvLayer is not in any public header.
// Called from runMLXWinogradTests() (same TU).
void runMLXConvLayerFP16WinogradTest_SP3() {
```
Replace with:
```cpp
// Directly-asserting unit test for ConvLayer fp16 Winograd path.
// Declared here because ConvLayer is not in any public header.
// Called from runMLXWinogradTests() (same TU).
void runMLXConvLayerFP16WinogradTest() {
```

- [ ] **Step 2B.3: Strip SP3 comment inside ConvLayerFP16WinogradTest at line 1799**

Find:
```cpp
  testAssert(conv.useWinograd);  // SP3 gate dropped: fp16 still picks Winograd
```
Replace with:
```cpp
  testAssert(conv.useWinograd);  // fp16 still picks Winograd
```

- [ ] **Step 2B.4: Edit comment inside runMLXWinogradTests at line 1851**

Find:
```cpp
  // GPU Winograd metal_kernel validated against the Task 1 CPU oracle.
```
Replace with:
```cpp
  // GPU Winograd metal_kernel validated against the CPU oracle.
```

- [ ] **Step 2B.5: Update call sites at lines 1904-1905**

Find:
```cpp
  runMLXBatchNormFP16Test_SP3();
  runMLXConvLayerFP16WinogradTest_SP3();
```
Replace with:
```cpp
  runMLXBatchNormFP16Test();
  runMLXConvLayerFP16WinogradTest();
```

- [ ] **Step 2B.6: Edit mlxbackend.cpp:1907**

Find:
```cpp
  // SP4 Task 2 / SP5 Task 5: smoke test — verify Winograd plumbing.
```
Replace with:
```cpp
  // Smoke test — verify Winograd plumbing.
```

- [ ] **Step 2B.7: Edit mlxbackend.cpp:1938**

Find:
```cpp
  // SP4 Task 3: WPT=1, 4, 8 must produce bit-identical output (fp32).
```
Replace with:
```cpp
  // WPT=1, 4, 8 must produce bit-identical output (fp32).
```

- [ ] **Step 2B.8: Edit mlxbackend.cpp:1984**

Find:
```cpp
  // SP4 Task 3 tail-guard coverage: Ntiles=100 (N=1, H=W=19) is NOT
```
Replace with:
```cpp
  // Tail-guard coverage: Ntiles=100 (N=1, H=W=19) is NOT
```

- [ ] **Step 2B.9: Edit mlxbackend.cpp:2022-2024**

Find:
```cpp
  // SP4 Task 4 / SP5 Task 3: input VW=1, 2, 4 must produce bit-identical fp16
  // output (Cfast). C=64 is divisible by 4 — VW=4 valid. Output VW removed in
  // SP5 Task 3 (output kernel is VW=1 monomorphic).
```
Replace with:
```cpp
  // Input VW=1, 2, 4 must produce bit-identical fp16 output (Cfast). C=64
  // is divisible by 4 — VW=4 valid. Output VW is gone (kernel is VW=1
  // monomorphic).
```

- [ ] **Step 2B.10: Edit mlxbackend.cpp:2066-2070**

Find:
```cpp
  // SP4 Task 5 / SP5 Task 4: input-stage GridOrder::Cfast and GridOrder::Tfast
  // must produce bit-identical fp32 output. They differ only in which thread
  // does which (c, tileIdx) pair; the on-disk layout is unchanged. The output
  // kernel is Cfast-monomorphic after SP5 Task 4, so only the input gridOrder
  // is varied here.
```
Replace with:
```cpp
  // Input-stage GridOrder::Cfast and GridOrder::Tfast must produce
  // bit-identical fp32 output. They differ only in which thread does which
  // (c, tileIdx) pair; the on-disk layout is unchanged. The output kernel
  // is Cfast-monomorphic, so only the input gridOrder is varied here.
```

- [ ] **Step 2B.11: Edit mlxbackend.cpp:2106**

Find:
```cpp
  // SP4 Task 5 / SP5 Task 4 tail-guard coverage: input Tfast with C=67 (not
```
Replace with:
```cpp
  // Tail-guard coverage: input Tfast with C=67 (not
```

- [ ] **Step 2B.12: Delete pure-history comment at mlxbackend.cpp:2143-2145**

Find:
```cpp
  // SP5 Task 5: matmulOrient axis removed end-to-end. The Std-vs-Tpd
  // equivalence tests and the Tfast×Tpd combined-branching test have been
  // deleted along with the enum.

```
Replace with:
```cpp

```
(The whole comment is pure history pointing at deleted code — no surviving invariant.)

- [ ] **Step 2B.13: Edit mlxbackend.cpp:2148**

Find:
```cpp
    // SP5 Task 9 — Output kernel is monomorphic on VW=1, GRID_ORDER=Cfast.
```
Replace with:
```cpp
    // Output kernel is monomorphic on VW=1, GRID_ORDER=Cfast.
```

- [ ] **Step 2B.14: Edit mlxbackend.cpp:2168-2169**

Find:
```cpp
    // makeWinogradWeights takes raw [Cout, Cin, 3, 3] flattened and produces
    // the transformed [16, Cin, Cout] tensor (Std-only after Task 5).
```
Replace with:
```cpp
    // makeWinogradWeights takes raw [Cout, Cin, 3, 3] flattened and produces
    // the transformed [16, Cin, Cout] tensor (Std-only).
```

- [ ] **Step 2B.15: Edit mlxbackend.cpp:2172**

Find:
```cpp
    // Output config: Std post-SP5 OutputUntransform has tg0/tg1/wpt only.
```
Replace with:
```cpp
    // Output config: Std OutputUntransform has tg0/tg1/wpt only.
```

### Sub-task 2C: `cpp/neuralnet/mlxwinograd.h` — single-line edits

(Block comments at lines 12-15, 161-171, 291-302 are deferred to Task 3.)

- [ ] **Step 2C.1: Edit mlxwinograd.h:134**

Find:
```cpp
// SP5 Task 5: matmulOrient axis removed; only the Std layout remains.
```
Replace with:
```cpp
// Output layout: Std only.
```

- [ ] **Step 2C.2: Edit mlxwinograd.h:229**

Find:
```cpp
            // outp [16, Ntiles, C] — C is the fast axis. (SP5 Task 5: Std only.)
```
Replace with:
```cpp
            // outp [16, Ntiles, C] — C is the fast axis.
```

- [ ] **Step 2C.3: Edit mlxwinograd.h:280**

Find:
```cpp
          // outp [16, Ntiles, C] — C is the fast axis. (SP5 Task 5: Std only.)
```
Replace with:
```cpp
          // outp [16, Ntiles, C] — C is the fast axis.
```

- [ ] **Step 2C.4: Edit mlxwinograd.h:306**

Find:
```cpp
    // m shape [16, Ntiles, outC] — Ntiles=m_shape[1], outC=m_shape[2] (SP5 Task 5: Std only.)
```
Replace with:
```cpp
    // m shape [16, Ntiles, outC] — Ntiles=m_shape[1], outC=m_shape[2].
```

- [ ] **Step 2C.5: Edit mlxwinograd.h:335**

Find:
```cpp
            // m shape [16, Ntiles, outC] (SP5 Task 5: Std only.)
```
Replace with:
```cpp
            // m shape [16, Ntiles, outC].
```

- [ ] **Step 2C.6: Delete pure-history comment at mlxwinograd.h:379**

Find:
```cpp
  // SP5 Task 5: matmulOrient axis removed; no _o suffix needed.
```
Replace with: (delete the entire line)

Use the Edit tool with old_string set to the full line including the trailing newline so the line is removed, e.g.:
```
old_string: "  // SP5 Task 5: matmulOrient axis removed; no _o suffix needed.\n"
new_string: ""
```

- [ ] **Step 2C.7: Edit mlxwinograd.h:386-387**

Find:
```cpp
  // Output kernel is monomorphic on VW=1 (SP5 Task 3), GRID_ORDER=Cfast
  // (SP5 Task 4), and MATMUL_ORIENT=Std (SP5 Task 5).
```
Replace with:
```cpp
  // Output kernel is monomorphic on VW=1, GRID_ORDER=Cfast,
  // and MATMUL_ORIENT=Std.
```

- [ ] **Step 2C.8: Edit mlxwinograd.h:410**

Find:
```cpp
  // Stage 1: input transform. Output shape: [16, Ntiles, C] (SP5 Task 5: Std only.)
```
Replace with:
```cpp
  // Stage 1: input transform. Output shape: [16, Ntiles, C].
```

- [ ] **Step 2C.9: Edit mlxwinograd.h:439**

Find:
```cpp
  // Stage 2: matmul. [16,Ntiles,C] @ [16,C,Cout] -> [16,Ntiles,Cout] (SP5 Task 5: Std only.)
```
Replace with:
```cpp
  // Stage 2: matmul. [16,Ntiles,C] @ [16,C,Cout] -> [16,Ntiles,Cout].
```

- [ ] **Step 2C.10: Edit mlxwinograd.h:445-446**

Find:
```cpp
  // Output kernel is VW=1 monomorphic (SP5 Task 3) and Cfast monomorphic
  // (SP5 Task 4). Grid x = Cout, grid y = ceil(Ntiles / WPT).
```
Replace with:
```cpp
  // Output kernel is VW=1 monomorphic and Cfast monomorphic.
  // Grid x = Cout, grid y = ceil(Ntiles / WPT).
```

### Sub-task 2D: `cpp/neuralnet/mlxwinotuner.cpp` — production code

- [ ] **Step 2D.1: Edit mlxwinotuner.cpp:77-80 (4-line block at top)**

Find:
```cpp
  // SP4: Tfast (GRID_ORDER=1) requires VW=1 in the kernels. Reject any
  // input candidate that violates this — surfaces the constraint earlier
  // than the Metal JIT static_assert. (SP5 Task 3: output VW is gone.
  // SP5 Task 6: global gridOrder is gone; input gridOrder stands alone.)
```
Replace with:
```cpp
  // Tfast (GRID_ORDER=1) requires VW=1 in the kernels. Reject any input
  // candidate that violates this — surfaces the constraint earlier than
  // the Metal JIT static_assert. (Output VW is gone; global gridOrder
  // is gone; input gridOrder stands alone.)
```

- [ ] **Step 2D.2: Edit mlxwinotuner.cpp:168**

Find:
```cpp
// SP5 Task 5: matmulOrient axis removed — input kernel always writes Std layout.
```
Replace with:
```cpp
// Input kernel always writes Std layout (matmulOrient axis is gone).
```

- [ ] **Step 2D.3: Edit mlxwinotuner.cpp:197**

Find:
```cpp
  // Output shape: [16, Ntiles, C] (SP5 Task 5: Std only.)
```
Replace with:
```cpp
  // Output shape: [16, Ntiles, C] (Std only).
```

- [ ] **Step 2D.4: Edit mlxwinotuner.cpp:250**

Find:
```cpp
// SP5 Task 5: matmulOrient axis removed — m is always Std-layout ([16, Ntiles, outC]).
```
Replace with:
```cpp
// m is always Std-layout ([16, Ntiles, outC]).
```

- [ ] **Step 2D.5: Edit mlxwinotuner.cpp:264-267 (kernelName block)**

Find:
```cpp
  // Kernel name encodes the still-live axes so the Metal JIT cache sees a
  // unique entry per (dtype, wpt) combination. (SP5 Task 3: VW dropped.
  // SP5 Task 4: GRID_ORDER dropped — output kernel is Cfast-only.
  // SP5 Task 5: MATMUL_ORIENT dropped — output kernel is Std-only.)
```
Replace with:
```cpp
  // Kernel name encodes the still-live axes so the Metal JIT cache sees a
  // unique entry per (dtype, wpt) combination. (Output kernel is VW=1
  // monomorphic, Cfast monomorphic, and Std-only.)
```

- [ ] **Step 2D.6: Edit mlxwinotuner.cpp:648**

Find:
```cpp
  // SP3 non-full inconsistency (skipped 8) is fixed here.
```
Replace with:
```cpp
  // Symmetric with full set (the 8 entry is preserved in non-full).
```

- [ ] **Step 2D.7: Edit mlxwinotuner.cpp:654-655**

Find:
```cpp
// New axes from SP4. After SP5: wptValues() is used by both stages;
// vwValues() is input-only (output kernel is VW=1 monomorphic).
```
Replace with:
```cpp
// wptValues() is used by both stages; vwValues() is input-only
// (output kernel is VW=1 monomorphic).
```

- [ ] **Step 2D.8: Edit mlxwinotuner.cpp:680-682 (2-line block)**

Find:
```cpp
// SP5 Task 3: output kernel is VW=1 monomorphic — no vw parameter, no
// vw-divisibility check on outC.
// SP5 Task 4: output kernel is Cfast monomorphic — no gridOrder parameter.
```
Replace with:
```cpp
// Output kernel is VW=1 monomorphic — no vw parameter, no
// vw-divisibility check on outC. Output kernel is also Cfast monomorphic
// — no gridOrder parameter.
```

- [ ] **Step 2D.9: Edit mlxwinotuner.cpp:715**

Find:
```cpp
// Replaces SP4's Joint-A/B/refine cascade. Returns the best (lowest-time)
```
Replace with:
```cpp
// Returns the best (lowest-time)
```

- [ ] **Step 2D.10: Edit mlxwinotuner.cpp:733-737 (5-line block)**

Find:
```cpp
  // Score the SP1 baked default (default-constructed = {tg0=32, tg1=1, wpt=1,
  // vw=1, gridOrder=Cfast}) so the sweep log carries a baseline the operator
  // can compare the winner against. Always adopted-winner; no fallback.
  // SP1 defaults satisfy isInputCandidateValid for any (C, Ntiles) because
  // vw=1 divides every channel count; see mlxwinograd.h for the struct defaults.
```
Replace with:
```cpp
  // Score the baked default (default-constructed = {tg0=32, tg1=1, wpt=1,
  // vw=1, gridOrder=Cfast}) so the sweep log carries a baseline the operator
  // can compare the winner against. Always adopted-winner; no fallback.
  // The defaults satisfy isInputCandidateValid for any (C, Ntiles) because
  // vw=1 divides every channel count; see mlxwinograd.h for the struct defaults.
```

- [ ] **Step 2D.11: Edit mlxwinotuner.cpp:745-748 (4-line block)**

Find:
```cpp
  // SP5 Task 4: the output gridOrder check in isValid() is gone (output kernel
  // is Cfast-monomorphic), so the input gridOrder axis can again be searched
  // over both Cfast and Tfast. SP5 Task 6: the global gridOrder field is also
  // gone — input gridOrder stands alone, no cross-stage consistency to enforce.
```
Replace with:
```cpp
  // The output gridOrder check in isValid() is gone (output kernel is
  // Cfast-monomorphic), so the input gridOrder axis can be searched over
  // both Cfast and Tfast. The global gridOrder field is also gone —
  // input gridOrder stands alone, no cross-stage consistency to enforce.
```

- [ ] **Step 2D.12: Edit mlxwinotuner.cpp:797-799 (3-line block)**

Find:
```cpp
// Flat sweep over (tg0, tg1, wpt) for the output untransform. Output VW
// and gridOrder are not searched: the kernel is monomorphic on VW=1 (SP5
// Task 3) and Cfast (SP5 Task 4).
```
Replace with:
```cpp
// Flat sweep over (tg0, tg1, wpt) for the output untransform. Output VW
// and gridOrder are not searched: the kernel is monomorphic on VW=1 and
// Cfast.
```

- [ ] **Step 2D.13: Edit mlxwinotuner.cpp:813-815 (3-line block)**

Find:
```cpp
  // Score the SP1 baked default (default-constructed = {tg0=32, tg1=1, wpt=1})
  // so the sweep log carries a baseline the operator can compare the winner
  // against. Symmetric to flatSweepInput.
```
Replace with:
```cpp
  // Score the baked default (default-constructed = {tg0=32, tg1=1, wpt=1})
  // so the sweep log carries a baseline the operator can compare the winner
  // against. Symmetric to flatSweepInput.
```

- [ ] **Step 2D.14: Edit mlxwinotuner.cpp:823-824**

Find:
```cpp
  // Output kernel is VW=1 monomorphic (SP5 Task 3) and Cfast monomorphic
  // (SP5 Task 4), so neither VW nor gridOrder is searched here.
```
Replace with:
```cpp
  // Output kernel is VW=1 monomorphic and Cfast monomorphic, so neither
  // VW nor gridOrder is searched here.
```

- [ ] **Step 2D.15: Edit mlxwinotuner.cpp:917**

Find:
```cpp
  // SP5 Task 6: global gridOrder is deleted; input gridOrder stands alone.
```
Replace with:
```cpp
  // Global gridOrder is deleted; input gridOrder stands alone.
```

### Sub-task 2E: `cpp/neuralnet/mlxwinotuner.cpp` — test runners

- [ ] **Step 2E.1: Edit mlxwinotuner.cpp:1253**

Find:
```cpp
    // SP5 Task 8 — v3 roundtrip: write -> load -> compare all 8 fields. Two
```
Replace with:
```cpp
    // v3 roundtrip: write -> load -> compare all 8 fields. Two
```

- [ ] **Step 2E.2: Edit mlxwinotuner.cpp:1286**

Find:
```cpp
  // SP3 Task 4: dtype-aware cache filenames must coexist in the same directory
```
Replace with:
```cpp
  // dtype-aware cache filenames must coexist in the same directory
```

- [ ] **Step 2E.3: Edit mlxwinotuner.cpp:1317**

Find:
```cpp
    // SP5 Task 8 — v3 isValid invariants.
```
Replace with:
```cpp
    // v3 isValid invariants.
```

- [ ] **Step 2E.4: Edit mlxwinotuner.cpp:1357**

Find:
```cpp
  // SP4 Task 7: candidate enumeration expanded with validity filtering.
```
Replace with:
```cpp
  // Candidate enumeration with validity filtering.
```

- [ ] **Step 2E.5: Edit mlxwinotuner.cpp:1390-1391**

Find:
```cpp
    // Output side: same shape of assertions. (SP5 Task 4: gridOrder param
    // dropped from buildOutputCandidatesForTesting — output is Cfast-only.)
```
Replace with:
```cpp
    // Output side: same shape of assertions. (gridOrder is not a parameter
    // of buildOutputCandidatesForTesting — output is Cfast-only.)
```

- [ ] **Step 2E.6: Edit mlxwinotuner.cpp:1398 (cout string — drop "Task 7")**

Find:
```cpp
    std::cout << "  MLX Winograd Task 7 candidate enumeration validity passed ("
```
Replace with:
```cpp
    std::cout << "  MLX Winograd candidate enumeration validity passed ("
```

- [ ] **Step 2E.7: Edit mlxwinotuner.cpp:1404-1408 (5-line block)**

Find:
```cpp
  // ---- Measurement primitives return finite positive times ----
  // We can't call the static helpers from the test, so we use the public
  // surface that will be wired in Task 4: loadOrAutoTune with reTune=true
  // would run the search; for Task-3 scope we just verify the public
  // schema struct works with valid configs. The measurement primitive itself
  // is exercised by the search-works test added in Task 4.
```
Replace with:
```cpp
  // ---- Measurement primitives return finite positive times ----
  // We can't call the static helpers from the test, so we use the public
  // surface: loadOrAutoTune with reTune=true runs the search and we verify
  // that the public schema struct works with valid configs. The measurement
  // primitive itself is exercised by the search-works test below.
```

- [ ] **Step 2E.8: Edit mlxwinotuner.cpp:1411-1414 (4-line block)**

Find:
```cpp
    // SP5 Task 10 — Gated flat-sweep convergence test.
    // Runs the production flat sweep on a small synthetic problem and asserts
    // that the winner is isValid and that its timing is no worse than the
    // SP1 baked default (tg0=32, tg1=1, wpt=1, vw=1, Cfast).
```
Replace with:
```cpp
    // Gated flat-sweep convergence test.
    // Runs the production flat sweep on a small synthetic problem and asserts
    // that the winner is isValid and that its timing is no worse than the
    // baked default (tg0=32, tg1=1, wpt=1, vw=1, Cfast).
```

- [ ] **Step 2E.9: Edit mlxwinotuner.cpp:1460 (cout string — drop "SP5")**

Find:
```cpp
      std::cout << "  SP5 flat-sweep convergence (gated) OK"
```
Replace with:
```cpp
      std::cout << "  flat-sweep convergence (gated) OK"
```

- [ ] **Step 2E.10: Edit mlxwinotuner.cpp:1538**

Find:
```cpp
    // Reuses the KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST gate so users who
    // opt into the SP5 Task 10 sweep cost also get this check. Note
```
Replace with:
```cpp
    // Reuses the KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST gate so users who
    // opt into the sweep-convergence cost also get this check. Note
```

- [ ] **Step 2E.11: Edit mlxwinotuner.cpp:1620 (the "Task 2 / gate" reference)**

Find:
```cpp
    // are format-checked by the log-format test (Task 2 / gate
```
Replace with:
```cpp
    // are format-checked by the log-format test (gate
```

### Sub-task 2F: `cpp/neuralnet/mlxwinotuner.h`

- [ ] **Step 2F.1: Edit mlxwinotuner.h:21**

Find:
```cpp
  // companion after SP5 Task 6; output kernel is Cfast-monomorphic after Task 4).
```
Replace with:
```cpp
  // companion; output kernel is Cfast-monomorphic).
```

### Sub-task 2G: Verify, build, test, commit

- [ ] **Step 2G.1: Grep for residual SP/Task tags in non-block-comment regions**

Run from repo root:
```bash
grep -nE "\bSP[0-9]+\b|\bTask [0-9]+\b" cpp/neuralnet/mlx*.{cpp,h}
```
Expected output: only the block comments at `mlxwinograd.h:12-15`, `:161-171`, `:291-302` remain. Every other line should be gone.

If anything else surfaces, edit it following the spec principle (keep invariant, drop tag, or delete pure-history) before continuing.

- [ ] **Step 2G.2: Rebuild**

```bash
cd cpp && ninja
```
Expected: clean build (comment-only diff plus two function renames whose call sites were updated; no compile errors).

- [ ] **Step 2G.3: Run unit tests**

```bash
./katago runnnlayertests 2>&1 | tail -20
```
Expected: same pass output as baseline. No new failures from the function-rename ripple.

- [ ] **Step 2G.4: Commit**

```bash
git add cpp/neuralnet/mlxbackend.cpp cpp/neuralnet/mlxwinograd.h \
        cpp/neuralnet/mlxwinotuner.cpp cpp/neuralnet/mlxwinotuner.h
git commit -m "$(cat <<'EOF'
De-tag historical SP/Task references in MLX comments

Strips internal-stage labels (SP1-SP5, Task N) from ~80 comment sites
across the four MLX backend files, plus two function renames whose
suffix carried the SP3 stage label:

  runMLXBatchNormFP16Test_SP3        -> runMLXBatchNormFP16Test
  runMLXConvLayerFP16WinogradTest_SP3 -> runMLXConvLayerFP16WinogradTest

Principle: keep the invariant the comment was documenting; drop the
stage label that names *when* the invariant became true. Pure-history
comments (e.g. "SP5 Task 5: matmulOrient axis removed end-to-end. ...
have been deleted along with the enum.") that point at code that is
already gone are deleted entirely. Specific engineering rationale
(e.g. "empirical sensitivity sweep showed <1% delta") is preserved.

Two cout log strings updated to match:
  "MLX Winograd Task 7 candidate enumeration validity passed"
    -> "MLX Winograd candidate enumeration validity passed"
  "SP5 flat-sweep convergence (gated) OK"
    -> "flat-sweep convergence (gated) OK"

The three large block comments at mlxwinograd.h:12-15, :161-171,
:291-302 are deferred to the next commit (they need full rewrite into
present-tense API docs, not in-place de-tag).

Comment-only diff plus function renames (no behavior change).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Rewrite historical block comments in mlxwinograd.h

**Files:**
- Modify: `cpp/neuralnet/mlxwinograd.h` (three block-comment rewrites)

Three block sites that were too dense for the in-place de-tag pattern of Task 2 because they describe what each tunable knob *is* in terms of when it was added or removed.

### Sub-task 3A: Block 1 — struct preamble (lines 12-15)

- [ ] **Step 3A.1: Rewrite the struct preamble comment**

In `cpp/neuralnet/mlxwinograd.h` find:
```cpp
// Per-stage launch-geometry configs. SP2 tunes (tg0, tg1); SP4 adds
// (wpt, vw, gridOrder). SP5 removed output vw (Task 3), output gridOrder
// (Task 4), and global matmulOrient (Task 5) — matmul orientation is now
// monomorphic on Std; output kernel is monomorphic on VW=1 and Cfast.
struct InputTransform {
```
Replace with:
```cpp
// Per-stage launch-geometry configs. Input transform exposes
// (tg0, tg1, wpt, vw, gridOrder); output untransform exposes (tg0, tg1, wpt).
// The output kernel is monomorphic on VW=1, GRID_ORDER=Cfast, and the
// matmul layout is monomorphic on Std for both stages.
struct InputTransform {
```

### Sub-task 3B: Block 2 — input kernel header (lines 161-171)

- [ ] **Step 3B.1: Rewrite the input kernel header comment**

In `cpp/neuralnet/mlxwinograd.h` find:
```cpp
// F(2,3) input transform kernel: NHWC T input -> [16, Ntiles, C] T output.
// SP5 Task 5: MATMUL_ORIENT template arg removed — output layout is monomorphic
// on Std ([16, Ntiles, C]).
// Template args (JIT-substituted via MLX template_args):
//   T              — float or half (precision)
//   WPT            — tiles per thread (Tasks 3+; 1 = SP3 behavior)
//   VW             — vector width for packed loads (Tasks 4+; 1 = SP3)
//   GRID_ORDER     — 0=Cfast (C is fast axis), 1=Tfast (Ntiles fast) (Task 5+)
// Grid:
//   Cfast: (ceil(C/VW), ceil(Ntiles/WPT), 1)
//   Tfast: (Ntiles,     ceil(C/WPT),      1)
```
Replace with:
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

### Sub-task 3C: Block 3 — output kernel header (lines 291-302)

- [ ] **Step 3C.1: Rewrite the output kernel header comment**

In `cpp/neuralnet/mlxwinograd.h` find:
```cpp
// F(2,3) output untransform kernel: [16, Ntiles, outC] T input -> NHWC T output.
// Template args (JIT-substituted via MLX template_args):
//   T              — float or half (precision)
//   WPT            — tiles per thread (Tasks 3+; 1 = SP3 behavior)
// Grid (Cfast-only after SP5 Task 4): (Cout, ceil(Ntiles/WPT), 1)
// nhwc input array carries the [N,H,W,outC] dims because metal_kernel only
// exposes *_shape for inputs, not outputs.
// SP5 Task 3: VW template arg dropped — output kernel is monomorphic on VW=1.
// SP5 Task 4: GRID_ORDER template arg dropped — output kernel is monomorphic
// on Cfast (empirical sensitivity sweep showed <1% delta).
// SP5 Task 5: MATMUL_ORIENT template arg dropped — output kernel is monomorphic
// on Std (input shape [16, Ntiles, outC]).
```
Replace with:
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

### Sub-task 3D: Verify, build, test, commit

- [ ] **Step 3D.1: Final grep — no SP/Task tags should remain anywhere in the four files**

```bash
grep -nE "\bSP[0-9]+\b|\bTask [0-9]+\b" cpp/neuralnet/mlx*.{cpp,h}
```
Expected: zero output.

- [ ] **Step 3D.2: Rebuild**

```bash
cd cpp && ninja
```
Expected: clean build (comment-only diff).

- [ ] **Step 3D.3: Run unit tests**

```bash
./katago runnnlayertests 2>&1 | tail -20
```
Expected: same pass output as before Task 3.

- [ ] **Step 3D.4: Commit**

```bash
git add cpp/neuralnet/mlxwinograd.h
git commit -m "$(cat <<'EOF'
Rewrite MLX winograd block comments in present tense

Three block comments in mlxwinograd.h that were too dense for the
in-place de-tag pattern of the previous commit because they described
what each tunable knob *is* in terms of when it was added or removed:

  * lines 12-15  — struct preamble ("SP2 tunes (tg0, tg1); SP4 adds
    (wpt, vw, gridOrder). SP5 removed output vw (Task 3), output
    gridOrder (Task 4)...").

  * lines 161-171 — input kernel header (SP5 Task 5 prelude + template-arg
    docs annotated with "Tasks 3+; 1 = SP3 behavior").

  * lines 291-302 — output kernel header ("SP5 Task 3: VW dropped...
    SP5 Task 4: GRID_ORDER dropped... SP5 Task 5: MATMUL_ORIENT dropped").

Rewritten into present-tense API docs that state what the configurable
knobs *are* and what the monomorphic invariants *are*, without naming
internal sprint stages. The empirical Cfast-vs-Tfast sensitivity-sweep
rationale (engineering judgment a future contributor would otherwise
have to re-derive) is preserved.

Comment-only diff.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review (controller checklist)

**1. Spec coverage:**
- Spec Commit 1: 4 items (stale-pointer, unused-binding ×2, warmup-comment, rounding-repair test) → Task 1 steps 1.5, 1.6, 1.7, 1.8+1.9, 1.2+1.3+1.4. ✓
- Spec Commit 2 principle (de-tag all SP/Task across all four files, including test code): Task 2 sub-tasks 2A–2F cover production + test code + log strings + function renames. ✓
- Spec Commit 3: three block-comment rewrites at the exact line ranges named in the spec. Task 3 sub-tasks 3A, 3B, 3C. ✓

**2. Placeholder scan:** No "TBD", "implement later", "appropriate", or vague language. Every Edit step has exact old_string and new_string text. Test code is shown in full. Commands are exact.

**3. Type consistency:**
- Function renames `runMLXBatchNormFP16Test_SP3` → `runMLXBatchNormFP16Test` and `runMLXConvLayerFP16WinogradTest_SP3` → `runMLXConvLayerFP16WinogradTest` are applied at: declaration-comment site (Step 2A.2), definition (Steps 2B.1, 2B.2), and call sites (Step 2B.5). All four references touched. ✓
- Test F's histogram `{(200, 1), (100, 2)}` produces work `(200, 200)` (tied), tie-broken by larger C → plan[0]=200, plan[1]=100. Shares (0.5, 0.5). lround(9.5)=10 each. Pre-repair sum 20. Repair: plan[0] -= 1 → 9. Final (9, 10). Sum 19. Both ≥ kRepFloor=3. ✓

**4. Step ordering:**
- Task 2 edits are top-down within each file. Single-line in-place replacements preserve line counts; the few multi-line replacements within a file (e.g. Steps 2A.6, 2A.8, 2A.9, 2B.12, 2D.1, 2D.5, 2D.8, 2D.11, 2D.12, 2D.13, 2E.7, 2E.8, 2E.10) replace N lines with N lines (or in 2B.12's case, replace 4 lines with 1, slightly shifting subsequent lines but the shift is captured by the implementer's read of the file). The implementer should Read the file between sub-tasks if line numbers drift.

The "delete pure-history" steps (2B.12 deletes 4 lines → 1 blank, 2C.6 deletes 1 line → 0) shift later line numbers within the same file. For these, the implementer should Read the file after each delete to confirm later sub-tasks' line numbers, OR rely on the exact `old_string` content (which is unique) to find each subsequent target.

**5. Test gating:** Test F is ungated (runs every time `runnnlayertests` is invoked, like Tests A–E). No env-var gates added.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-21-mlx-backend-comment-cleanup.md`. Per the earlier brainstorming decision, **inline execution** was chosen — I'll hand off to the `superpowers:executing-plans` skill to run the plan task-by-task in this session.
