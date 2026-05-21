# MLX Tests Relocation — Design

**Date:** 2026-05-21
**Branch:** feature/mlx-backend
**Status:** Spec — pending plan & implementation

## Goal

Move the bodies of `Tests::runMLXWinogradTests()` and `Tests::runMLXWinotunerTests()` (currently ~645 lines under `#ifdef USE_MLX_BACKEND` inside `cpp/tests/testnn.cpp`) into the MLX backend source files, so that `cpp/tests/testnn.cpp` and `cpp/tests/tests.h` become byte-identical to `master`. End-user behavior of `./katago runnnlayertests` is preserved: the same MLX tests run, in roughly the same place in the sequence.

**Success criterion:**

```bash
git diff master HEAD -- cpp/tests/testnn.cpp cpp/tests/tests.h    # empty output
./katago runnnlayertests                                          # passes; MLX aux test output still present
```

## Non-goals

- No CMake changes (no new translation units).
- No edits to `cpp/command/runtests.cpp` or `cpp/main.cpp`.
- No new test-only headers (e.g. `mlxtests.h`).
- No public-header (`mlxwinograd.h`, `mlxwinotuner.h`) additions for test symbols.
- No change to the contents of the tests themselves; bodies move verbatim modulo `Tests::` qualifier and required `#include` adjustments.

## Background

The current HEAD adds two member functions to `Tests`:

- `Tests::runMLXWinogradTests()` — exercises CPU & GPU Winograd, FP16 Winograd, kernel-plumbing smoke, WPT bit-for-bit equivalence, tail-guard coverage, output-kernel monomorphic smoke, etc. Also internally calls two SP3 free functions defined in `mlxbackend.cpp`: `runMLXBatchNormFP16Test_SP3()` and `runMLXConvLayerFP16WinogradTest_SP3()`.
- `Tests::runMLXWinotunerTests()` — exercises tuner cache schema v3 roundtrip, `isValid` invariants, output-kernel monomorphic smoke, gated flat-sweep convergence, dtype-aware cache filename collision avoidance, etc.

Both are gated by `#ifdef USE_MLX_BACKEND` and are invoked from `Tests::runNNLayerTests()` immediately after `testConvLayer()`.

### Existing precedent (kept as-is)

`cpp/neuralnet/mlxbackend.cpp` already hosts two MLX-specific free functions called from inside the current `Tests::runMLXWinogradTests` body:

- `void runMLXBatchNormFP16Test_SP3();` — defined at `mlxbackend.cpp:1690`.
- `void runMLXConvLayerFP16WinogradTest_SP3();` — defined at `mlxbackend.cpp:1727`.

These are forward-declared inside testnn.cpp today. After this relocation, they remain in `mlxbackend.cpp` and become same-TU calls of the relocated `runMLXWinogradTests`, so no forward-decl is needed.

### The reachable hook

`Tests::runNNLayerTests()` (master) calls `testConvLayer(numTestsRun)` near the top. `testConvLayer` repeatedly calls `NeuralNet::testEvaluateConv(...)`, which each backend implements. The MLX backend's implementation lives at `cpp/neuralnet/mlxbackend.cpp:1550`. This entry point is the natural — and only — master-pristine hook into MLX from `runNNLayerTests`.

## Architecture

Three files change. Two files are reverted to master.

### Change 1 — `cpp/neuralnet/mlxbackend.cpp`

#### 1a. One-shot guard at the top of `NeuralNet::testEvaluateConv`

```cpp
bool NeuralNet::testEvaluateConv(
  const ConvLayerDesc* desc, int batchSize, int nnXLen, int nnYLen,
  bool useFP16, bool useNHWC,
  const vector<float>& inputBuffer, vector<float>& outputBuffer
) {
  static bool ranMLXAuxTests = false;
  if(!ranMLXAuxTests) {
    ranMLXAuxTests = true;       // set BEFORE running, so a throw won't retrigger
    runMLXWinogradTests();
    runMLXWinotunerTests();
  }

  // ... existing body unchanged ...
}
```

