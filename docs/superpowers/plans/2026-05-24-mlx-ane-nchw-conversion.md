# MLX Backend ANE/CoreML NHWC → NCHW Conversion Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transpose spatial inputs NHWC → NCHW into a dedicated `InputBuffers` staging vector on the ANE dispatch path so the Swift `CoreMLComputeHandle.apply()` ABI (which `memcpy`s `[1, C, H, W]` per row) receives correctly-laid-out bytes. Keep `spatialInput` NHWC for the MLX/GPU path.

**Architecture:** Single-file change to `cpp/neuralnet/mlxbackend.cpp`. Add a `userInputBufferNCHW` member to `InputBuffers`, sized like `spatialInput` and zero-initialized; the constructor always allocates (the cross-backend `createInputBuffers` ABI does not see mux mode). Inside the existing `getOutput` per-row loop, replace the current unconditional strided-mask gather with an `if (computeHandle->coremlOnlyHandle)` block that (a) writes the row to `userInputBufferNCHW` with explicit NHWC→NCHW indexing and (b) lifts the mask as a contiguous `memcpy` from the start of the converted row (channel 0 is the validity mask). At the ANE dispatch site, hand `userInputBufferNCHW.data()` to `apply()` instead of `spatialInput.data()`.

**Tech Stack:** C++17, MLX (Apple), Swift-C++ interop via `KataGoSwift`, CMake + Ninja.

**Spec:** `docs/superpowers/specs/2026-05-24-mlx-ane-nchw-conversion-design.md`

---

### Task 1: Capture pre-fix repro baseline

Prove the bug exists on the current MLX backend build by running `testgpuerror` against a known-good Eigen reference and observing tens-of-percent winrate error on the ANE path. This is read-only — no code changes, no commit. Captures a number to compare against post-fix.

**Files:**
- Read: `cpp/neuralnet/mlxbackend.cpp` (current state)
- Read: `cpp/rungpuerrortest.sh`
- Read: `cpp/tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt` (existing Eigen reference)

- [ ] **Step 1: Confirm MLX-backend build is current**

Run from repo root:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ls -la katago 2>/dev/null | head -1 && file katago 2>/dev/null | head -1
```

Expected: `katago` binary exists (built from the prior mask-fix work). If missing, run:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && cmake -G Ninja -DUSE_BACKEND=MLX . && ninja
```

Expected: build completes, `katago` binary present in `cpp/`.

- [ ] **Step 2: Confirm reference file exists**

Run:

```bash
ls -la /Users/chinchangyang/Code/KataGo-MLX/cpp/tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt
```

Expected: file exists, non-zero size. If missing, regenerate it via the Eigen leg of `./rungpuerrortest.sh` (run from `cpp/` with `USE_BACKEND=EIGEN` build); skipping this step is fine if the file is present.

- [ ] **Step 3: Confirm model file is downloaded**

Run:

```bash
ls -la /Users/chinchangyang/Code/KataGo-MLX/cpp/models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz
```

Expected: file exists. If missing, `cd cpp && wget --no-clobber -P models/ https://media.katagotraining.org/uploaded/networks/models/kata1/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz`.

- [ ] **Step 4: Run pre-fix repro and capture output**

Run from `cpp/`:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && \
  ./katago testgpuerror \
    -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
    -config configs/gtp_example.cfg \
    -boardsize 19 \
    -override-config "requireMaxBoardSize=True, deviceToUseThread0=100" \
    -reference-file tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt \
    2>&1 | tee /tmp/mlx-ane-prefix-repro.log
```

Expected: command completes without crashing. The log shows `max` winrate error in the tens of percent (anywhere in the 10%–99% band). Note the exact number — this is the baseline. Pass it along when you mark the task complete.

- [ ] **Step 5: Mark task complete without committing**

Nothing to commit (read-only baseline capture).

---

### Task 2: Implement NHWC → NCHW conversion in `mlxbackend.cpp`

Add `userInputBufferNCHW` to `InputBuffers`, replace the per-row strided mask gather with the path-aware transpose-and-mask block from the spec, and swap the ANE dispatch's spatial pointer. Rebuild, smoke-test, commit.

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp`

