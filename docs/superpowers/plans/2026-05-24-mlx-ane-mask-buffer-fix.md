# MLX ANE/CoreML Mask Buffer Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the MLX backend's ANE/CoreML dispatch path from silently feeding an all-ones mask when `requireExactNNLen=false`, by gathering channel 0 of the NHWC spatial input into a persistent `userInputMaskBuffer` on every call.

**Architecture:** Single-file C++ change in `cpp/neuralnet/mlxbackend.cpp` — add two members to `struct InputBuffers`, populate the new buffer per batch row inside the existing `getOutput` loop, and swap the ANE branch's pointer from the transient ones-vector to the persistent buffer. Plus a one-line script tweak so the existing cross-backend sweep covers MLX-ANE.

**Tech Stack:** C++17, MLX (Apple's array framework), katagocoreml + Swift CoreMLComputeHandle, CMake/Ninja, KataGo's `testgpuerror` command.

**Spec:** `docs/superpowers/specs/2026-05-24-mlx-ane-mask-buffer-fix-design.md`

---

## File Structure

**Modified files (all in repository root unless noted):**

| File | Responsibility | Lines touched |
|------|---------------|---------------|
| `cpp/neuralnet/mlxbackend.cpp` | Production MLX inference: holds `InputBuffers`, `ComputeHandle`, and `NeuralNet::getOutput`. The bug and the fix both live here. | ~1464–1525 (struct), ~1700–1790 (dispatch) |
| `cpp/rungpuerrortest.sh` | Cross-backend `testgpuerror` driver shared with Metal. Make its `ane` mode use the backend-agnostic `deviceToUseThread0` key so it works for MLX too. | ~11 |

**Untouched on purpose:**
- Swift `CoreMLComputeHandle.apply` ABI — no change.
- `katagocoreml` converter library — no change (the bug is in how we feed the converted model, not in conversion).
- Metal backend (separate project anyway) — already correct.
- `cpp/neuralnet/mlxtests.cpp` — the spec opts for integration coverage via `testgpuerror`; the bug is in dispatch glue, not in a unit-testable layer. Adding a stub helper purely to bolt a unit test on top would be over-engineering for four lines of strided indexing.

**Local-only, not committed:**
- `.claude/MLX_Validation.md` — refresh after the post-fix sweep per `CLAUDE.md`'s "When to re-run" checklist.

---

## Task 1: Reproduce the bug (manual, no commit)

**Files:** none modified — this is a verification step. Skip only if you have already observed the bug locally on this branch.

**Files:**
- Read: `cpp/neuralnet/mlxbackend.cpp:1747-1768`

- [ ] **Step 1: Build the MLX backend**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
cmake -G Ninja -DUSE_BACKEND=MLX
ninja
```

Expected: clean build producing `./katago` linked against the MLX backend.

- [ ] **Step 2: Confirm an Eigen reference exists for one of the standard models**

```bash
ls /Users/chinchangyang/Code/KataGo-MLX/cpp/tests/results/gpu_error_reference_files/ | head
```

Expected: at least one `*.json` file produced by a prior Eigen run via `rungpuerrortest.sh`. If empty, build with `-DUSE_BACKEND=EIGEN` first and run `rungpuerrortest.sh` once to populate it.

- [ ] **Step 3: Run `testgpuerror` on a non-19×19 case with the ANE backend**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
# Use whichever model has a matching reference under tests/results/gpu_error_reference_files/.
# Example: MODEL2 from rungpuerrortest.sh (version 4, b6c96), 13×13 board, requireMaxBoardSize=False.
./katago testgpuerror \
  -model tests/models/grun50-b6c96-s156348160-d118286860.txt.gz \
  -config configs/gtp_example.cfg \
  -boardsize 13 \
  -override-config "requireMaxBoardSize=False, deviceToUseThread0=100" \
  -reference-file tests/results/gpu_error_reference_files/<matching-file>.json
```

Expected: large winrate / score / ownership drift versus the reference (winrate error typically > 1%, often several %). This is the bug. **Capture the output** so you can compare post-fix.

- [ ] **Step 4: Sanity-check by switching to the MLX/GPU path**

Same command, but `deviceToUseThread0=0` (selects `MLX_MUX_GPU` per `mlxbackend.cpp:56-57`):

```bash
./katago testgpuerror \
  -model tests/models/grun50-b6c96-s156348160-d118286860.txt.gz \
  -config configs/gtp_example.cfg \
  -boardsize 13 \
  -override-config "requireMaxBoardSize=False, deviceToUseThread0=0" \
  -reference-file tests/results/gpu_error_reference_files/<matching-file>.json
```

Expected: drift in the normal band (winrate error typically < 0.01%, consistent with `.claude/MLX_Validation.md`). This confirms the bug is specific to the ANE path.

---

## Task 2: Fix the bug — single C++ commit

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp` (lines 1464–1525 for `InputBuffers`; lines 1700–1790 for `NeuralNet::getOutput`)

- [ ] **Step 1: Read the current `InputBuffers` struct**

Run: `cat cpp/neuralnet/mlxbackend.cpp | sed -n '1464,1525p'`

Expected: a struct with `spatialInput`, `globalInput`, `metaInput`, `policyResults`, etc., but **no** `userInputMaskBuffer` and **no** `singleMaskElts`. Confirm the layout matches the spec.

- [ ] **Step 2: Add `singleMaskElts` and `userInputMaskBuffer` to `InputBuffers`**

Find the member declaration block (currently `std::vector<float> spatialInput;` through `std::vector<float> ownershipResults;` at lines ~1477–1484) and insert a new member at the end of that block.

In the size-declaration block above the vectors (currently `singleInputElts` through `singleOwnershipResultElts` at ~1467–1475) add a new size constant.

The struct field additions:

```cpp
// In the "size" block, alongside singleInputElts etc:
size_t singleMaskElts;

// In the std::vector<float> block, alongside spatialInput etc:
std::vector<float> userInputMaskBuffer;
```

In the constructor body (currently ~1486–1518), after `singleOwnershipResultElts = (size_t)m.numOwnershipChannels * nnXLen * nnYLen;` add:

```cpp
singleMaskElts = (size_t)nnXLen * nnYLen;
```

And after `ownershipResults.resize(singleOwnershipResultElts * maxBatchSize);` add:

```cpp
userInputMaskBuffer.resize(singleMaskElts * maxBatchSize);
```

No need to zero-fill — the gather in Task 2 Step 3 fully rewrites every batch row before it is read.

- [ ] **Step 3: Add the per-row mask gather inside `NeuralNet::getOutput`**

Locate the per-row loop currently at `cpp/neuralnet/mlxbackend.cpp:1723-1745`. Immediately after the `SymmetryHelpers::copyInputsWithSymmetry(...)` call at line 1744 (and before the closing `}` of the loop at 1745) insert:

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

Note `rowSpatialInput` is the local pointer already in scope (declared at line 1724).

- [ ] **Step 4: Swap the ANE-branch mask pointer**

Locate `cpp/neuralnet/mlxbackend.cpp:1748-1768`. Replace the entire ANE branch body with:

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

(The `else` branch — the MLX/GPU path at lines 1769-1790 — is unchanged.)

- [ ] **Step 5: Build with the MLX backend**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
```

