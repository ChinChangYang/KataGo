# MLX Tests Relocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move bodies of `Tests::runMLXWinogradTests()` and `Tests::runMLXWinotunerTests()` out of `cpp/tests/testnn.cpp` into the MLX backend translation units, so that `cpp/tests/testnn.cpp` and `cpp/tests/tests.h` become byte-identical to master.

**Architecture:** Both functions move to free-function form. `runMLXWinogradTests` lives in `cpp/neuralnet/mlxbackend.cpp`; `runMLXWinotunerTests` lives in `cpp/neuralnet/mlxwinotuner.cpp`. Invocation is via a one-shot static guard at the top of `NeuralNet::testEvaluateConv` in `mlxbackend.cpp` — the MLX-side hook reachable from `Tests::runNNLayerTests` via `testConvLayer`.

**Tech Stack:** C++17, CMake/Ninja, MLX (Apple Silicon framework).

**Spec reference:** `docs/superpowers/specs/2026-05-21-mlx-tests-relocation-design.md`

---

## Preamble — Current state (HEAD before this plan)

These line ranges and identifiers are fixed by HEAD as of commit `52fef8c8`. Each task references them.

**`cpp/tests/testnn.cpp` (to be reverted to master):**

| Lines | Content |
|------:|---------|
| 922-923 | The two MLX calls inside `Tests::runNNLayerTests()`: `runMLXWinogradTests();` and `runMLXWinotunerTests();` |
| 933-1337 | First `#ifdef USE_MLX_BACKEND` block, defining `Tests::runMLXWinogradTests()` (FP16 build) and the `#else` stub `Tests::runMLXWinogradTests() {}` |
| 1339-1574 | Second `#ifdef USE_MLX_BACKEND` block, defining `Tests::runMLXWinotunerTests()` (FP16 build) and the `#else` stub |

**`cpp/tests/tests.h` (to be reverted to master):** lines 76-77 declare the two member functions.

**`cpp/neuralnet/mlxbackend.cpp`:**
- Entire file is wrapped in `#ifdef USE_MLX_BACKEND ... #endif` (line 1 ↔ last line).
- Last `#endif // USE_MLX_BACKEND` is the final line of the file.
- `NeuralNet::testEvaluateConv` begins at line 1550.
- `runMLXBatchNormFP16Test_SP3` is defined at line 1690.
- `runMLXConvLayerFP16WinogradTest_SP3` is defined at line 1727.

**`cpp/neuralnet/mlxwinotuner.cpp`:**
- Entire file is wrapped in `#ifdef USE_MLX_BACKEND ... #endif` (line 1 ↔ last line).
- Last `#endif // USE_MLX_BACKEND` is the final line of the file.
- Already includes `<chrono>`, `<random>`, `<algorithm>`, `<fstream>`, `<limits>`, `"../core/fileutils.h"`, `"../core/makedir.h"`.

**Build target for this work:** `USE_BACKEND=MLX`, FP16 path. The non-MLX `#else` stubs in testnn.cpp die with the rest of the deletion; non-MLX builds compile because (a) the `Tests::` decls leave `tests.h`, so no symbol is missing, and (b) the MLX TUs are not compiled at all when the CMake `USE_BACKEND` is not `MLX`.

---

### Task 1: Add `runMLXWinotunerTests` as a free function in mlxwinotuner.cpp

**Goal:** Define the new free function at file scope. No caller yet. Build still passes (unused free function is fine).

**Files:**
- Modify: `cpp/neuralnet/mlxwinotuner.cpp` (append before final `#endif`)

- [ ] **Step 1: Append the function body**