- [ ] **Step 1: Read the current `InputBuffers` struct and constructor**

```bash
sed -n '1464,1530p' /Users/chinchangyang/Code/KataGo-MLX/cpp/neuralnet/mlxbackend.cpp
```

Confirm the struct currently has `std::vector<float> userInputMaskBuffer;` at line 1481 and the ctor resizes it at line 1521. The new vector will sit next to it with the same lifetime.

- [ ] **Step 2: Add `userInputBufferNCHW` member**

Edit `cpp/neuralnet/mlxbackend.cpp`. Find the line:

```cpp
  std::vector<float> userInputMaskBuffer;
```

Replace with:

```cpp
  std::vector<float> userInputMaskBuffer;
  // NCHW staging buffer for the ANE/CoreML dispatch path. The Swift
  // CoreMLComputeHandle.apply() allocates MLMultiArray with shape
  // [1, C, H, W] and memcpys each row's bytes, so it strictly requires
  // NCHW. spatialInput stays NHWC for the MLX/GPU path; rows are
  // transposed into this buffer inside getOutput before dispatch. The
  // MLX/GPU path never reads this buffer.
  std::vector<float> userInputBufferNCHW;
```

- [ ] **Step 3: Resize `userInputBufferNCHW` in the constructor**

Edit `cpp/neuralnet/mlxbackend.cpp`. Find the line:

```cpp
    userInputMaskBuffer.resize(singleMaskElts * maxBatchSize);
```

Replace with:

```cpp
    userInputMaskBuffer.resize(singleMaskElts * maxBatchSize);
    userInputBufferNCHW.resize(singleInputElts * maxBatchSize);
```

- [ ] **Step 4: Replace the per-row mask gather with the path-aware transpose block**

Edit `cpp/neuralnet/mlxbackend.cpp`. Find the block (currently at `mlxbackend.cpp:1750-1768`):

```cpp
    // Extract mask (channel 0) from NHWC spatial input into the dedicated
    // contiguous buffer required by the Swift CoreMLComputeHandle ABI on
    // the ANE path. One strided gather over numInputChannels; dwarfed by
    // the forward pass. The MLX/GPU path slices channel 0 itself via
    // mx::slice and does not read this buffer.
    //
    // When the mlpackage was converted with optimize_identity_mask=true
    // (i.e., requireExactNNLen=true) the ANE model ignores this buffer,
    // but populating it unconditionally avoids a silent-misprediction
    // footgun when optimize_identity_mask=false.
    {
      const int numChannels = computeHandle->numInputChannels;
      float* dstMask = inputBuffers->userInputMaskBuffer.data()
                     + inputBuffers->singleMaskElts * nIdx;
      const float* srcSpatial = rowSpatialInput;  // already NHWC, ch 0 first
      for(size_t i = 0; i < inputBuffers->singleMaskElts; i++) {
        dstMask[i] = srcSpatial[i * numChannels];
      }
    }
```

Replace with:

```cpp
    // ANE/CoreML path needs an NCHW spatial buffer because the Swift
    // CoreMLComputeHandle.apply() allocates MLMultiArray with shape
    // [1, C, H, W] and raw memcpys C*H*W floats per row. spatialInput
    // is NHWC (required by the MLX/GPU path's mx::array shape), so we
    // transpose each row into userInputBufferNCHW here. The validity
    // mask (channel 0) sits at the start of the converted row, so it
    // collapses to a contiguous memcpy into userInputMaskBuffer.
    //
    // When the mlpackage was converted with optimize_identity_mask=true
    // (i.e., requireExactNNLen=true) the ANE model ignores the mask
    // buffer, but populating it unconditionally costs essentially
    // nothing (one memcpy of H*W floats) and avoids a silent-
    // misprediction footgun when optimize_identity_mask=false.
    //
    // The MLX/GPU path slices channel 0 itself via mx::slice and does
    // not read userInputMaskBuffer or userInputBufferNCHW.
    if(computeHandle->coremlOnlyHandle) {
      const int C = computeHandle->numInputChannels;
      const size_t HW = inputBuffers->singleMaskElts;  // nnXLen * nnYLen
      float* rowNCHW = inputBuffers->userInputBufferNCHW.data()
                     + inputBuffers->singleInputElts * nIdx;
      const float* rowNHWC = rowSpatialInput;  // [H*W, C]
      for(int c = 0; c < C; c++) {
        float* dstCh = rowNCHW + (size_t)c * HW;
        for(size_t hw = 0; hw < HW; hw++) {
          dstCh[hw] = rowNHWC[hw * C + c];
        }
      }
      float* dstMask = inputBuffers->userInputMaskBuffer.data()
                     + inputBuffers->singleMaskElts * nIdx;
      std::memcpy(dstMask, rowNCHW, HW * sizeof(float));
    }
```