Expected: clean build, no warnings about unused variables, no errors. If `cmake` complains the build dir was configured for a different backend, run `cmake -G Ninja -DUSE_BACKEND=MLX` first.

- [ ] **Step 6: Smoke-test existing layer tests**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago runnnlayertests
```

Expected: existing MLX layer tests (Winograd, BatchNorm FP16, ConvLayer FP16, etc.) still pass. This catches accidental damage to the file-local structs or unrelated code paths.

- [ ] **Step 7: Re-run the Task 1 Step 3 repro to confirm the fix**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model tests/models/grun50-b6c96-s156348160-d118286860.txt.gz \
  -config configs/gtp_example.cfg \
  -boardsize 13 \
  -override-config "requireMaxBoardSize=False, deviceToUseThread0=100" \
  -reference-file tests/results/gpu_error_reference_files/<matching-file>.json
```

Expected: winrate / score / ownership drift now in the same band as the MLX/GPU run from Task 1 Step 4 (typically winrate error < 0.01%). If drift is still large, the gather is reading the wrong channel — double-check that `srcSpatial[i * numChannels]` matches NHWC layout (channel is the innermost dimension).

- [ ] **Step 8: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxbackend.cpp
git commit -m "$(cat <<'EOF'
MLX backend: feed real mask to ANE/CoreML path