**Semantics:** `testEvaluateConv` is called many times during a single `testConvLayer` invocation (once per `(test config × useNHWC × useFP16)` combination). The static flag ensures the MLX aux tests run **exactly once per process**, on the first call. Setting the flag before invoking the aux tests is intentional: if either aux test throws, the partial-run state is at least not repeated on the next conv config.

#### 1b. Forward-decl for `runMLXWinotunerTests`

Add a single forward-declaration near the top of the `#ifdef USE_MLX_BACKEND` region (or wherever the other MLX-internal free-function decls live), so `testEvaluateConv` can call it:

```cpp
void runMLXWinotunerTests();   // defined in mlxwinotuner.cpp
```

`runMLXWinogradTests` is defined in the same TU (see 1c) and so needs no forward-decl, provided its definition appears before `testEvaluateConv` — or use a forward-decl for symmetry. Either is acceptable.

#### 1c. Append `runMLXWinogradTests` as a free function

Append the entire ~330-line body of the current `Tests::runMLXWinogradTests()` as a free function `void runMLXWinogradTests()`. The body is moved verbatim with one mechanical change:

- The function's signature loses the `Tests::` qualifier (`void Tests::runMLXWinogradTests()` → `void runMLXWinogradTests()`).

The body's internal calls to `runMLXBatchNormFP16Test_SP3()` and `runMLXConvLayerFP16WinogradTest_SP3()` become same-TU calls in `mlxbackend.cpp`, so the two forward-decls that currently sit inside testnn.cpp are dropped (those decls move into testnn.cpp's deleted region and disappear).

#### 1d. Include adjustments

The relocated body uses `<array>`, `<cstring>`, `<random>`, and `"../neuralnet/mlxwinograd.h"`. `mlxbackend.cpp` already includes the Winograd header (it must — `NeuralNet::testEvaluateConv` uses `MLXWinograd::InputTransform`). Any missing standard-library includes for the relocated body are added at the top of the file under the existing `#ifdef USE_MLX_BACKEND` guard.

### Change 2 — `cpp/neuralnet/mlxwinotuner.cpp`

#### 2a. Append `runMLXWinotunerTests` as a free function

Append the entire ~310-line body of the current `Tests::runMLXWinotunerTests()` as a free function `void runMLXWinotunerTests()`, with the `Tests::` qualifier dropped. No other body edits.

#### 2b. Include adjustments