- [ ] **Step 5: Swap the ANE dispatch's spatial pointer**

Edit `cpp/neuralnet/mlxbackend.cpp`. Find the block (currently around `mlxbackend.cpp:1771-1787`):

```cpp
  // Dispatch to appropriate path based on mux mode.
  if(computeHandle->coremlOnlyHandle) {
    // ANE path: dispatch through the Swift CoreMLComputeHandle. Same call
    // shape Metal uses at metalbackend.cpp:1007. The mask buffer is
    // populated per row in the loop above; the mlpackage ignores it iff it
    // was converted with optimize_identity_mask=true.
    computeHandle->coremlOnlyHandle.get().apply(
      inputBuffers->spatialInput.data(),
      inputBuffers->globalInput.data(),
      inputBuffers->metaInput.data(),  // always non-null (resized to at least 1 in InputBuffers ctor)
      inputBuffers->userInputMaskBuffer.data(),
      inputBuffers->policyResults.data(),
      inputBuffers->policyPassResults.data(),
      inputBuffers->valueResults.data(),
      inputBuffers->scoreValueResults.data(),
      inputBuffers->ownershipResults.data(),
      batchSize);
  } else {
```

Replace with:

```cpp
  // Dispatch to appropriate path based on mux mode.
  if(computeHandle->coremlOnlyHandle) {
    // ANE path: dispatch through the Swift CoreMLComputeHandle. Swift
    // creates MLMultiArray(shape: [1, C, H, W]) per row and memcpys
    // C*H*W floats — strict NCHW. We pass userInputBufferNCHW (rows
    // transposed from NHWC in the loop above) instead of spatialInput.
    // The mask is the contiguous H*W float prefix of each NCHW row,
    // already lifted into userInputMaskBuffer above. The mlpackage
    // ignores the mask buffer iff it was converted with
    // optimize_identity_mask=true.
    computeHandle->coremlOnlyHandle.get().apply(
      inputBuffers->userInputBufferNCHW.data(),
      inputBuffers->globalInput.data(),
      inputBuffers->metaInput.data(),  // always non-null (resized to at least 1 in InputBuffers ctor)
      inputBuffers->userInputMaskBuffer.data(),
      inputBuffers->policyResults.data(),
      inputBuffers->policyPassResults.data(),
      inputBuffers->valueResults.data(),
      inputBuffers->scoreValueResults.data(),
      inputBuffers->ownershipResults.data(),
      batchSize);
  } else {
```

- [ ] **Step 6: Verify `<cstring>` is already included for `std::memcpy`**

Run:

```bash
grep -n '#include <cstring>\|#include <string.h>' /Users/chinchangyang/Code/KataGo-MLX/cpp/neuralnet/mlxbackend.cpp
```

Expected: at least one `<cstring>` include. If neither is present, add `#include <cstring>` after the existing standard-library includes near the top of the file. (`std::memcpy` is required by Step 4; the existing strided mask gather did not need it, so a fresh include may be necessary.)

- [ ] **Step 7: Rebuild**

Run from `cpp/`:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ninja
```

Expected: clean build, no warnings about the new code, `katago` binary updated. If the build fails because `std::memcpy` is undeclared, return to Step 6 and add the include.

- [ ] **Step 8: Smoke test (binary doesn't crash on a trivial invocation)**

Run from `cpp/`:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && ./katago version
```