The ANE dispatch in NeuralNet::getOutput was unconditionally allocating
an all-ones mask buffer and passing it to the Swift CoreMLComputeHandle.
That is only correct when the mlpackage was converted with
optimize_identity_mask=true (i.e., requireExactNNLen=true), where the
model ignores the buffer. With requireExactNNLen=false the converter
emits a model that actually consumes input_mask, so the all-ones buffer
silently mispredicted policy/value/score/ownership for any position
where the real mask had zeros (rectangular boards, boards smaller than
the NN frame, etc.).

Gather channel 0 of the NHWC spatial input into a persistent
userInputMaskBuffer member of InputBuffers on every batch row, and pass
that buffer to the Swift apply(). Mirrors how the Metal backend
populates userInputMaskBuffer after its NCHW conversion. The MLX/GPU
path is unchanged (it slices channel 0 internally via mx::slice).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: commit created on `mlx-backend-squash`.

---

## Task 3: Make `rungpuerrortest.sh` ANE mode backend-agnostic

**Files:**
- Modify: `cpp/rungpuerrortest.sh` (line ~11)

- [ ] **Step 1: Inspect the current `ane` override**

Run: `grep -n 'ane).*EXTRA_OVERRIDE' /Users/chinchangyang/Code/KataGo-MLX/cpp/rungpuerrortest.sh`

Expected: matches `ane) EXTRA_OVERRIDE=", metalDeviceToUseThread0=100"; SUFFIX="_ane" ;;` — the Metal-prefixed key.

- [ ] **Step 2: Switch to the backend-agnostic key**

In `cpp/rungpuerrortest.sh`, change the `ane)` case line from:

```bash
    ane) EXTRA_OVERRIDE=", metalDeviceToUseThread0=100"; SUFFIX="_ane" ;;
```

to:

```bash
    ane) EXTRA_OVERRIDE=", deviceToUseThread0=100"; SUFFIX="_ane" ;;
```

Rationale: `cpp/program/setup.cpp:209-210` falls back to the generic `deviceToUseThread<N>` key for any backend that doesn't have a more specific one wired in. Both the Metal backend and the MLX backend accept `100` as the ANE mux index (`metalbackend.h` defines `METAL_MUX_ANE = 100`; `mlxbackend.cpp:57` defines `MLX_MUX_ANE = 100`), so the same script now exercises whichever backend the binary was built with.

- [ ] **Step 3: Verify Metal compatibility is preserved**

Run: `grep -n 'metalDeviceToUseThread' /Users/chinchangyang/Code/KataGo-MLX/cpp/rungpuerrortest.sh`

Expected: no matches. (The previous Metal-specific key was the only reason a Metal-built binary needed special treatment; the generic key works there too.)

- [ ] **Step 4: Commit**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/rungpuerrortest.sh
git commit -m "$(cat <<'EOF'
rungpuerrortest: use backend-agnostic deviceToUseThread0 key

The 'ane' mode previously passed metalDeviceToUseThread0=100, which only
the Metal backend recognized. Switch to the generic deviceToUseThread0
fallback (cpp/program/setup.cpp:209-210) so the same script drives the
ANE path of whichever backend the binary was built with — both Metal's
METAL_MUX_ANE and MLX's MLX_MUX_ANE are defined as 100.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: commit created.

---

## Task 4: Full cross-backend sweep validation (manual, no commit)

This is the regression-coverage step. The script runs ~30 model × board-size configurations against the existing Eigen references.

**Files:** none modified.

- [ ] **Step 1: Run the sweep in MLX/GPU mode (baseline)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./rungpuerrortest.sh gpu 2>&1 | tee /tmp/mlx-gpu-sweep.log
```

Expected: the same numbers recorded in `.claude/MLX_Validation.md` for the GPU path (or close — minor variation across runs is normal). If a result file regresses noticeably vs. the snapshot, stop and investigate before continuing.

- [ ] **Step 2: Run the sweep in ANE mode**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./rungpuerrortest.sh ane 2>&1 | tee /tmp/mlx-ane-sweep.log
```

