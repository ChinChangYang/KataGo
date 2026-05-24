# MLX ANE Converter Mutex Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a file-static mutex around `new ComputeHandle(...)` in `cpp/neuralnet/mlxbackend.cpp` so the MLX backend's mux config 2×GPU + 2×ANE FP16 no longer crashes inside the CoreML converter.

**Architecture:** Mirror the Metal backend's existing pattern (`metalbackend.cpp:442` + `:589`). Declare a file-static `std::mutex computeHandleMutex` near the existing `MLX_MUX_GPU` / `MLX_MUX_ANE` constants, then hold a `std::lock_guard` around the `new ComputeHandle(...)` call at the end of `NeuralNet::createComputeHandle`. Forward-inference paths are untouched.

**Tech Stack:** C++17, `std::mutex`, `std::lock_guard`. `<mutex>` already included at `cpp/neuralnet/mlxbackend.cpp:32`.

**Spec:** `docs/superpowers/specs/2026-05-24-mlx-ane-converter-mutex-design.md` (commit `837303c5`).

---

## Task 1: Pre-fix repro

**Files:**
- Read: `cpp/neuralnet/mlxbackend.cpp:1662-1702`
- Read: `cpp/neuralnet/metalbackend.cpp:442,580-594` (prior art)
- Output: `cpp/tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_mux2g2a_prefix.txt`

Confirm the bug reproduces at HEAD before changing code, so the after-fix run is meaningful. The on-disk failure log from the earlier session (`..._mux2g2a.txt`) was generated with the same `mlxbackend.cpp` that's still at HEAD, but a fresh repro at the current commit avoids any ambiguity.

- [ ] **Step 1: Verify the current HEAD has no mutex around handle construction**

Run: `grep -n "computeHandleMutex\|lock_guard" cpp/neuralnet/mlxbackend.cpp`

Expected: only the existing `cachedModelsMutex` (line 1409 / 1435) and `compiledFuncsMutex` (line 1450) lock_guards are present. **No `computeHandleMutex`.** If a `computeHandleMutex` already exists, stop and report — the fix may already be in.

- [ ] **Step 2: Ensure binary is current**

Run: `cd cpp && stat -f "%Sm %N" -t "%Y-%m-%d %H:%M:%S" katago neuralnet/mlxbackend.cpp`

Expected: binary mtime ≥ source mtime. If source is newer, rebuild first: `ninja`.

- [ ] **Step 3: Trigger the 2×GPU + 2×ANE FP16 failure**

Run:
```bash
cd cpp
./katago testgpuerror \
  -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize 19 \
  -override-config "requireMaxBoardSize=True, numNNServerThreadsPerModel=4, deviceToUseThread0=0, deviceToUseThread1=0, deviceToUseThread2=100, deviceToUseThread3=100, mlxUseFP16=true" \
  -reference-file tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt \
  2>&1 | tee tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_mux2g2a_prefix.txt
```

Expected: process aborts with
```
libc++abi: terminating due to uncaught exception of type std::runtime_error:
MLX backend N: Core ML model conversion failed:
[MIL StorageWriter]: Metadata written to different offset than expected.
```
(N may be 2 or 3 depending on scheduling.)

If the run completes successfully instead, stop — the race may be load-dependent and the fix is harder to validate. Investigate before proceeding.

- [ ] **Step 4: Clean up any partial temp .mlpackage directories**

Run: `trash $(ls -d /var/folders/*/T/katago_coreml/model_* 2>/dev/null) 2>/dev/null; echo cleanup_done`

Expected: `cleanup_done` printed; any leftover partial conversions moved to Trash. (Use `trash`, not `rm`, per user preference.)

## Task 2: Implement the mutex

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp:56-57` (add mutex below MLX_MUX constants)
- Modify: `cpp/neuralnet/mlxbackend.cpp:1700-1701` (wrap `new ComputeHandle` in lock_guard)

- [ ] **Step 1: Add the file-static mutex declaration**

Insert immediately after line 57 (`static constexpr int MLX_MUX_ANE = 100; ...`).

Old:
```cpp
static constexpr int MLX_MUX_GPU = 0;    // MLX/GPU - default
static constexpr int MLX_MUX_ANE = 100;  // CoreML on CPU+ANE via katagocoreml + KataGoSwift

//------------------------------------------------------------------------------
// CoreML Model Conversion - reuses katagocoreml library, mirrors metalbackend.cpp
//------------------------------------------------------------------------------
```

New:
```cpp
static constexpr int MLX_MUX_GPU = 0;    // MLX/GPU - default
static constexpr int MLX_MUX_ANE = 100;  // CoreML on CPU+ANE via katagocoreml + KataGoSwift