Expected: prints version banner without crashing. (This catches any link-time or basic-startup regression before the full ANE inference run.)

- [ ] **Step 9: Run the same pre-fix repro as Task 1 and confirm the fix**

Run from `cpp/`:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && \
  ./katago testgpuerror \
    -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
    -config configs/gtp_example.cfg \
    -boardsize 19 \
    -override-config "requireMaxBoardSize=True, deviceToUseThread0=100" \
    -reference-file tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt \
    2>&1 | tee /tmp/mlx-ane-postfix-repro.log
```

Expected: command completes; the `max` winrate error has dropped from "tens of percent" (Task 1 baseline) into the half-precision tolerance band (typically under a few percent; if the converter happens to have emitted an FP32 mlpackage on this host, under 0.1%). Note the exact number.

If the post-fix number is still in the tens of percent, **stop and surface a BLOCKED status** — do not commit. Either the spec is wrong about the layout, the edit didn't apply, or there's a second bug. Diff `/tmp/mlx-ane-prefix-repro.log` vs `/tmp/mlx-ane-postfix-repro.log` and report what you see.

- [ ] **Step 10: Commit the fix**

Run from repo root:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX && \
  git add cpp/neuralnet/mlxbackend.cpp && \
  git commit -m "$(cat <<'EOF'
MLX backend: transpose ANE spatial input NHWC -> NCHW

The Swift CoreMLComputeHandle.apply() allocates MLMultiArray with shape
[1, C, H, W] and memcpys C*H*W floats per row — strict NCHW. The MLX/GPU
path requires spatialInput to be NHWC (mx::array constructed with
{B, H, W, C} shape), so we cannot just change spatialInput's layout.

Add a userInputBufferNCHW staging vector to InputBuffers, transpose each
row NHWC -> NCHW into it inside the ANE branch of getOutput, and hand
that pointer to apply() instead of spatialInput. The validity mask
(channel 0) sits at the start of each converted row, so the previous
strided mask gather collapses to a contiguous memcpy.

GPU path is untouched. ANE path now produces results that match the
Eigen reference within the converter's precision band.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds, no pre-commit hook failures. If a hook fails, fix the issue, re-stage, and create a **new** commit (do not amend).

---

### Task 3: Targeted post-fix spot-check (two configurations)

Run two specific configurations: one with `requireExactNNLen=true` (mlpackage has `optimize_identity_mask=true`, mask ignored → proves the layout fix in isolation) and one with `requireExactNNLen=false` on a 13×13 board (proves the layout fix composes with the mask fix). Capture both numbers.

**Files:**
- None modified.

- [ ] **Step 1: Confirm the v8 b10c128 model is available**

Run:

```bash
ls -la /Users/chinchangyang/Code/KataGo-MLX/cpp/tests/models/g170e-b10c128-s1141046784-d204142634.bin.gz
ls -la /Users/chinchangyang/Code/KataGo-MLX/cpp/tests/results/gpu_error_reference_files/g170e-b10c128-s1141046784-d204142634.bin.gz_size13.txt
ls -la /Users/chinchangyang/Code/KataGo-MLX/cpp/tests/results/gpu_error_reference_files/g170e-b10c128-s1141046784-d204142634.bin.gz_size19.txt
```

Expected: all three files exist. (If the model is missing, copy or re-download it; the reference files were generated by an earlier Eigen sweep and should be on disk per the 2026-05-23 validation memo.)

- [ ] **Step 2: Run spot-check A — `requireExactNNLen=true` on 19×19 (isolates layout fix)**

Run from `cpp/`:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && \
  ./katago testgpuerror \
    -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
    -config configs/gtp_example.cfg \
    -boardsize 19 \
    -override-config "requireMaxBoardSize=True, deviceToUseThread0=100" \
    -reference-file tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt \
    2>&1 | tee /tmp/mlx-ane-spotcheck-A.log
```

Expected: errors within the half-precision tolerance band (max winrate err under a few percent, often well under 1%). Since the mask is ignored on this configuration, any remaining error must be due to layout + precision — confirms the layout fix alone is enough on this path.