Expected: every invocation completes; result files appear under `cpp/tests/results/gpu_error_results/` with the `_ane` suffix. Compare each against its sibling Eigen reference — winrate / score / ownership drift should be in the same band as the GPU sweep (FP32 max winrate err typically < 0.01% per the existing validation snapshot; FP16 wider but bounded).

- [ ] **Step 3: Diff the ANE results against the GPU results**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp/tests/results/gpu_error_results
ls *_ane.json | while read f; do
  base=${f%_ane.json}
  echo "=== $base ==="
  diff <(jq -S . "$base.json") <(jq -S . "$f") | head -20
done
```

Expected: small numerical differences only (different code paths produce slightly different FP roundoff). No structural differences. Large divergences on any specific board size indicate the fix did not fully land for that configuration — re-read `mlxbackend.cpp` around the dispatch site.

- [ ] **Step 4: Update the local validation snapshot**

Edit `.claude/MLX_Validation.md` (untracked, Claude-local). Update:
- The "Last validated" date to today.
- The MLX-vs-Eigen drift numbers for both GPU and ANE configurations.
- Any new reproduction commands surfaced by the sweep.

Per `CLAUDE.md`: this file is *not* committed.

---

## Self-Review

**Spec coverage check** (against `docs/superpowers/specs/2026-05-24-mlx-ane-mask-buffer-fix-design.md`):

| Spec section | Plan task |
|---|---|
| §Problem (statement of the bug) | Task 1 Step 3 (pre-fix repro reproduces it) |
| §Goal (always pass real mask) | Task 2 Step 3 + Step 4 (gather + pointer swap) |
| §Non-Goals (no Swift ABI change, no converter change) | Honored — `coremlOnlyHandle.apply` ABI unchanged; no `katagocoreml` edits |
| §Data Flow §Before / After | Task 2 Steps 3–4 implement the "After" data flow exactly |
| §Components Touched > `InputBuffers` | Task 2 Step 2 |
| §Components Touched > `NeuralNet::getOutput` | Task 2 Steps 3–4 |
| §Error Handling & Invariants > NHWC enforced upstream | No-op — already throws at `mlxbackend.cpp:1685-1686` |
| §Error Handling & Invariants > buffer sized for `maxBatchSize` | Task 2 Step 2 sizes to `singleMaskElts * maxBatchSize` |
| §Testing > Pre-fix repro | Task 1 Step 3 |
| §Testing > Post-fix manual validation | Task 2 Step 7 + Task 4 |
| §Testing > Automated regression (script tweak) | Task 3 |
| §Rollout (single branch, no flag) | Two commits on `mlx-backend-squash`, no flag |

No gaps.

**Placeholder scan:** `<matching-file>.json` in Task 1 Step 3 and Task 2 Step 7 is the one intentional placeholder — the actual filename depends on which Eigen references exist in the user's checkout. The `ls` step in Task 1 Step 2 surfaces them. All other steps are concrete.

**Type / name consistency check:**
- `singleMaskElts` (Task 2 Step 2) → used as `inputBuffers->singleMaskElts` in Task 2 Step 3. ✓
- `userInputMaskBuffer` (Task 2 Step 2) → used as `inputBuffers->userInputMaskBuffer.data()` in Task 2 Steps 3–4. ✓
- `computeHandle->numInputChannels` (Task 2 Step 3) — confirmed to exist via earlier exploration (`mlxbackend.cpp` ComputeHandle members include numInputChannels). ✓
- `rowSpatialInput` (Task 2 Step 3) — declared at `mlxbackend.cpp:1724`. ✓
- `deviceToUseThread0` (Task 3) — confirmed in `setup.cpp:209-210`. ✓
- `MLX_MUX_ANE = 100` (Task 3 rationale) — confirmed in `mlxbackend.cpp:57`. ✓
- `METAL_MUX_ANE = 100` (Task 3 rationale) — confirmed in `metalbackend.h:174` area. ✓