The relocated body uses `<chrono>`, `<cstdio>`, `<cstdlib>`, `<limits>`, `<random>`, `"../core/fileutils.h"`, `"../core/makedir.h"`, and `"../neuralnet/mlxwinotuner.h"`. The header is already included by the TU; missing standard-library and core/* includes are added under the existing `#ifdef USE_MLX_BACKEND` guard.

### Change 3 — `cpp/tests/testnn.cpp` reverted to master

Delete:

1. The two calls inside `Tests::runNNLayerTests()`:
   ```cpp
   runMLXWinogradTests();
   runMLXWinotunerTests();
   ```
2. The entire `#ifdef USE_MLX_BACKEND ... #endif` region that defines `Tests::runMLXWinogradTests` and `Tests::runMLXWinotunerTests`, including the two forward-decls for `runMLXBatchNormFP16Test_SP3` and `runMLXConvLayerFP16WinogradTest_SP3`.

Net result: `cpp/tests/testnn.cpp` is byte-identical to master.

### Change 4 — `cpp/tests/tests.h` reverted to master

Delete the two member-function declarations at lines 76-77:

```cpp
void runMLXWinogradTests();
void runMLXWinotunerTests();
```

Net result: `cpp/tests/tests.h` is byte-identical to master.

## Data flow

```
./katago runnnlayertests
  └─ MainCmds::runnnlayertests              [cpp/command/runtests.cpp — unchanged]
      └─ Tests::runNNLayerTests             [cpp/tests/testnn.cpp — master]
          ├─ NeuralNet::globalInitialize
          ├─ testConvLayer
          │   └─ NeuralNet::testEvaluateConv  [cpp/neuralnet/mlxbackend.cpp — gains one-shot guard]
          │       ├─ FIRST CALL ONLY:
          │       │   ├─ runMLXWinogradTests   [defined in mlxbackend.cpp]
          │       │   │   ├─ CPU/GPU Winograd, FP16, smoke, WPT, tail-guard…
          │       │   │   ├─ runMLXBatchNormFP16Test_SP3        [same TU]
          │       │   │   └─ runMLXConvLayerFP16WinogradTest_SP3 [same TU]
          │       │   └─ runMLXWinotunerTests  [defined in mlxwinotuner.cpp]
          │       └─ existing conv-evaluation body
          ├─ testBatchNormLayer
          ├─ testResidualBlock
          └─ testGlobalPoolingResidualBlock
```

## Output ordering

Currently (HEAD) the MLX aux tests print **between** `testConvLayer` and `testBatchNormLayer`. After the move, they print **inside** the first `testEvaluateConv` invocation — i.e. interleaved with `testConvLayer`'s own per-config logging. Order of individual MLX test cases relative to each other is unchanged. Output interleaving is cosmetic; the MLX aux tests are independent of any other test state.

## Error handling

- A `testAssert` failure inside the relocated bodies aborts the process (existing behavior).
- A C++ exception escaping `runMLXWinogradTests` or `runMLXWinotunerTests` propagates out of `testEvaluateConv`, which propagates out of `testConvLayer`, which propagates out of `runNNLayerTests`. Same propagation chain as today; only the call site is different.
- The static flag is set **before** the aux tests run, so a propagating exception does not cause the aux tests to re-run on subsequent `testEvaluateConv` calls in the same process. This is defensive — `runnnlayertests` aborts on first failure anyway.

## Testing

Two acceptance checks, both runnable locally:

1. **Source pristine check:**
   ```bash
   git diff master HEAD -- cpp/tests/testnn.cpp cpp/tests/tests.h
   ```
   Expected output: empty.

2. **Behavior preserved:**
   ```bash
   cd cpp && ninja && ./katago runnnlayertests
   ```
   Expected output: all current MLX test output still present (CPU Winograd, GPU Winograd, FP16, smoke, WPT, tail-guard, batchnorm FP16, conv FP16, v3 roundtrip, isValid invariants, monomorphic smoke, flat-sweep convergence, dtype-aware filename) — all `testAssert`s pass, exit code 0.

## Risks and mitigations

| Risk | Mitigation |
|------|-----------|
| Linker error: free function not found from `testEvaluateConv`. | Add explicit forward-decl(s) in `mlxbackend.cpp` for `runMLXWinotunerTests` (other TU). For `runMLXWinogradTests` (same TU), either place the definition before `testEvaluateConv` or add a forward-decl for symmetry. |
| Missing `#include` after relocation (e.g. `<random>`). | Plan task includes an explicit include-audit step; build will fail loudly if any are missed. |
| Static-flag thread-safety. | `runnnlayertests` is single-threaded at this point (`testConvLayer` runs serially before parallel work). C++11 `static` initializers are thread-safe regardless. Not a real risk. |
| MLX aux tests increase wall-time of first conv config (~few seconds). | Accepted; same total wall-time as today, just interleaved differently. |
| Build with `USE_MLX_BACKEND=OFF` accidentally references the new symbols. | The new code lives inside the existing `#ifdef USE_MLX_BACKEND` regions of `mlxbackend.cpp` and `mlxwinotuner.cpp`. Non-MLX backends never compile these TUs (CMake gates them). |

## Out of scope / future work

- Splitting `mlxbackend.cpp` (now ~1769 lines + ~330 = ~2100 lines) into smaller TUs is **not** part of this change.
- Replacing the static-flag-in-testEvaluateConv pattern with a more structured hook (e.g. a `NeuralNet::testBackendAux()` virtual entry point) is a wider refactor for a future spec; for now we match the file-size constraint and ship.