- [ ] **Step 3: Run spot-check B — `requireExactNNLen=false` on 13×13 (layout + mask interaction)**

Run from `cpp/`:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && \
  ./katago testgpuerror \
    -model tests/models/g170e-b10c128-s1141046784-d204142634.bin.gz \
    -config configs/gtp_example.cfg \
    -boardsize 13 \
    -override-config "requireMaxBoardSize=False, maxBatchSize=27, deviceToUseThread0=100" \
    -reference-file tests/results/gpu_error_reference_files/g170e-b10c128-s1141046784-d204142634.bin.gz_size13.txt \
    2>&1 | tee /tmp/mlx-ane-spotcheck-B.log
```

Expected: errors in the same band as spot-check A. Critically, no "off by an entire channel" symptoms (large lead/score drift on positions where `nnXLen != boardXSize`) — confirms the mask is being passed through correctly and the layout fix doesn't interact badly with the mask fix from `375a520c`.

- [ ] **Step 4: Mark task complete without committing**

Both `.log` files are sanity-check artifacts. Note both `max` winrate err numbers and pass them along when marking the task complete; they feed into the snapshot in Task 5.

---

### Task 4: Full cross-backend sweep validation

Run `./rungpuerrortest.sh ane` to drive all 30 invocations through the MLX→ANE path against the existing Eigen references. Confirm parity with the MLX/GPU sweep numbers.

**Files:**
- None modified.

- [ ] **Step 1: Confirm prior Eigen-pass references are on disk**

Run:

```bash
ls /Users/chinchangyang/Code/KataGo-MLX/cpp/tests/results/gpu_error_reference_files/ | wc -l
```

Expected: at least 30 (one per invocation in `rungpuerrortest.sh`). If fewer, the Eigen pass needs to be re-run first — that is a separate operation not in scope for this plan; surface as a BLOCKED status with the count.

- [ ] **Step 2: Run the full ANE sweep**

Run from `cpp/`:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && \
  ./rungpuerrortest.sh ane 2>&1 | tee /tmp/mlx-ane-fullsweep.log
```

Expected: all 30 invocations complete (the script uses `bash -eux` so any non-zero exit aborts the whole sweep). Wall-clock should be in the same order as the prior MLX/GPU sweep (~25 minutes per the 2026-05-23 memo).

- [ ] **Step 3: Extract the worst-case max metrics across the sweep**