// Serializes ComputeHandle construction across server threads. The CoreML
// converter (katagocoreml::KataGoConverter::convert) holds process-global
// MIL writer state that is not reentrant; without this lock, 2+ ANE threads
// racing at startup corrupt the .mlpackage and throw "Metadata written to
// different offset than expected." Mirrors metalbackend.cpp:442.
static std::mutex computeHandleMutex;

//------------------------------------------------------------------------------
// CoreML Model Conversion - reuses katagocoreml library, mirrors metalbackend.cpp
//------------------------------------------------------------------------------
```

- [ ] **Step 2: Hold the mutex around new ComputeHandle(...)**

Replace the existing return statement at lines 1700-1701 of `cpp/neuralnet/mlxbackend.cpp`.

Old:
```cpp
  if(!inputsUseNHWC)
    throw StringError("MLX backend: inputsUseNHWC = false unsupported");

  return new ComputeHandle(context, *loadedModel, inputsUseNHWC, requireExactNNLen, useFP16,
                           gpuIdx, maxBatchSize, serverThreadIdx);
}
```

New:
```cpp
  if(!inputsUseNHWC)
    throw StringError("MLX backend: inputsUseNHWC = false unsupported");

  // Serialize handle construction: see computeHandleMutex declaration above.
  std::lock_guard<std::mutex> lock(computeHandleMutex);
  return new ComputeHandle(context, *loadedModel, inputsUseNHWC, requireExactNNLen, useFP16,
                           gpuIdx, maxBatchSize, serverThreadIdx);
}
```

- [ ] **Step 3: Build**

Run: `cd cpp && ninja`

Expected: build succeeds with no warnings on the modified file. If a deprecation warning for `std::mutex` or `std::lock_guard` appears, check that `<mutex>` is still included at line 32 — it should be.

- [ ] **Step 4: Verify the mutex is now visible to grep**

Run: `grep -n "computeHandleMutex" cpp/neuralnet/mlxbackend.cpp`

Expected: two hits — the declaration near the top of the file, and the `lock_guard` use in `NeuralNet::createComputeHandle`.

## Task 3: Negative repro now passes

**Files:**
- Output: `cpp/tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_mux2g2a.txt`

- [ ] **Step 1: Re-run the failing 2×GPU + 2×ANE FP16 testgpuerror**

Run:
```bash
cd cpp
./katago testgpuerror \
  -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize 19 \
  -override-config "requireMaxBoardSize=True, numNNServerThreadsPerModel=4, deviceToUseThread0=0, deviceToUseThread1=0, deviceToUseThread2=100, deviceToUseThread3=100, mlxUseFP16=true" \
  -reference-file tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt \
  2>&1 | tee tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_mux2g2a.txt
```

Expected:
- Process runs to completion (no "Metadata written to different offset" exception).
- Log shows all four threads: two with `gpuIdx = 0` and two with `gpuIdx = 100`.
- Log shows two "Mux ANE mode - using CoreML (CPU+ANE)" lines followed by two successful "Conversion completed" lines (serialized).
- Eval section prints `current cfg error vs reference` and `batched current cfg error vs reference` blocks for winrate, lead, scoreMean, etc.

- [ ] **Step 2: Check the accuracy tolerance**

Run: `grep "current cfg error vs reference winrateError" cpp/tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_mux2g2a.txt`

Expected: two lines, one for `current cfg` and one for `batched current cfg`. The max winrateError (last column) on each line should be ≤ 0.01 (1.0%). On the b18c384 19×19 case the single-ANE baseline was 0.545% and the 1+1 mux check earlier was 0.638%, so 2+2 should land in the same band.

If the max winrate error exceeds 1.0%, stop and report — that would indicate the mux is producing different numerical results than the single-ANE case, which the design did not expect.

- [ ] **Step 3: Confirm both paths actually carried traffic**

Run: `grep "finishing, processed" cpp/tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_mux2g2a.txt`

Expected: four "GPU N finishing, processed ..." lines, two for `GPU 0` (MLX/GPU threads) and two for `GPU 100` (ANE/CoreML threads). Each should report a non-zero row count.

## Task 4: Regression checks

**Files:**
- Output: stdout from runtests / runnnlayertests
- Output: `cpp/tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_default.txt`

- [ ] **Step 1: Unit tests**

Run: `cd cpp && ./katago runtests 2>&1 | tail -20`

Expected: ends with the usual "All tests passed" / "Done" / success indicator that this binary prints. No new failures vs the pre-fix pass set.

- [ ] **Step 2: Neural net layer tests**

Run: `cd cpp && ./katago runnnlayertests 2>&1 | tail -10`

Expected: 14/14 configs pass, including `runMLXCoreMLSmokeTest`. If any config fails, abort and investigate — the mutex change should be invisible to single-thread layer-by-layer tests.

- [ ] **Step 3: Single-thread default testgpuerror is unchanged**

Run:
```bash
cd cpp
./katago testgpuerror \
  -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize 19 \
  -override-config "requireMaxBoardSize=True" \
  -reference-file tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt \
  2>&1 | tee tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_default.txt