Open `cpp/neuralnet/mlxwinotuner.cpp`. Locate the final line `#endif // USE_MLX_BACKEND`. Insert the new function definition **immediately before** that line (so it lives inside the file's top-level `#ifdef USE_MLX_BACKEND` region).

The body to insert is the entire content of `cpp/tests/testnn.cpp` lines 1349-1569 from HEAD `52fef8c8`, with **one** mechanical change: the function signature loses the `Tests::` qualifier.

That is:

- Source (testnn.cpp line 1349): `void Tests::runMLXWinotunerTests() {`
- Destination (mlxwinotuner.cpp): `void runMLXWinotunerTests() {`

Every other line of the body (including its closing `}` at line 1569 and the trailing `cout << "MLX Winograd tuner tests passed" << endl;`) copies verbatim.

The body uses the following symbols, all already available in this TU (no new includes required):
- `MLXWinogradTuneParams`, `MLXWinogradTuner::*`, `MLXWinograd::*` (via the `mlxwinotuner.h` already included)
- `cout`, `endl` (via existing includes; `using std::cout;` is already in effect at file scope — verify by skimming the top of the file before pasting; if not, prefix with `std::` like the existing tests do — observe that the body already uses `std::cout` in some places and bare `cout` in others — preserve verbatim regardless)
- `testAssert` (from `"../core/test.h"`; check that mlxwinotuner.cpp includes this. If not, add `#include "../core/test.h"` to the file's existing include block at the top)

Use this exact command to confirm `testAssert` is reachable:

```bash
grep -n 'testAssert\|core/test.h' cpp/neuralnet/mlxwinotuner.cpp | head
```

If `"../core/test.h"` is not yet in the file's include block (lines 3-20), add it alongside the other `core/` includes.

- [ ] **Step 2: Build to confirm it compiles**

```bash
cd cpp && ninja 2>&1 | tail -20
```

Expected: build succeeds. The unused free function `runMLXWinotunerTests` produces no warning (free functions with default external linkage are not subject to `-Wunused-function`).

If you see "undeclared identifier" for `cout`, `endl`, `testAssert`, or any MLX type: revisit the includes per Step 1. If you see a redefinition error: you accidentally placed the new function outside the file-level `#ifdef`. Move it back inside.

- [ ] **Step 3: Run the existing tests to confirm no regression**

```bash
./katago runnnlayertests 2>&1 | tail -30
```

Expected: identical output to HEAD before this task (the new function is defined but not called).

- [ ] **Step 4: Commit**

```bash
git add cpp/neuralnet/mlxwinotuner.cpp
git commit -m "Move runMLXWinotunerTests body to mlxwinotuner.cpp (not yet wired)

Free function void runMLXWinotunerTests() now defined at file scope
in mlxwinotuner.cpp, with body copied verbatim from
Tests::runMLXWinotunerTests in testnn.cpp. No caller yet; the old
Tests::runMLXWinotunerTests is still defined and still invoked from
runNNLayerTests. Both coexist (different scopes) until Task 3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add `runMLXWinogradTests` as a free function in mlxbackend.cpp

**Goal:** Define the second free function at file scope. Build still passes. After this task, both new free functions exist but neither is called.

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp` (forward-decl near top + body before final `#endif`)

- [ ] **Step 1: Add forward-declarations near the top of mlxbackend.cpp**

`runMLXWinogradTests` and `runMLXWinotunerTests` will be called by `NeuralNet::testEvaluateConv` (line 1550) in Task 3. Both definitions live *after* `testEvaluateConv` in this TU — `runMLXWinogradTests` will be appended at the bottom (Step 2 below), and `runMLXWinotunerTests` is in a different TU. Forward-decls are therefore needed.

Locate the end of the file's `#include` block in `cpp/neuralnet/mlxbackend.cpp` (around lines 13-25, ending with a blank line before the first code definition). Add the following two lines immediately after the last `#include`:

```cpp
// Test-only free functions. runMLXWinogradTests is defined at the bottom of
// this file (alongside runMLXBatchNormFP16Test_SP3 / runMLXConvLayerFP16WinogradTest_SP3).
// runMLXWinotunerTests is defined in mlxwinotuner.cpp.
void runMLXWinogradTests();
void runMLXWinotunerTests();
```

- [ ] **Step 2: Append the function body**

Locate the final line `#endif // USE_MLX_BACKEND` in `cpp/neuralnet/mlxbackend.cpp`. Insert the new function definition **immediately before** that line.

The body to insert is the entire content of `cpp/tests/testnn.cpp` lines 942-1334 from HEAD `52fef8c8`, with **one** mechanical change: the function signature loses the `Tests::` qualifier.

That is:

- Source (testnn.cpp line 942): `void Tests::runMLXWinogradTests() {`
- Destination (mlxbackend.cpp): `void runMLXWinogradTests() {`

Every other line copies verbatim. The body's calls to `runMLXBatchNormFP16Test_SP3()` and `runMLXConvLayerFP16WinogradTest_SP3()` (lines ~1030-1031 of source) become same-TU calls: both functions are defined later in `mlxbackend.cpp` (lines 1690 and 1727 of HEAD), but the relocated `runMLXWinogradTests` is appended **after** them so direct calls compile without further forward-decls.

The body uses these additional headers (currently included by testnn.cpp lines 934-937): `<array>`, `<cstring>`, `<random>`. Verify they are present in `mlxbackend.cpp` with:

```bash
grep -n '^#include <array>\|^#include <cstring>\|^#include <random>' cpp/neuralnet/mlxbackend.cpp
```

If any are missing, add them to the file's existing `#include` block (in alphabetical order with the other standard-library includes, which today are at lines 23-25: `<mlx/mlx.h>`, `<iostream>`, `<cstring>` — so `<cstring>` is already there; check `<array>` and `<random>`).

- [ ] **Step 3: Build to confirm it compiles**

```bash
cd cpp && ninja 2>&1 | tail -20
```

Expected: build succeeds. Two new free functions exist (`runMLXWinogradTests`, `runMLXWinotunerTests`) with default external linkage; neither is called yet.

If you see "undeclared identifier `runMLXBatchNormFP16Test_SP3`" or `runMLXConvLayerFP16WinogradTest_SP3`: you placed `runMLXWinogradTests` **before** them in the file. Move it lower (right before the final `#endif`).

If you see "redefinition of `runMLXWinogradTests`": you forgot to convert the `Tests::` qualifier. Re-check Step 2.

- [ ] **Step 4: Run the existing tests to confirm no regression**

```bash
./katago runnnlayertests 2>&1 | tail -30
```

Expected: identical output to HEAD before this task (both new functions defined but neither called).

- [ ] **Step 5: Commit**

```bash
git add cpp/neuralnet/mlxbackend.cpp
git commit -m "Move runMLXWinogradTests body to mlxbackend.cpp (not yet wired)

Free function void runMLXWinogradTests() now defined at file scope
in mlxbackend.cpp, with body copied verbatim from
Tests::runMLXWinogradTests in testnn.cpp. Forward-decls added at the
top of mlxbackend.cpp for both runMLXWinogradTests (same TU) and
runMLXWinotunerTests (mlxwinotuner.cpp, defined in Task 1).

No caller yet; the old Tests::runMLX*Tests are still defined and
invoked from runNNLayerTests. Wiring happens in Task 3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Switch invocation — add one-shot guard, delete old code, verify master pristineness

**Goal:** After this task, `cpp/tests/testnn.cpp` and `cpp/tests/tests.h` are byte-identical to master, and the MLX aux tests still run via `NeuralNet::testEvaluateConv`'s static one-shot guard.

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp` (one-shot guard inside `NeuralNet::testEvaluateConv`)
- Modify: `cpp/tests/testnn.cpp` (delete 2 calls + 2 `#ifdef` blocks)
- Modify: `cpp/tests/tests.h` (delete 2 decls)

- [ ] **Step 1: Insert the one-shot guard into `NeuralNet::testEvaluateConv`**

Open `cpp/neuralnet/mlxbackend.cpp`. Find `NeuralNet::testEvaluateConv` at line 1550. The current function body begins:

```cpp
bool NeuralNet::testEvaluateConv(
  const ConvLayerDesc* desc,
  int batchSize,
  int nnXLen,
  int nnYLen,
  bool useFP16,
  bool useNHWC,
  const vector<float>& inputBuffer,
  vector<float>& outputBuffer
) {
  if(!useNHWC) {
    return false; // MLX only supports NHWC
  }
  ...
```

Insert the one-shot guard immediately after the opening brace `{` of the function body, before `if(!useNHWC)`. The exact insertion is:

```cpp
bool NeuralNet::testEvaluateConv(
  const ConvLayerDesc* desc,
  int batchSize,
  int nnXLen,
  int nnYLen,
  bool useFP16,
  bool useNHWC,
  const vector<float>& inputBuffer,
  vector<float>& outputBuffer
) {
  // Run MLX-specific aux tests (Winograd kernel + tuner) exactly once per
  // process, on the first invocation of testEvaluateConv. This is the
  // MLX-side hook reachable from Tests::runNNLayerTests through
  // testConvLayer, allowing testnn.cpp to stay backend-agnostic.
  // The flag is set BEFORE the calls so a propagating exception does not
  // cause the aux tests to re-run on subsequent conv configs.
  static bool ranMLXAuxTests = false;
  if(!ranMLXAuxTests) {
    ranMLXAuxTests = true;
    runMLXWinogradTests();
    runMLXWinotunerTests();
  }

  if(!useNHWC) {
    return false; // MLX only supports NHWC
  }
```

- [ ] **Step 2: Delete the two MLX calls from `Tests::runNNLayerTests`**

Open `cpp/tests/testnn.cpp`. Delete lines 922-923 (the two calls). The function should now match master:

```cpp
void Tests::runNNLayerTests() {
  NeuralNet::globalInitialize();
  int64_t numTestsRun = 0;
  testConvLayer(numTestsRun);
  testBatchNormLayer(numTestsRun);
  testResidualBlock(numTestsRun);
  testGlobalPoolingResidualBlock(numTestsRun);
  NeuralNet::globalCleanup();
  cout << "Tested " << numTestsRun << " configurations" << endl;
  cout << "Done" << endl;
}
```

- [ ] **Step 3: Delete the two `#ifdef USE_MLX_BACKEND` blocks from `testnn.cpp`**

After Step 2 the line numbers have shifted by 2. Re-locate (via `grep -n '^#ifdef USE_MLX_BACKEND' cpp/tests/testnn.cpp`) the two MLX blocks and delete each in its entirety:

- Block 1: from `#ifdef USE_MLX_BACKEND` (previously line 933) through the matching `#endif` (previously line 1337). This includes the body of `Tests::runMLXWinogradTests`, the `#else` stub, and the `#endif`.
- Block 2: from the next `#ifdef USE_MLX_BACKEND` (previously line 1339) through the matching `#endif` (previously line 1574). This includes the body of `Tests::runMLXWinotunerTests`, the `#else` stub, and the `#endif`.

Concrete sed-free approach: open the file in an editor, search for `#ifdef USE_MLX_BACKEND`, delete from that line down to and including the next standalone `#endif` line; repeat.

- [ ] **Step 4: Delete the two member-function decls from `tests.h`**

Open `cpp/tests/tests.h`. Delete lines 76-77:

```cpp
  void runMLXWinogradTests();
  void runMLXWinotunerTests();
```

- [ ] **Step 5: Verify the master-pristineness invariant**

```bash
git diff master HEAD -- cpp/tests/testnn.cpp cpp/tests/tests.h
```

Expected output: completely empty (no diff). If anything appears, you have either deleted too little or too much. Diff against master and fix until empty.

```bash
git diff --stat master HEAD | head -20
```

Expected: `cpp/tests/testnn.cpp` and `cpp/tests/tests.h` are absent from the changed-files list.

- [ ] **Step 6: Build**

```bash
cd cpp && ninja 2>&1 | tail -20
```

Expected: build succeeds.

If you see "undefined reference to `runMLXWinogradTests`" or `runMLXWinotunerTests`: the forward-decls from Task 2 Step 1 are missing or the function bodies were not preserved in Tasks 1-2.

If you see "redefinition of `runMLXWinogradTests`": Task 1 or Task 2 was not committed cleanly — the old `Tests::runMLXWinogradTests` somehow still exists.

- [ ] **Step 7: Run the full NN layer test suite**

```bash
./katago runnnlayertests 2>&1 | tee /tmp/post-relocation.log
echo "---"
grep -E "MLX Winograd|MLX-metal winograd|MLX BatchNorm|MLX ConvLayer|MLX Winograd tuner|v3 roundtrip|isValid|Output-kernel monomorphic|kernel-plumbing smoke|WPT bit-for-bit|tile-tail" /tmp/post-relocation.log
```

Expected output of the second `grep`: at least the following lines must appear (order may differ slightly because MLX tests now interleave inside `testConvLayer`'s first config):

```
  MLX Winograd F(2,3) CPU reference OK
  MLX-metal winograd maxErr=...
  MLX-metal winograd FP16 maxErr=...
  ...
  MLX BatchNorm FP16 test passed (...)
  MLX ConvLayer FP16 winograd test passed (...)
  MLX Winograd kernel-plumbing smoke test passed ...
  MLX Winograd WPT bit-for-bit equivalence (1/4/8) passed
  Running MLX Winograd tuner tests
  v3 roundtrip (Cfast + Tfast) OK
  v3 isValid invariants OK
  Output-kernel monomorphic smoke test OK
  MLX Winograd tuner tests passed
```

Exit code 0.

- [ ] **Step 8: Final sanity — confirm the one-shot guard fires only once**

```bash
./katago runnnlayertests 2>&1 | grep -c "Running MLX Winograd F(2,3) tests"
./katago runnnlayertests 2>&1 | grep -c "Running MLX Winograd tuner tests"
```

Expected: each grep outputs `1` (the leading log line from each aux test appears exactly once per process).

If either prints `0`: `testEvaluateConv` was never called (something broke between `Tests::runNNLayerTests` and `testConvLayer`). If either prints `>1`: the static-flag guard logic is wrong; re-check Step 1.

- [ ] **Step 9: Commit**

```bash
git add cpp/neuralnet/mlxbackend.cpp cpp/tests/testnn.cpp cpp/tests/tests.h
git commit -m "Relocate MLX aux tests: wire one-shot guard, revert testnn.cpp/tests.h to master

Tests::runMLXWinogradTests and Tests::runMLXWinotunerTests are gone
from cpp/tests/testnn.cpp (#ifdef USE_MLX_BACKEND blocks at lines
933-1337 and 1339-1574 deleted, calls at lines 922-923 deleted) and
from cpp/tests/tests.h (decls at lines 76-77 deleted).

cpp/tests/testnn.cpp and cpp/tests/tests.h are now byte-identical
to master:

  git diff master HEAD -- cpp/tests/testnn.cpp cpp/tests/tests.h
  # (no output)

Invocation moves to a one-shot static guard at the top of
NeuralNet::testEvaluateConv (mlxbackend.cpp:1550), reachable from
Tests::runNNLayerTests via testConvLayer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Plan self-review

**Spec coverage:**

| Spec section | Implementing task |
|--------------|-------------------|
| 1a. One-shot guard in `testEvaluateConv` | Task 3 Step 1 |
| 1b. Forward-decl for `runMLXWinotunerTests` | Task 2 Step 1 |
| 1c. Append `runMLXWinogradTests` free function | Task 2 Step 2 |
| 1d. Include adjustments in `mlxbackend.cpp` | Task 2 Step 2 (verifies `<array>`, `<cstring>`, `<random>`) |
| 2a. Append `runMLXWinotunerTests` free function | Task 1 Step 1 |
| 2b. Include adjustments in `mlxwinotuner.cpp` | Task 1 Step 1 (verifies `"../core/test.h"`) |
| 3. testnn.cpp reverted to master | Task 3 Steps 2-3, verified Step 5 |
| 4. tests.h reverted to master | Task 3 Step 4, verified Step 5 |
| Testing: source pristine check | Task 3 Step 5 |
| Testing: behavior preserved | Task 3 Step 7 |

No spec section is unaddressed.

**Placeholder scan:** None. Every code block contains the exact code to insert or delete. The two large bodies (~330 and ~310 lines) are referenced by line range in HEAD `52fef8c8` rather than reproduced inline — this is a specific, reproducible reference, not a placeholder.

**Type consistency:**
- Function name `runMLXWinogradTests` used consistently (Tasks 1-3).
- Function name `runMLXWinotunerTests` used consistently (Tasks 1-3).
- Forward-decl signatures match definition signatures: `void runMLXWinogradTests();` / `void runMLXWinotunerTests();`.
- Static flag name `ranMLXAuxTests` used only in Task 3 Step 1; no later task references it.