Run:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && \
  for f in tests/results/gpu_error_results/*_ane.txt; do \
    grep -E 'winrate.*max|lead.*max|scoreMean.*max|scoreStdev.*max|ownership.*max' "$f" | sed "s|^|$(basename "$f"): |"; \
  done > /tmp/mlx-ane-sweep-maxes.txt
sort -t: -k3 -gr /tmp/mlx-ane-sweep-maxes.txt | head -20
```

Expected: top winrate-max in the half-precision tolerance band (under ~5% across the whole sweep on this hardware, often well under 1%; the 2026-05-23 MLX/GPU FP16 sweep had a worst-case 2.63%). Any winrate-max above ~10% or any single invocation reporting catastrophic error (>50%) is a regression — surface as BLOCKED, do not proceed to Task 5.

- [ ] **Step 4: Mark task complete without committing**

The per-invocation result files under `cpp/tests/results/gpu_error_results/*_ane.txt` are gitignored and persist on disk for follow-up inspection. Pass the worst-case winrate/lead/scoreMean/scoreStdev/ownership max numbers along when marking the task complete; they feed into Task 5.

---

### Task 5: Refresh local validation snapshot

Update the local-only `.claude/MLX_Validation.md` snapshot with the new ANE accuracy and throughput numbers. **Do not commit** — the file is intentionally untracked.

**Files:**
- Modify: `.claude/MLX_Validation.md` (local-only, untracked)

- [ ] **Step 1: Read the current snapshot for shape and tone**

```bash
cat /Users/chinchangyang/Code/KataGo-MLX/.claude/MLX_Validation.md 2>/dev/null | head -120
```

If the file does not exist, create it from scratch following the structure described in the top-level `CLAUDE.md` "MLX Validation Snapshot" section (date heading + "Cross-backend validation" table + "Reproduction commands" block + "When to re-run" checklist).

- [ ] **Step 2: Run a throughput benchmark on the ANE path**

Run from `cpp/`:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp && \
  ./katago benchmark \
    -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
    -override-config "deviceToUseThread0=100" \
    -half-batch-size \
    2>&1 | tee /tmp/mlx-ane-benchmark.log
```

Expected: completes within a few minutes. Note the visits/sec figure at the optimal `numSearchThreads` line. Compare against the same model's MLX/GPU benchmark (rerun without the override if a recent number isn't already in the snapshot) and against the Metal/ANE benchmark on this host if one is recorded.

- [ ] **Step 3: Update the snapshot file**

Edit `.claude/MLX_Validation.md` to append a new dated section (today's date — `date +%Y-%m-%d`) under the existing entries. Include:

- Date and branch (`mlx-backend-squash`) and the SHAs of the mask fix (`375a520c`), script tweak (`40b75328`), and NCHW fix (the SHA from Task 2 Step 10).
- Cross-backend table: MLX/GPU vs MLX/ANE vs Metal/ANE (if recorded), each showing worst-case max for winrate / lead / scoreMean / scoreStdev / ownership across the 30-invocation sweep. Use the Task 4 Step 3 numbers for the new MLX/ANE row.
- Throughput line: MLX/ANE visits/sec from Step 2 above, alongside the most-recent MLX/GPU and Metal/ANE numbers from the existing snapshot.
- Reproduction commands block: include the `./rungpuerrortest.sh ane` invocation, the benchmark command from Step 2, and the model paths used.
- "When to re-run" checklist line: "touched `mlxbackend.cpp`'s ANE dispatch / NCHW transpose, `nneval.cpp` batching, or any code path feeding the Swift `apply()` ABI."

- [ ] **Step 4: Do not commit, confirm file is untracked**

Run:

```bash
git -C /Users/chinchangyang/Code/KataGo-MLX status --porcelain .claude/MLX_Validation.md
```

Expected: `??` (untracked) or no output (if it appears in `.gitignore`). If git would track it, do **not** add or commit; the file is intentionally local-only per the project `CLAUDE.md`.

---

## Self-Review

**1. Spec coverage:**
- Spec "Components Touched → `struct InputBuffers`": Task 2 Steps 2–3 add the member and resize.
- Spec "Components Touched → `NeuralNet::getOutput`": Task 2 Step 4 replaces the per-row block; Step 5 swaps the dispatch pointer.
- Spec "Testing → Pre-fix repro": Task 1.
- Spec "Testing → Post-fix validation step 1 (Rebuild)": Task 2 Step 7.
- Spec "Testing → Post-fix validation step 2 (Targeted spot-check)": Task 3.
- Spec "Testing → Post-fix validation step 3 (Full sweep)": Task 4.
- Spec "Testing → Post-fix validation step 4 (Throughput sanity)": Task 5 Step 2.
- Spec "Testing → Post-fix validation step 5 (Snapshot update)": Task 5 Steps 1, 3, 4.
- Spec "Rollout → Single commit on mlx-backend-squash": Task 2 Step 10. Subsequent tasks are read-only.

No spec requirement is unaccounted for.

**2. Placeholder scan:** No `TBD`, `TODO`, `implement later`, or "add appropriate error handling" — every step states the exact action and command. The one conditional in Task 2 Step 6 (the `<cstring>` include) is exhaustively specified: check, and if absent, add.

**3. Type consistency:**
- `userInputBufferNCHW` (with capitalized N-C-H-W) is consistent across Task 2 Steps 2, 3, 4, 5 and the comments in Steps 4–5.
- Loop counter types: `int c` for channel iteration, `size_t hw` for the H*W loop and the inner stride, `size_t HW` for the cached `singleMaskElts` — match the spec.
- `inputBuffers->singleInputElts` and `inputBuffers->singleMaskElts` use the existing constants from the struct (no rename).
- The ANE-branch predicate `if(computeHandle->coremlOnlyHandle)` matches what the existing dispatch site at `mlxbackend.cpp:1772` already uses.

No drift detected.