```

Expected: run completes; max winrateError stays in the single-MLX-GPU baseline band (≤ ~3% FP16 vs Eigen reference — the prior `validation snapshot`'s 2.63% figure is the reference). The mutex is uncontended in this config, so behavior should be bit-identical to pre-fix.

## Task 5: Commit

**Files:**
- Stage: `cpp/neuralnet/mlxbackend.cpp`

- [ ] **Step 1: Verify staged diff is exactly the two hunks from Task 2**

Run: `git -C /Users/chinchangyang/Code/KataGo-MLX add cpp/neuralnet/mlxbackend.cpp && git -C /Users/chinchangyang/Code/KataGo-MLX diff --cached cpp/neuralnet/mlxbackend.cpp`

Expected: diff shows only two hunks — the file-static mutex declaration block, and the lock_guard insertion at the end of `NeuralNet::createComputeHandle`. No unintended changes.

If unrelated changes appear (e.g., the pre-existing WIP in `cpp/CMakeLists.txt` or `cpp/neuralnet/mlxtests.cpp` got swept in), unstage them and re-check. Those WIP files must remain unstaged per the same constraint that's held across this session.

- [ ] **Step 2: Commit**

Run:
```bash
git -C /Users/chinchangyang/Code/KataGo-MLX commit -m "$(cat <<'EOF'
MLX backend: serialize ComputeHandle construction

Two ANE server threads racing inside katagocoreml::KataGoConverter
::convert corrupted the MIL writer state and threw "Metadata written
to different offset than expected" at startup, blocking the 2xGPU +
2xANE FP16 mux config the example configs documented in 64304cdb.

Mirror metalbackend.cpp's pattern: file-static computeHandleMutex
held during the new ComputeHandle(...) call at the end of
NeuralNet::createComputeHandle. Mutex is uncontended in single-thread
defaults; for mux configs it adds a few seconds of serialized startup
in exchange for working concurrent ANE handles. Inference paths are
untouched.

Spec: docs/superpowers/specs/2026-05-24-mlx-ane-converter-mutex-design.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds. Run `git -C /Users/chinchangyang/Code/KataGo-MLX log --oneline -3` to verify the new commit sits at the tip of `mlx-backend-squash`.

## Task 6: Refresh local validation snapshot

**Files:**
- Modify (untracked): `.claude/MLX_Validation.md`

`.claude/MLX_Validation.md` is local-only per CLAUDE.md. After the post-fix verification, prepend a short snapshot entry recording the 2+2 mux result (max winrate error, both GPU/ANE row counts) and the date. Do **not** commit this file.

- [ ] **Step 1: Add a `## Snapshot — 2026-05-24 (post mux 2+2 mutex fix)` section**

Insert above the existing `## Snapshot — 2026-05-24 (post NHWC→NCHW ANE layout fix, ...)` block. Include:
- Branch / HEAD SHA (the new commit from Task 5).
- One paragraph: what changed and why.
- Pre-fix vs post-fix one-row comparison (pre-fix = crash, post-fix = max winrateError from Task 3 Step 2).
- Per-path row counts from Task 3 Step 3.
- One-line repro command (same as Task 3 Step 1).

- [ ] **Step 2: Verify .claude/MLX_Validation.md is still untracked**

Run: `git -C /Users/chinchangyang/Code/KataGo-MLX status .claude/MLX_Validation.md`

Expected: appears under "Untracked files" (or not at all if `.claude/` is gitignored as a directory). Should never appear under "Changes to be committed."

## Self-review

(Run after writing all tasks.)

**Spec coverage:**
- Spec Goal "2×GPU + 2×ANE FP16 mux becomes functional" → Task 3.
- Spec Goal "accuracy stays in family with single-ANE baseline" → Task 3 Step 2 (1.0% bound).
- Spec Testing #1 "Negative repro" → Task 1 (pre-fix) + Task 3 (post-fix).
- Spec Testing #2 "Accuracy ≤ 1.0%" → Task 3 Step 2.
- Spec Testing #3 "runtests / runnnlayertests" → Task 4 Step 1-2.
- Spec Testing #4 "Single-thread default unchanged" → Task 4 Step 3.
- Spec Testing #5 (optional analysis smoke) → omitted; not required by the spec.
- Spec Rollout "Single commit on mlx-backend-squash" → Task 5.
- Spec Rollout "No `.claude/MLX_Validation.md` strictly required, but refresh" → Task 6.

**Placeholder scan:** no "TBD", "TODO", "appropriate error handling", or unspecified test code. All bash commands and code snippets are full.

**Type consistency:** mutex name `computeHandleMutex` used identically in declaration and lock_guard. File paths consistent throughout. Commit SHAs from this session (`64304cdb`, `837303c5`) are stable.
