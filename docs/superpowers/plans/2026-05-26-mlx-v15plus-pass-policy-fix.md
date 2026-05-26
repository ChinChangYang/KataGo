# MLX v15+ Pass Policy Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the MLX backend's pass policy for modelVersion ≥ 15: implement the v15+ two-layer pass head (gpoolToPassMul → bias → activation → gpoolToPassMul2) in `PolicyHead`, and align the C++ per-row stride (`numPolicyPassChannels`) with the actual final pass output width that both Swift's per-batch offset and the new MLX/GPU graph produce. Restores correctness for v15+ models on MLX/GPU (always wrong before) and MLX/ANE batched paths (rows ≥ 1 garbage before).

**Architecture:** All three changes (struct fields, `apply()` body, `numPolicyPassChannels` initializer) are coupled and land in one C++ commit — any single one alone breaks the memcpy size invariant at `mlxbackend.cpp:1170`. A second smaller commit extends `runMLXCoreMLSmokeTest` to exercise the batched ANE path and compare the pass position so a future regression of this class fails `./katago runnnlayertests` rather than only being caught by `testgpuerror`.

**Tech Stack:** C++17 (uses `std::optional<>`), MLX (Apple's array framework), CoreML/ANE via Swift bridge, KataGo's `testgpuerror` and `runnnlayertests` commands, CMake/Ninja.

**Spec:** `docs/superpowers/specs/2026-05-26-mlx-v15plus-pass-policy-fix-design.md`

---

## File Structure

**Modified files:**

| File | Responsibility | Lines touched |
|------|---------------|---------------|
| `cpp/neuralnet/mlxbackend.cpp` | (1) `#include <optional>`. (2) `PolicyHead` struct: add `gpoolToPassBias`, `passActivationType`, `gpoolToPassMul2` fields and constructor initializers gated on `modelVersion >= 15`. (3) `PolicyHead::apply()`: extend the pass branch with bias + activation + second matmul when `modelVersion >= 15`. (4) `Model::numPolicyPassChannels` initializer: pick `gpoolToPassMul2.outChannels` for v15+, otherwise `gpoolToPassMul.outChannels`. Update the surrounding 5-line comment. | ~35 lines net add across 4 edit sites |
| `cpp/neuralnet/mlxtests.cpp` | Extend the existing parity block in `runMLXCoreMLSmokeTest`: build handles with `maxBatchSize=2`, run `getOutput` with two NNResultBufs per call, and assert per-row pass-position parity (`policyProbs[nnXLen*nnYLen]`) within FP16 tolerance for both rows. | ~40 lines net add |

**Untouched on purpose:**
- `cpp/external/katagocoreml/` (the mlpackage converter) — already correct; mlpackage produces final pass output. Symptom 2 in the spec proves this (row 0 reads correct data; the bug is on the C++ side's stride assumption).
- `cpp/neuralnet/metalbackend.swift` — Swift's per-batch offset (`batchIndex * numPolicyChannels`) is already correct for the actual MLMultiArray width. The C++ side needs to align with it, not vice versa.
- `cpp/neuralnet/metalbackend.cpp` — the Metal backend already implements v15+ pass correctly via its MPSGraph path.
- `cpp/neuralnet/desc.{h,cpp}` — `PolicyHeadDesc` already parses all v15+ fields.
- The standing `gpu_error_reference_files/` set — adding a v15+ entry to the continuous sweep is a separate follow-up per the spec's "Future Work" section.

**Local-only, not committed:**
- `.claude/MLX_Validation.md` — refresh with post-fix v15+ ANE & MLX/GPU numbers, correct the 2026-05-25 snapshot's misattribution of the 25% size-19 figure to "FP16 noise" (it's this bug).

**Pre-existing WIP** (`git status` shows these unstaged before this work; do not stage them):
- `cpp/CMakeLists.txt`, `cpp/neuralnet/mlxtests.cpp` (if any residual WIP), `cpp/eigen_reference_*.json`, `cpp/katago.dSYM/`, `cpp/tests/results/gpu_error_reference_files/`, `cpp/tests/results/gpu_error_results/`, various plan/spec files under `docs/superpowers/`, `CLAUDE.md`, `.claude/`. None of this plan's commits should touch any of these.

---

## Task 1: Capture pre-fix baseline (manual, no commit)

**Files:** none modified — verification step. Skip only if you have already captured the ~41% / ~72% topPolicyDelta locally on this branch within the last hour.

- [ ] **Step 1: Confirm the model and reference file are present**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ls -la models/b5c192nbt-v16test.bin.gz \
       tests/results/gpu_error_reference_files/b5c192nbt-v16test.bin.gz_sizerect.txt \
       tests/results/gpu_error_reference_files/b5c192nbt-v16test.bin.gz_size19.txt
```

Expected: all three files exist. If `tests/results/gpu_error_reference_files/b5c192nbt-v16test.bin.gz_sizerect.txt` is missing, stop and regenerate it via the Eigen path documented in `CLAUDE.md` under "GPU Error Testing" before proceeding.

- [ ] **Step 2: Build the MLX backend at current HEAD**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
cmake -G Ninja -DUSE_BACKEND=MLX
ninja
```

Expected: clean build producing `./katago` linked against the MLX backend. Build time is ~1 minute on warm cache.

- [ ] **Step 3: Run the ANE rectangle batched test (the broken case)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model models/b5c192nbt-v16test.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize rectangle \
  -override-config "requireMaxBoardSize=False, maxBatchSize=11, deviceToUseThread0=100" \
  -reference-file tests/results/gpu_error_reference_files/b5c192nbt-v16test.bin.gz_sizerect.txt \
  > /tmp/v15plus_rect_ane_before.txt 2>&1
grep "topPolicyDelta\|policyKLDiv" /tmp/v15plus_rect_ane_before.txt | head -10
```

Expected: roughly these numbers (will vary slightly run-to-run):
```
fp32 error vs reference topPolicyDelta:     ~0.00004%   ~0.00009%   ~0.00016%   ~0.00022%
batched fp32 error vs reference topPolicyDelta: ~0.54%  ~0.44%      ~15%        ~41%
batched fp32 error vs reference policyKLDiv:    ~0.007  ~0.008      ~0.13       ~0.44
```

The load-bearing signal: **batched fp32 topPolicyDelta max around 40%, avg around 0.5%** (heavy-tail). Unbatched FP32 is clean (max < 0.001%). Keep `/tmp/v15plus_rect_ane_before.txt` for the post-fix diff.

If batched fp32 max is < 1%, the bug is not reproducing — stop and investigate. Possible cause: someone changed `numPolicyPassChannels` or `PolicyHead` since this plan was written.

- [ ] **Step 4: Run the MLX/GPU rectangle test (the always-broken case for v15+)**

Same as Step 3 but drop `deviceToUseThread0=100` (so the run uses the MLX/GPU path, not ANE):

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model models/b5c192nbt-v16test.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize rectangle \
  -override-config "requireMaxBoardSize=False, maxBatchSize=11" \
  -reference-file tests/results/gpu_error_reference_files/b5c192nbt-v16test.bin.gz_sizerect.txt \
  > /tmp/v15plus_rect_gpu_before.txt 2>&1
grep "topPolicyDelta\|policyKLDiv" /tmp/v15plus_rect_gpu_before.txt | head -10
```

Expected: `fp32 error vs reference topPolicyDelta` max **around 72%, avg around 1.5%** (heavy-tail; both unbatched and batched, since MLX/GPU's pass is always wrong for v15+). Keep `/tmp/v15plus_rect_gpu_before.txt` for the post-fix diff.

- [ ] **Step 5: Confirm v11 baseline is currently clean (so we know what "no regression" looks like)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize 19 \
  -override-config "requireMaxBoardSize=True, deviceToUseThread0=100" \
  -reference-file tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt \
  > /tmp/v11_size19_ane_before.txt 2>&1
grep "topPolicyDelta" /tmp/v11_size19_ane_before.txt | head -6
```

Expected: all `topPolicyDelta` lines max < 0.001% (v11 has `numPolicyChannels=1`, so doesn't enter the optimism path or the buggy pass path on either backend). This run should be unchanged by this fix; if it isn't, the fix touched the wrong code path.

---

## Task 2: Apply the three-part fix to mlxbackend.cpp (one atomic commit)

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp` at four sites:
  - Add `#include <optional>` to the standard-library include block
  - `PolicyHead` struct (around line 880-942): add fields + ctor initializers, extend `apply()`
  - `Model::numPolicyPassChannels` initializer (line 1043) + the 5-line comment above it (lines 1017-1021)

This task lands all three coupled C++ changes in one commit. Per the spec, any one alone breaks the memcpy size invariant.

- [ ] **Step 1: Add `#include <optional>` to the standard-library include block**

Open `cpp/neuralnet/mlxbackend.cpp`. The existing includes go up through `<cmath>` at line 37. Add `<optional>` alongside the other STL includes — alphabetical placement after `<mutex>` and before `<random>` keeps it grouped. The edit:

```cpp
#include <memory>
#include <mutex>
#include <optional>
#include <map>
#include <tuple>
#include <random>
```

becomes the include block. If the existing ordering isn't strictly alphabetical (it isn't — `<memory>`, `<mutex>`, `<map>`, `<tuple>`, `<random>` is the current order), insert `<optional>` next to `<mutex>` per the same pragmatic ordering the file already uses.

Apply this edit:

Old text to find (exact, including indentation):

```
#include <memory>
#include <mutex>
#include <map>
```

New text to replace with:

```
#include <memory>
#include <mutex>
#include <optional>
#include <map>
```

- [ ] **Step 2: Replace the `PolicyHead` struct field declarations and constructor initializer list**

Locate the struct definition around line 880 (`struct PolicyHead {`). Replace lines 880-909 (struct header through the end of the constructor's initializer list and its empty body `{}`) with the path-aware version.

Old text to find (exact, including indentation):

```cpp
// Policy Head
struct PolicyHead {
  const string name;
  const int modelVersion;
  const ConvLayer p1Conv;
  const ConvLayer g1Conv;
  const BatchNormLayer g1BN;
  const MatMulLayer gpoolToBiasMul;
  const BatchNormLayer p1BN;
  const ConvLayer p2Conv;
  const MatMulLayer gpoolToPassMul;

  PolicyHead() = delete;
  PolicyHead(const PolicyHead&) = delete;
  PolicyHead& operator=(const PolicyHead&) = delete;

  PolicyHead(const PolicyHeadDesc& desc,
             const MLXWinograd::InputTransform& inCfg,
             const MLXWinograd::OutputUntransform& outCfg,
             bool useFP16 = false)
    : name(desc.name),
      modelVersion(desc.modelVersion),
      p1Conv(desc.p1Conv, inCfg, outCfg, useFP16),
      g1Conv(desc.g1Conv, inCfg, outCfg, useFP16),
      g1BN(desc.g1BN, desc.g1Activation.activation, useFP16),
      gpoolToBiasMul(desc.gpoolToBiasMul, useFP16),
      p1BN(desc.p1BN, desc.p1Activation.activation, useFP16),
      p2Conv(desc.p2Conv, inCfg, outCfg, useFP16),
      gpoolToPassMul(desc.gpoolToPassMul, useFP16)
  {}
```

New text to replace with:

```cpp
// Policy Head
struct PolicyHead {
  const string name;
  const int modelVersion;
  const ConvLayer p1Conv;
  const ConvLayer g1Conv;
  const BatchNormLayer g1BN;
  const MatMulLayer gpoolToBiasMul;
  const BatchNormLayer p1BN;
  const ConvLayer p2Conv;
  const MatMulLayer gpoolToPassMul;
  // v15+ two-layer pass head: gpoolToPassMul (input -> hidden) ->
  // gpoolToPassBias -> passActivation -> gpoolToPassMul2 (hidden -> output).
  // Pre-v15 models use a single matmul (gpoolToPassMul: input -> output) and
  // these three fields stay empty / zero. Mirrors PolicyHeadDesc parsing in
  // desc.cpp:1289-1299 and Metal's MPSGraph implementation in
  // metalbackend.cpp:298-315.
  const std::optional<MatBiasLayer> gpoolToPassBias;
  const int passActivationType;
  const std::optional<MatMulLayer> gpoolToPassMul2;

  PolicyHead() = delete;
  PolicyHead(const PolicyHead&) = delete;
  PolicyHead& operator=(const PolicyHead&) = delete;

  PolicyHead(const PolicyHeadDesc& desc,
             const MLXWinograd::InputTransform& inCfg,
             const MLXWinograd::OutputUntransform& outCfg,
             bool useFP16 = false)
    : name(desc.name),
      modelVersion(desc.modelVersion),
      p1Conv(desc.p1Conv, inCfg, outCfg, useFP16),
      g1Conv(desc.g1Conv, inCfg, outCfg, useFP16),
      g1BN(desc.g1BN, desc.g1Activation.activation, useFP16),
      gpoolToBiasMul(desc.gpoolToBiasMul, useFP16),
      p1BN(desc.p1BN, desc.p1Activation.activation, useFP16),
      p2Conv(desc.p2Conv, inCfg, outCfg, useFP16),
      gpoolToPassMul(desc.gpoolToPassMul, useFP16),
      gpoolToPassBias(desc.modelVersion >= 15
        ? std::optional<MatBiasLayer>(std::in_place, desc.gpoolToPassBias, useFP16)
        : std::nullopt),
      passActivationType(desc.modelVersion >= 15 ? desc.passActivation.activation : 0),
      gpoolToPassMul2(desc.modelVersion >= 15
        ? std::optional<MatMulLayer>(std::in_place, desc.gpoolToPassMul2, useFP16)
        : std::nullopt)
  {}
```

Why `std::in_place` rather than `std::make_optional<...>(...)`: the underlying types (`MatBiasLayer`, `MatMulLayer`) declare `operator=` and copy-ctor as `= delete` (`mlxbackend.cpp:502-503`, similarly for `MatMulLayer`), so `make_optional`'s decay-copy path won't compile. `std::in_place` forwards constructor args directly into the optional's storage without copy.

- [ ] **Step 3: Extend `PolicyHead::apply()` for v15+ two-layer pass**

In the same `PolicyHead` struct, replace the single-line pass computation in `apply()` with the path-aware version. Locate lines 938-942 (currently `// Pass policy` through the `return {policyPass, policy};`).

Old text to find (exact):

```cpp
    // Pass policy
    mx::array policyPass = gpoolToPassMul.apply(pooledFlat);

    return {policyPass, policy};
```

New text to replace with:

```cpp
    // Pass policy: pre-v15 is a single matmul (pooled -> output). v15+ is a
    // two-layer MLP (pooled -> hidden, + bias, activation, hidden -> output).
    // Mirrors PolicyHeadDesc parsing in desc.cpp:1289-1299 and Metal's MPSGraph
    // implementation in metalbackend.cpp:298-315.
    mx::array policyPass = gpoolToPassMul.apply(pooledFlat);
    if(modelVersion >= 15) {
      policyPass = gpoolToPassBias->apply(policyPass);
      policyPass = applyActivation(policyPass, passActivationType);
      policyPass = gpoolToPassMul2->apply(policyPass);
    }

    return {policyPass, policy};
```

`applyActivation` is the existing helper at `mlxbackend.cpp:250` and handles `ACTIVATION_RELU`, `ACTIVATION_MISH`, `ACTIVATION_MISH_SCALE8` (asserts), `ACTIVATION_IDENTITY`, and an identity default. `MatBiasLayer::apply` exists at `mlxbackend.cpp:517-519` and returns `input + bias`. No new helpers needed.

- [ ] **Step 4: Update `Model::numPolicyPassChannels` initializer + the comment above it**

Locate the field declaration around line 1017-1022:

```cpp
  // Pass-policy output width — `gpoolToPassMul.outChannels` may exceed
  // numPolicyChannels for human-SL nets (humanv0: 48 vs 2). Only the first 1-2
  // values are consumed by NNOutput, but the per-row stride in our buffers
  // must match the real tensor width, otherwise batched memcpy and extraction
  // truncate and misalign rows beyond row 0.
  const int numPolicyPassChannels;
```

Replace with (correct the comment — the prior fix was wrong; the per-row stride must match the *final* pass output width, not the hidden width):

```cpp
  // Pass-policy output width. For v15+ models the pass head is two-layer:
  // gpoolToPassMul (input -> hidden) -> bias -> activation -> gpoolToPassMul2
  // (hidden -> output). The actual final output width — and the per-row stride
  // Swift's extractOutputs uses for its writes (metalbackend.swift:316:
  // batchIndex * numPolicyChannels) — is gpoolToPassMul2.outChannels, which by
  // construction (desc.cpp:1342-1343) equals numPolicyChannels. Pre-v15 models
  // have a single matmul (gpoolToPassMul: input -> output) and the output width
  // is gpoolToPassMul.outChannels = numPolicyChannels (desc.cpp:1348-1349).
  // Using gpoolToPassMul.outChannels for v15+ was the prior bug: it is the
  // hidden width, not the output width, and rows >= 1 in batched ANE reads
  // landed on uninitialized memory.
  const int numPolicyPassChannels;
```

Then locate the initializer around line 1042-1043:

Old text to find (exact):

```cpp
      numPolicyChannels(desc.numPolicyChannels),
      numPolicyPassChannels(desc.policyHead.gpoolToPassMul.outChannels),
```

New text to replace with:

```cpp
      numPolicyChannels(desc.numPolicyChannels),
      numPolicyPassChannels(desc.modelVersion >= 15
                              ? desc.policyHead.gpoolToPassMul2.outChannels
                              : desc.policyHead.gpoolToPassMul.outChannels),
```

The assertion at `mlxbackend.cpp:1868`
(`singlePolicyPassResultElts == numPolicyPassChannels`) still holds because
`singlePolicyPassResultElts` is set from the same field
(`mlxbackend.cpp:1533`) — both will now reflect the actual output width.

- [ ] **Step 5: Rebuild and check for warnings**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja 2>&1 | tee /tmp/build_v15plus_pass_fix.txt | tail -20
```

Expected: clean recompile of `mlxbackend.cpp.o` and re-link. Exit 0. The build may print "X warnings generated" — only the existing 2 unrelated warnings should appear (these are present at baseline; check `tail -20` doesn't show new ones).

If you see:
- "no matching function for call to 'std::optional<MatBiasLayer>::optional'" — re-check that the `std::in_place` placement matches the snippet above (forwarding into the in-place constructor).
- "use of deleted function 'MatMulLayer::MatMulLayer(const MatMulLayer&)'" — same root cause; ensure no `std::make_optional` or implicit copy slipped in.
- "'gpoolToPassMul2' was not declared in this scope" inside `apply()` — confirm the field declaration is *before* the constructor in the struct body, as written in Step 2.
- "applyActivation' was not declared in this scope" — the helper is defined at file-scope at line 250, callable from inside `PolicyHead::apply()` without qualification. If this fires the struct moved relative to the helper; revert to the original location.

If the build fails, stop and resolve before proceeding.

- [ ] **Step 6: Run the v16 ANE rectangle batched test from Task 1, Step 3**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model models/b5c192nbt-v16test.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize rectangle \
  -override-config "requireMaxBoardSize=False, maxBatchSize=11, deviceToUseThread0=100" \
  -reference-file tests/results/gpu_error_reference_files/b5c192nbt-v16test.bin.gz_sizerect.txt \
  > /tmp/v15plus_rect_ane_after.txt 2>&1
grep "topPolicyDelta\|policyKLDiv" /tmp/v15plus_rect_ane_after.txt | head -10
```

Expected: `batched fp32 error vs reference topPolicyDelta` max **≤ ~1%** (down from ~41%). `batched fp32 ... policyKLDiv` max **≤ ~0.01** (down from ~0.44). `fp32` (unbatched) lines stay at ~0%, unchanged. The load-bearing pass criterion for the fix.

If `topPolicyDelta` max is still > 5%, the fix didn't take effect on the ANE path. Re-read `mlxbackend.cpp:1043` and confirm the `modelVersion >= 15 ? ... : ...` ternary applied. Re-check that `ninja` actually recompiled (look for `Linking` line in the build output).

- [ ] **Step 7: Run the v16 MLX/GPU rectangle test from Task 1, Step 4**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model models/b5c192nbt-v16test.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize rectangle \
  -override-config "requireMaxBoardSize=False, maxBatchSize=11" \
  -reference-file tests/results/gpu_error_reference_files/b5c192nbt-v16test.bin.gz_sizerect.txt \
  > /tmp/v15plus_rect_gpu_after.txt 2>&1
grep "topPolicyDelta\|policyKLDiv" /tmp/v15plus_rect_gpu_after.txt | head -10
```

Expected: `fp32 error vs reference topPolicyDelta` max **≤ ~1%** (down from ~72%). Same for batched fp32. The MLX/GPU path now produces correct pass logits (previously always wrong for v15+).

If `topPolicyDelta` max is still > 5%, the `apply()` change didn't take effect on the MLX/GPU path. Re-check Step 3 — the `if(modelVersion >= 15) { ... }` block must actually execute the three appended lines.

- [ ] **Step 8: Re-confirm v11 baseline is unchanged (no regression)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize 19 \
  -override-config "requireMaxBoardSize=True, deviceToUseThread0=100" \
  -reference-file tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt \
  > /tmp/v11_size19_ane_after.txt 2>&1
diff /tmp/v11_size19_ane_before.txt /tmp/v11_size19_ane_after.txt | head -10
```

Expected: numerical lines match within run-to-run noise (timing log lines may differ — that's fine). Specifically, the `topPolicyDelta` and `policyKLDiv` lines should be identical or differ only in the last digit. v11's `numPolicyChannels = 1` means the bug branch is never entered on either backend; the fix's `if(modelVersion >= 15)` gate keeps this code path untouched.

If `topPolicyDelta` regresses (e.g., 0.001% → 5%), the fix accidentally affected the pre-v15 path. Likely cause: the ternary in Step 4 reads from a desc field that the pre-v15 parser left in an undefined state. Stop and re-examine.

- [ ] **Step 9: Stage and commit the fix**

The pre-existing WIP listed in the File Structure section above must remain unstaged. Stage only `cpp/neuralnet/mlxbackend.cpp`:

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxbackend.cpp
git status --short
```

Expected: `M cpp/neuralnet/mlxbackend.cpp` shows in green (staged). The pre-existing WIP shows in red (unstaged). If `cpp/neuralnet/mlxbackend.cpp` shows in both (split staged/unstaged), stop — you have unrelated edits that need to be set aside first via `git stash push -- cpp/neuralnet/mlxbackend.cpp` and re-applied later.

```bash
git commit -m "$(cat <<'EOF'
MLX backend: implement v15+ two-layer pass head

PolicyHead implemented only the first matmul of the v15+ pass head
(gpoolToPassMul), missing bias, activation, and gpoolToPassMul2 -- so
MLX/GPU's pass output was silently the hidden activations for v15+
models. numPolicyPassChannels was also derived from
gpoolToPassMul.outChannels (the hidden width, e.g., 48 for b5c192) rather
than the final output width (= numPolicyChannels). For MLX/ANE the
mlpackage produces the correct final pass output but C++ read it at the
wrong stride: row 0 happened to land on Swift's writes, rows >= 1 read
uninitialized memory. Surfaces on testgpuerror as ~4% of positions
(those where Eigen's argmax is pass) with topPolicyDelta up to 72%
(MLX/GPU) or 41% (ANE batched).

Mirrors Metal's design (metalbackend.cpp:298-315): add the v15+ pass
layers to MLX PolicyHead, do the full two-layer pass in apply(), and
use gpoolToPassMul2.outChannels for the stride on v15+. Pre-v15 path
unchanged. The three changes are coupled: any one alone breaks the
memcpy size invariant in Model::apply.

Validation: b5c192 v16 rectangle ANE batched fp32 topPolicyDelta max
dropped from 41% to <1%; MLX/GPU dropped from 72% to <1%. v11
baseline (size19 ANE) unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds. `git status --short` still shows the pre-existing WIP files (unstaged).

---

## Task 3: Extend `runMLXCoreMLSmokeTest` with batched + pass-position parity

**Files:**
- Modify: `cpp/neuralnet/mlxtests.cpp` — the existing parity block (around line 1226-1373) currently builds handles with `maxBatchSize=1` and asserts top-1 spatial parity. Extend it to (a) use `maxBatchSize=2`, (b) submit two NNResultBufs to `getOutput`, (c) assert per-row pass-position parity.

The change must coexist with the existing v12+ spatial-stride regression check; both shapes of bug should fail the smoke test.

- [ ] **Step 1: Replace the parity block's handle/inputBuffers/result allocation with a batched-2 version**

Locate the lines inside the `else` branch in `runMLXCoreMLSmokeTest` (around line 1251-1322). The block currently creates a single `bufAne` / `bufGpu`, runs `getOutput(...,1,...)`, and checks top-1 spatial parity.

Replace it with a version that exercises batched ANE (the bug-firing code path) and adds pass-position assertions. The minimal change: bump `maxBatchSize` from 1 to 2 in both `createComputeHandle` calls (the ANE handle at line 1204 and the GPU handle at line 1253) and in both `createInputBuffers` calls (line 1221 and 1261); add a second NNResultBuf populated with the same input (deterministic empty board, so identical to row 0); pass both to `getOutput` with `numBatchEltsFilled=2`; add pass-position equality assertions across rows and across paths.

First, locate the ANE-side handle and input buffers allocation at lines 1204-1222:

Old text to find (exact):

```cpp
  ComputeHandle* handle = NeuralNet::createComputeHandle(
    context,
    loadedModel,
    /*logger=*/nullptr,
    /*maxBatchSize=*/1,
    /*requireExactNNLen=*/true,
    /*inputsUseNHWC=*/true,
    /*gpuIdxForThisThread=*/MLX_MUX_ANE_LOCAL,
    /*serverThreadIdx=*/0);

  // Verify the ANE-path invariants the constructor was supposed to establish.
  // isUsingFP16 is a public NeuralNet API; struct-internal checks (gpuIdx,
  // coremlOnlyHandle, model, inputBuffers->maxBatchSize) are delegated to a
  // helper in mlxbackend.cpp because ComputeHandle and InputBuffers are
  // file-local there (not in any public header).
  testAssert(NeuralNet::isUsingFP16(handle) == true);  // useFP16Mode=Auto → true

  InputBuffers* inputBuffers = NeuralNet::createInputBuffers(
    loadedModel, /*maxBatchSize=*/1, /*nnXLen=*/19, /*nnYLen=*/19);
```

New text to replace with (only the two `/*maxBatchSize=*/1` literals change to `2`; the comment about invariants stays):

```cpp
  // maxBatchSize=2 (not 1) so that the parity check below exercises the
  // batched ANE path where the v15+ pass-policy stride bug fires. Single-batch
  // calls only ever read row 0, which happens to land inside Swift's writes
  // regardless of the C++-side stride assumption; rows >= 1 are what catches
  // the bug class. See docs/superpowers/specs/2026-05-26-mlx-v15plus-pass-
  // policy-fix-design.md "Symptom 2".
  ComputeHandle* handle = NeuralNet::createComputeHandle(
    context,
    loadedModel,
    /*logger=*/nullptr,
    /*maxBatchSize=*/2,
    /*requireExactNNLen=*/true,
    /*inputsUseNHWC=*/true,
    /*gpuIdxForThisThread=*/MLX_MUX_ANE_LOCAL,
    /*serverThreadIdx=*/0);

  // Verify the ANE-path invariants the constructor was supposed to establish.
  // isUsingFP16 is a public NeuralNet API; struct-internal checks (gpuIdx,
  // coremlOnlyHandle, model, inputBuffers->maxBatchSize) are delegated to a
  // helper in mlxbackend.cpp because ComputeHandle and InputBuffers are
  // file-local there (not in any public header).
  testAssert(NeuralNet::isUsingFP16(handle) == true);  // useFP16Mode=Auto → true

  InputBuffers* inputBuffers = NeuralNet::createInputBuffers(
    loadedModel, /*maxBatchSize=*/2, /*nnXLen=*/19, /*nnYLen=*/19);
```

- [ ] **Step 2: Bump the GPU-side handle/inputBuffers from maxBatchSize=1 to 2**

Locate the GPU-side handle creation around lines 1253-1262 (inside the same `else` branch).

Old text to find (exact):

```cpp
    ComputeHandle* gpuHandle = NeuralNet::createComputeHandle(
      context, loadedModel,
      /*logger=*/nullptr,
      /*maxBatchSize=*/1,
      /*requireExactNNLen=*/true,
      /*inputsUseNHWC=*/true,
      /*gpuIdxForThisThread=*/0,  // MLX/GPU
      /*serverThreadIdx=*/1);
    InputBuffers* gpuInputBuffers = NeuralNet::createInputBuffers(
      loadedModel, /*maxBatchSize=*/1, /*nnXLen=*/19, /*nnYLen=*/19);
```

New text to replace with:

```cpp
    ComputeHandle* gpuHandle = NeuralNet::createComputeHandle(
      context, loadedModel,
      /*logger=*/nullptr,
      /*maxBatchSize=*/2,
      /*requireExactNNLen=*/true,
      /*inputsUseNHWC=*/true,
      /*gpuIdxForThisThread=*/0,  // MLX/GPU
      /*serverThreadIdx=*/1);
    InputBuffers* gpuInputBuffers = NeuralNet::createInputBuffers(
      loadedModel, /*maxBatchSize=*/2, /*nnXLen=*/19, /*nnYLen=*/19);
```

- [ ] **Step 3: Add a second NNResultBuf and second NNOutput for row 1**

Locate the existing NNResultBuf and NNOutput declarations around lines 1293-1322. Replace the single-row construction with a two-row version. Both rows get the same input (deterministic empty board), so per-row outputs should be identical within FP16 noise. A stride bug producing different rows is the diagnostic.

Old text to find (exact):

```cpp
    NNResultBuf bufAne;
    NNResultBuf bufGpu;
    bufAne.symmetry = 0;
    bufGpu.symmetry = 0;
    bufAne.policyOptimism = 0.0;
    bufGpu.policyOptimism = 0.0;
    bufAne.hasRowMeta = false;  // safe: parity branch is gated on
    bufGpu.hasRowMeta = false;  // metaEncoderVersion==0 above.
    bufAne.rowSpatialBuf.resize(NNInputs::NUM_FEATURES_SPATIAL_V7 * 19 * 19);
    bufAne.rowGlobalBuf.resize(NNInputs::NUM_FEATURES_GLOBAL_V7);
    NNInputs::fillRowV7(
      board, hist, nextPla, nnInputParams,
      /*nnXLen=*/19, /*nnYLen=*/19, /*useNHWC=*/true,
      bufAne.rowSpatialBuf.data(), bufAne.rowGlobalBuf.data());
    bufGpu.rowSpatialBuf = bufAne.rowSpatialBuf;
    bufGpu.rowGlobalBuf  = bufAne.rowGlobalBuf;

    // NNOutput::policyProbs is a fixed-size float[NNPos::MAX_NN_POLICY_SIZE]
    // (nninputs.h:148); no heap allocation needed.
    NNOutput outAne;
    NNOutput outGpu;
    outAne.nnXLen = outGpu.nnXLen = 19;
    outAne.nnYLen = outGpu.nnYLen = 19;
    outAne.whiteOwnerMap = nullptr;
    outGpu.whiteOwnerMap = nullptr;

    std::vector<NNResultBuf*> inBufsAne = { &bufAne };
    std::vector<NNOutput*> outsAne = { &outAne };
    std::vector<NNResultBuf*> inBufsGpu = { &bufGpu };
    std::vector<NNOutput*> outsGpu = { &outGpu };

    NeuralNet::getOutput(handle, inputBuffers,
                         /*numBatchEltsFilled=*/1, inBufsAne.data(), outsAne);
    NeuralNet::getOutput(gpuHandle, gpuInputBuffers,
                         1, inBufsGpu.data(), outsGpu);
```

New text to replace with:

```cpp
    // Two NNResultBufs per path: both filled with the SAME deterministic empty
    // board. Per-row outputs must be identical within FP16 noise (the model is
    // deterministic). A stride bug producing different per-row outputs (e.g.,
    // row 0 correct, row 1 garbage) fails the per-row parity assertions below.
    NNResultBuf bufAne0, bufAne1;
    NNResultBuf bufGpu0, bufGpu1;
    auto initBuf = [&](NNResultBuf& buf) {
      buf.symmetry = 0;
      buf.policyOptimism = 0.0;
      buf.hasRowMeta = false;  // safe: parity branch is gated on
                               // metaEncoderVersion==0 above.
      buf.rowSpatialBuf.resize(NNInputs::NUM_FEATURES_SPATIAL_V7 * 19 * 19);
      buf.rowGlobalBuf.resize(NNInputs::NUM_FEATURES_GLOBAL_V7);
    };
    initBuf(bufAne0); initBuf(bufAne1);
    initBuf(bufGpu0); initBuf(bufGpu1);

    NNInputs::fillRowV7(
      board, hist, nextPla, nnInputParams,
      /*nnXLen=*/19, /*nnYLen=*/19, /*useNHWC=*/true,
      bufAne0.rowSpatialBuf.data(), bufAne0.rowGlobalBuf.data());
    // All four bufs share the same input bytes.
    bufAne1.rowSpatialBuf = bufAne0.rowSpatialBuf;
    bufAne1.rowGlobalBuf  = bufAne0.rowGlobalBuf;
    bufGpu0.rowSpatialBuf = bufAne0.rowSpatialBuf;
    bufGpu0.rowGlobalBuf  = bufAne0.rowGlobalBuf;
    bufGpu1.rowSpatialBuf = bufAne0.rowSpatialBuf;
    bufGpu1.rowGlobalBuf  = bufAne0.rowGlobalBuf;

    // NNOutput::policyProbs is a fixed-size float[NNPos::MAX_NN_POLICY_SIZE]
    // (nninputs.h:148); no heap allocation needed.
    NNOutput outAne0, outAne1, outGpu0, outGpu1;
    for(NNOutput* o : {&outAne0, &outAne1, &outGpu0, &outGpu1}) {
      o->nnXLen = 19;
      o->nnYLen = 19;
      o->whiteOwnerMap = nullptr;
    }

    std::vector<NNResultBuf*> inBufsAne = { &bufAne0, &bufAne1 };
    std::vector<NNOutput*> outsAne = { &outAne0, &outAne1 };
    std::vector<NNResultBuf*> inBufsGpu = { &bufGpu0, &bufGpu1 };
    std::vector<NNOutput*> outsGpu = { &outGpu0, &outGpu1 };

    NeuralNet::getOutput(handle, inputBuffers,
                         /*numBatchEltsFilled=*/2, inBufsAne.data(), outsAne);
    NeuralNet::getOutput(gpuHandle, gpuInputBuffers,
                         2, inBufsGpu.data(), outsGpu);
```

- [ ] **Step 4: Update the top-1 spatial parity check to use the row-0 outputs (and add row-1 parity)**

Locate the existing top-1 spatial check around lines 1337-1364. The variables `outAne` and `outGpu` are gone; references must change to `outAne0` and `outGpu0` (row 0). Also add an assertion that the ANE row-1 top-1 matches ANE row-0 top-1, since identical inputs must produce identical outputs (FP16 noise tolerated).

Old text to find (exact):

```cpp
    // Top-1 policy index parity. Strict argmax (first-of-max via >) would
    // be flaky if two positions sit within FP16 noise of each other and
    // the two backends round them in opposite directions. Detect that
    // case and accept only when BOTH backends consider the two positions
    // tied. A stride-scramble regression makes their probabilities
    // differ by orders of magnitude (v16 pre-fix: topPolicyDelta 0.98,
    // KL 14), not by 1e-3, so this tolerance does not weaken scrambling
    // detection.
    int top1Ane = 0, top1Gpu = 0;
    for(int i = 1; i < 19 * 19; i++) {
      if(outAne.policyProbs[i] > outAne.policyProbs[top1Ane]) top1Ane = i;
      if(outGpu.policyProbs[i] > outGpu.policyProbs[top1Gpu]) top1Gpu = i;
    }
    if(top1Ane != top1Gpu) {
      // FP16 noise per channel is O(1e-3) on softmax outputs. A genuine
      // tie at the top means both backends rate both positions within
      // that envelope; a scramble fails this check by a wide margin.
      constexpr float kFP16PolicyTieTol = 1e-3f;
      float aneAtAne = outAne.policyProbs[top1Ane];
      float aneAtGpu = outAne.policyProbs[top1Gpu];
      float gpuAtAne = outGpu.policyProbs[top1Ane];
      float gpuAtGpu = outGpu.policyProbs[top1Gpu];
      bool aneTied = std::abs(aneAtAne - aneAtGpu) < kFP16PolicyTieTol;
      bool gpuTied = std::abs(gpuAtAne - gpuAtGpu) < kFP16PolicyTieTol;
      if(!(aneTied && gpuTied)) {
        cerr << "runMLXCoreMLSmokeTest: TOP-1 POLICY MISMATCH"
             << " ANE=" << top1Ane << " (p_ane=" << aneAtAne
             << ", p_gpu=" << gpuAtAne << ")"
             << " GPU=" << top1Gpu << " (p_ane=" << aneAtGpu
             << ", p_gpu=" << gpuAtGpu << ")"
             << " (stride bug regression?)" << endl;
        testAssert(false);
      }
      // else: FP16 near-tie — both backends agree both positions are
      // effectively equally likely; the argmax flip is noise, not a bug.
    }
```

New text to replace with (uses row-0 for cross-backend parity, then asserts ANE row-1 matches ANE row-0):

```cpp
    // Top-1 spatial-policy index parity (row 0, cross-backend). Strict argmax
    // (first-of-max via >) would be flaky if two positions sit within FP16
    // noise of each other and the two backends round them in opposite
    // directions. Detect that case and accept only when BOTH backends
    // consider the two positions tied. A stride-scramble regression makes
    // their probabilities differ by orders of magnitude (v16 pre-fix:
    // topPolicyDelta 0.98, KL 14), not by 1e-3, so this tolerance does not
    // weaken scrambling detection.
    int top1Ane = 0, top1Gpu = 0;
    for(int i = 1; i < 19 * 19; i++) {
      if(outAne0.policyProbs[i] > outAne0.policyProbs[top1Ane]) top1Ane = i;
      if(outGpu0.policyProbs[i] > outGpu0.policyProbs[top1Gpu]) top1Gpu = i;
    }
    if(top1Ane != top1Gpu) {
      constexpr float kFP16PolicyTieTol = 1e-3f;
      float aneAtAne = outAne0.policyProbs[top1Ane];
      float aneAtGpu = outAne0.policyProbs[top1Gpu];
      float gpuAtAne = outGpu0.policyProbs[top1Ane];
      float gpuAtGpu = outGpu0.policyProbs[top1Gpu];
      bool aneTied = std::abs(aneAtAne - aneAtGpu) < kFP16PolicyTieTol;
      bool gpuTied = std::abs(gpuAtAne - gpuAtGpu) < kFP16PolicyTieTol;
      if(!(aneTied && gpuTied)) {
        cerr << "runMLXCoreMLSmokeTest: TOP-1 SPATIAL POLICY MISMATCH"
             << " ANE=" << top1Ane << " (p_ane=" << aneAtAne
             << ", p_gpu=" << gpuAtAne << ")"
             << " GPU=" << top1Gpu << " (p_ane=" << aneAtGpu
             << ", p_gpu=" << gpuAtGpu << ")"
             << " (stride bug regression?)" << endl;
        testAssert(false);
      }
      // else: FP16 near-tie — both backends agree both positions are
      // effectively equally likely; the argmax flip is noise, not a bug.
    }

    // Per-row parity: identical inputs must produce identical outputs
    // within FP16 noise. A v15+ pass-policy stride bug (row 0 reads inside
    // Swift's writes, rows >= 1 read uninitialized memory) makes row 0 vs
    // row 1 differ by orders of magnitude on the pass position. See
    // docs/superpowers/specs/2026-05-26-mlx-v15plus-pass-policy-fix-design.md.
    constexpr int kPassIdx = 19 * 19;
    constexpr float kFP16ProbTol = 0.05f;
    auto absDiff = [](float a, float b) { return std::abs(a - b); };
    testAssert(absDiff(outAne0.policyProbs[kPassIdx], outAne1.policyProbs[kPassIdx]) < kFP16ProbTol);
    testAssert(absDiff(outGpu0.policyProbs[kPassIdx], outGpu1.policyProbs[kPassIdx]) < kFP16ProbTol);

    // Cross-path pass-position parity: with the v15+ fix in place, MLX/GPU
    // and MLX/ANE compute the full two-layer pass head; their pass-position
    // probabilities should agree within FP16 noise (the same tolerance the
    // existing pass-sanity check below uses, made strict to catch the bug).
    testAssert(absDiff(outAne0.policyProbs[kPassIdx], outGpu0.policyProbs[kPassIdx]) < kFP16ProbTol);
    testAssert(absDiff(outAne1.policyProbs[kPassIdx], outGpu1.policyProbs[kPassIdx]) < kFP16ProbTol);
```

- [ ] **Step 5: Update the loose pass/value-sanity asserts to use row-0 outputs**

Locate the existing sanity asserts at lines 1366-1369:

Old text to find (exact):

```cpp
    // Pass + value sanity (loose; FP16 noise on both sides).
    testAssert(std::abs(outAne.policyProbs[19 * 19] - outGpu.policyProbs[19 * 19]) < 1.0);
    testAssert(std::abs(outAne.whiteWinProb  - outGpu.whiteWinProb)  < 0.05);
    testAssert(std::abs(outAne.whiteLossProb - outGpu.whiteLossProb) < 0.05);
```

New text to replace with (drop the loose pass diff since Step 4's strict per-row assertion subsumes it; keep value-head sanity for row 0 and add for row 1):

```cpp
    // Value-head sanity (loose; FP16 noise on both sides). Per-row to also
    // catch any future cross-row corruption on the value/scoreValue path.
    testAssert(std::abs(outAne0.whiteWinProb  - outGpu0.whiteWinProb)  < 0.05);
    testAssert(std::abs(outAne0.whiteLossProb - outGpu0.whiteLossProb) < 0.05);
    testAssert(std::abs(outAne1.whiteWinProb  - outGpu1.whiteWinProb)  < 0.05);
    testAssert(std::abs(outAne1.whiteLossProb - outGpu1.whiteLossProb) < 0.05);
```

- [ ] **Step 6: Rebuild**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja 2>&1 | tail -5
```

Expected: clean recompile of `mlxtests.cpp.o` and re-link. Exit 0. If you see:
- "no member named `policyProbs` in `NNOutput`" — re-confirm `outAne0`, `outGpu0` etc. were named consistently in every substitution.
- "narrowing conversion" or `auto initBuf` complaint — wrap the lambda in `(void)`-cast if the compiler is strict; otherwise it compiles cleanly under `-std=c++17`.

- [ ] **Step 7: Run the smoke test on a v15+ model (the fix-validation case)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
MLX_COREML_TEST_MODEL=models/b5c192nbt-v16test.bin.gz ./katago runnnlayertests 2>&1 | tee /tmp/smoke_v16_after.txt
```

Expected output — search `/tmp/smoke_v16_after.txt` for these literal strings:
- `runMLXCoreMLSmokeTest: starting on models/b5c192nbt-v16test.bin.gz`
- `runMLXCoreMLSmokeTest: passed`
- NO occurrence of `TOP-1 SPATIAL POLICY MISMATCH`
- NO occurrence of `testAssert failed`
- exit code 0

If `testAssert failed` fires inside the parity block:
- "absDiff(outAne0.policyProbs[kPassIdx], outAne1.policyProbs[kPassIdx]) < kFP16ProbTol" failed → Task 2's `numPolicyPassChannels` fix didn't land or the apply() change didn't land. Verify with `git log -1 -p cpp/neuralnet/mlxbackend.cpp` that all three sub-changes from Task 2 are committed.
- "absDiff(outAne0..., outGpu0...)" failed → MLX/GPU's pass output disagrees with ANE's by > 5%. Possible: the `apply()` change is missing one of bias/activation/matmul2, or the activation type is wrong. Compare to Metal's MPSGraph implementation behavior in metalbackend.swift's pass-tensor handling (line ~552: `policyHead.policyPassTensor`).

- [ ] **Step 8: Run the smoke test on a v11 model (skip-branch regression check)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
MLX_COREML_TEST_MODEL=models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz ./katago runnnlayertests 2>&1 | tee /tmp/smoke_v11_after.txt
```

Expected: `parity check skipped; modelVersion=11` in the output, followed by `runMLXCoreMLSmokeTest: passed`. Exit 0. The new batched assertions never run because the parity branch is gated on modelVersion >= 12; the existing v11 construction smoke still runs unchanged.

- [ ] **Step 9: Run the smoke test with no model present (early-skip regression check)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
MLX_COREML_TEST_MODEL=/tmp/does-not-exist.bin.gz ./katago runnnlayertests 2>&1 | tee /tmp/smoke_nomodel_after.txt
```

Expected: `skipping; model not found at /tmp/does-not-exist.bin.gz` in the output. Exit 0. None of the new batched assertions fire (the function returns early before any handle is built).

- [ ] **Step 10: Confirm `./katago runtests` still passes**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago runtests 2>&1 | tail -10
```

Expected: `All tests passed` (or equivalent banner). The unit-test suite is independent of these changes; this is a no-regression smoke at the harness level.

- [ ] **Step 11: Stage and commit the smoke test extension**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git add cpp/neuralnet/mlxtests.cpp
git status --short
```

Expected: `M cpp/neuralnet/mlxtests.cpp` (staged). The pre-existing WIP unchanged. If `cpp/neuralnet/mlxtests.cpp` appears in both staged and unstaged (split), you have residual WIP that needs to be set aside first.

```bash
git commit -m "$(cat <<'EOF'
mlxtests: cover v15+ pass-policy stride class in smoke test

runMLXCoreMLSmokeTest was constructed with batchSize=1, which only
exercises row 0 of the per-row buffer. For v15+ models the prior C++
stride bug (numPolicyPassChannels = gpoolToPassMul.outChannels = hidden
width) put garbage in rows >= 1; row 0 happened to read inside Swift's
writes, so the smoke test was structurally incapable of detecting it.

Bump both ANE and MLX/GPU handles + InputBuffers to maxBatchSize=2,
submit two identical NNResultBufs per path, and assert per-row and
cross-path parity on the pass position
(policyProbs[nnXLen*nnYLen]) within FP16 tolerance. Identical inputs
must produce identical per-row outputs.

Keeps the existing top-1 spatial parity check (which guards the v12+
NHWC/NCHW spatial stride class from the 2026-05-25 fix). Both bug
classes now fail the smoke test if regressed.

Gating unchanged: modelVersion >= 12 and metaEncoderVersion == 0.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git status --short
```

Expected: commit succeeds; pre-existing WIP unchanged.

---

## Task 4: Cross-model validation pass (no commit)

**Files:** none modified — broader correctness check before declaring the fix done. The model selection below covers the v15+ model classes (humansl two-layer pass, standard v16) and one v11 control.

- [ ] **Step 1: Re-run humanv0 v15 ANE sizerect (different v15+ shape: humansl + metaEncoder)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ls tests/results/gpu_error_reference_files/b18c384nbt-humanv0.bin.gz_sizerect.txt
```

If the reference file is missing, skip this step — humanv0 v15 validation requires the reference, and regenerating it is out of scope for this fix.

If present:

```bash
./katago testgpuerror \
  -model models/b18c384nbt-humanv0.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize rectangle \
  -override-config "requireMaxBoardSize=False, maxBatchSize=11, deviceToUseThread0=100, humanSLProfile=preaz_9d" \
  -reference-file tests/results/gpu_error_reference_files/b18c384nbt-humanv0.bin.gz_sizerect.txt \
  > /tmp/humanv0_rect_ane_after.txt 2>&1
grep "topPolicyDelta\|policyKLDiv" /tmp/humanv0_rect_ane_after.txt | head -10
```

Expected: `topPolicyDelta` max ≤ ~5% (vs ~99% pre-fix per the stale 5/24 result file in `cpp/tests/results/gpu_error_results/b18c384nbt-humanv0.bin.gz_sizerect_ane.txt`). Slightly looser tolerance than v16 b5c192 because humanv0 is a humansl model and may have higher FP16 sensitivity on rectangle boards. If the max is still > 10%, stop and investigate — the humansl path may need additional fixes that this plan didn't anticipate.

- [ ] **Step 2: Re-run humanv0 v15 MLX/GPU sizerect**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model models/b18c384nbt-humanv0.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize rectangle \
  -override-config "requireMaxBoardSize=False, maxBatchSize=11, humanSLProfile=preaz_9d" \
  -reference-file tests/results/gpu_error_reference_files/b18c384nbt-humanv0.bin.gz_sizerect.txt \
  > /tmp/humanv0_rect_gpu_after.txt 2>&1
grep "topPolicyDelta" /tmp/humanv0_rect_gpu_after.txt | head -6
```

Expected: `fp32 error` topPolicyDelta max essentially unchanged from before this fix (per stale file: max ~0.00018%, since humanv0 v15 MLX/GPU was the one case where the bug somehow didn't fire visibly — the stale result file shows it as clean). The fix should leave humanv0 v15 MLX/GPU at the same clean baseline, or improve it modestly if any FP rounding differs.

- [ ] **Step 3: Re-run v16 b5c192 size19 ANE batched (the validation snapshot's 25% case)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model models/b5c192nbt-v16test.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize 19 \
  -override-config "requireMaxBoardSize=True, deviceToUseThread0=100" \
  -reference-file tests/results/gpu_error_reference_files/b5c192nbt-v16test.bin.gz_size19.txt \
  > /tmp/v16_size19_ane_after.txt 2>&1
grep "topPolicyDelta" /tmp/v16_size19_ane_after.txt | head -6
```

Expected: `batched fp32 error vs reference topPolicyDelta` max **≤ ~1%** (vs 25.03% in the prior `.claude/MLX_Validation.md` snapshot, which misattributed the figure to "FP16 noise"). This run confirms the snapshot's misattribution was wrong — the 25% was this bug, fixed by the same change that fixed the 41% rectangle figure.

- [ ] **Step 4: Re-run the 2026-05-25 v11 b18 mux 2g2a config (regression check on the historical mux baseline)**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize 19 \
  -override-config "requireMaxBoardSize=True, numNNServerThreadsPerModel=4, \
    deviceToUseThread0=0, deviceToUseThread1=0, \
    deviceToUseThread2=100, deviceToUseThread3=100, mlxUseFP16=true" \
  -reference-file tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt \
  > /tmp/v11_mux2g2a_after.txt 2>&1
grep "topPolicyDelta\|winrateError" /tmp/v11_mux2g2a_after.txt | head -6
```

Expected: `winrateError` max ≤ ~1.1% (matches the 0.78%-1.08% recorded in `.claude/MLX_Validation.md` for the prior fix's baseline). The mux config exercises 2 MLX/GPU + 2 ANE threads in concurrent serving — confirms this fix didn't regress the multi-thread setup.

---

## Task 5: Refresh `.claude/MLX_Validation.md` (local-only, never committed)

**Files:**
- Modify: `.claude/MLX_Validation.md` (gitignored per `.gitignore`'s `.claude/` rule)

This is a documentation/hygiene step per `CLAUDE.md`'s "When to re-run" checklist. It also corrects a misattribution in the prior snapshot.

- [ ] **Step 1: Read the current snapshot**

```bash
cat /Users/chinchangyang/Code/KataGo-MLX/.claude/MLX_Validation.md | head -80
```

Note the file's existing structure (date stamp, validation table, throughput numbers, reproduction commands, "When to re-run", "Open follow-ups").

- [ ] **Step 2: Prepend a new snapshot for 2026-05-26**

Append/prepend the new section near the top of the file (after the file header but before the 2026-05-25 stride-fix snapshot). Use the same format as existing snapshots. The new section must cover:

1. Date and HEAD commit (run `git log -1 --format='%h %s'` in cpp/ to confirm).
2. Brief root-cause summary referencing `docs/superpowers/specs/2026-05-26-mlx-v15plus-pass-policy-fix-design.md`.
3. The before/after table for v16 b5c192 sizerect (ANE batched + MLX/GPU), captured from `/tmp/v15plus_rect_ane_before.txt`, `/tmp/v15plus_rect_ane_after.txt`, `/tmp/v15plus_rect_gpu_before.txt`, `/tmp/v15plus_rect_gpu_after.txt`.
4. The v16 size19 ANE batched correction: previously reported as 25% "FP16 noise on one position" in the 2026-05-25 snapshot; actually was this v15+ pass-policy bug, now ≤ ~1%. Reference `/tmp/v16_size19_ane_after.txt`.
5. The humanv0 v15 sizerect numbers if Task 4 Step 1 ran; otherwise note that this model wasn't re-validated.
6. The v11 b18 mux 2g2a regression check: numbers in family with the prior snapshot. Reference `/tmp/v11_mux2g2a_after.txt`.
7. Updated "When to re-run" — add the v15+ pass head and the smoke-test parity block to the trigger list.

- [ ] **Step 3: Correct the prior snapshot's misattribution**

In the 2026-05-25 snapshot ("v12+ ANE policy-optimism stride fix + smoke-test parity check"), locate the paragraph that says (approximately):

> "The 25% topPolicyDelta max is concentrated on a single FP16-sensitive position (the avg/90/99 columns are all sub-1%). Same shape as the non-ANE GPU baseline (max ~22% on the same model under FP16)."

Append a correction note (do not delete the original; mark it as superseded):

> **CORRECTION 2026-05-26**: This 25% figure was *not* FP16 noise. It was the v15+ pass-policy stride bug (this snapshot's NHWC/NCHW spatial fix did not address pass policy). Post the 2026-05-26 fix
> (`docs/superpowers/specs/2026-05-26-mlx-v15plus-pass-policy-fix-design.md`)
> this same configuration measures ≤ ~1% topPolicyDelta max. The same bug
> independently affected MLX/GPU on rectangle (max ~72%) and ANE batched
> rectangle (max ~41%).

- [ ] **Step 4: Verify the file remains uncommitted**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git status --short .claude/
```

Expected: `.claude/` does not appear in the output (gitignored). If it does appear, do not stage it; the file is local-only.

- [ ] **Step 5: Final cross-check**

```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git log --oneline -3
git status --short
```

Expected:
- Two new commits on top of `mlx-ane-policy-optimism-stride-fix`: the spec (already landed as `95dec4ec` before this plan), the C++ fix from Task 2, and the smoke-test extension from Task 3 — for a total of 3 new commits on this branch's HEAD relative to where the branch started before this work.
- `git status --short` shows the SAME pre-existing WIP that existed before this work (untracked files, plus `.claude/MLX_Validation.md` which is gitignored so it doesn't appear at all).
- No accidental modifications to other files.

---

## Notes for the implementer

**Why no TDD with a separate failing unit test for Task 2.** The bug only manifests through the full backend pipeline: KataGo model → MLX trunk → MLX policy head → buffer copy → C++ post-processor. There is no isolated unit test layer between "the pass MLMultiArray" and "the optimism formula" — every relevant subsystem is full-process. The natural failing-test artefacts are the `testgpuerror` baselines captured in Task 1 (Steps 3, 4, 5) and the post-fix passing-test artefacts in Task 2 (Steps 6, 7, 8). Task 3's smoke-test extension is the codified regression check.

**If Task 2 Step 6 (ANE post-fix) still shows > 5% topPolicyDelta.** First confirm Task 2's three sub-changes all landed: `git diff HEAD~1 -- cpp/neuralnet/mlxbackend.cpp` should show all three of (a) new PolicyHead struct fields, (b) the v15+ branch in apply(), (c) the ternary in numPolicyPassChannels. If all three are there, the most likely cause is that the activation type isn't what the model actually trained with. Verify by adding a temporary `cerr << "passActivationType=" << passActivationType << endl;` to the PolicyHead constructor and checking for the expected value (typically `ACTIVATION_RELU = 1` or `ACTIVATION_MISH = 2`). The value comes from `desc.passActivation.activation`; if it's 0 (`ACTIVATION_IDENTITY`), the model file was parsed but the activation wasn't, indicating a parser issue in `desc.cpp:1292` worth investigating.

**If Task 2 Step 7 (MLX/GPU post-fix) shows worse numbers than before.** Likely cause: the MLX-side `gpoolToPassBias->apply(...)` produces the wrong-shape output for broadcasting. `MatBiasLayer::apply` returns `input + bias` where `bias` has shape `[numChannels]`; MLX should broadcast this correctly along the last axis of a (batch, hidden) input. If broadcasting fails (incompatible shapes), the build would error rather than producing wrong numbers — so this would surface at Task 2 Step 5 as a compile error, not a runtime number. If runtime numbers are wrong but compilation passes, double-check that the order is `gpoolToPassMul → bias → activation → gpoolToPassMul2` and not e.g. `... → activation → bias → ...` (the spec and Metal both put bias before activation).

**If `git add` accidentally picks up pre-existing WIP.** Run `git restore --staged <file>` to unstage just that file, then re-stage with `git add cpp/neuralnet/mlxbackend.cpp` (or `mlxtests.cpp`) — `git add` of a single path is idempotent and won't re-stage WIP from other files. If a single file has both this plan's changes AND residual WIP intermixed:

1. `git stash push -- cpp/neuralnet/<file>` — sets aside both this plan's edits and the WIP.
2. `git checkout HEAD -- cpp/neuralnet/<file>` — restore to last committed state.
3. Re-apply only this plan's edits by hand (the plan steps have the full text).
4. `git add cpp/neuralnet/<file> && git commit ...`.
5. `git stash pop` — restores the pre-existing WIP cleanly on top.

This is the safer path if WIP and this plan's hunks interleave in ways `git add -p` can't cleanly separate.

**Why the spec docs commit isn't a step in this plan.** It was already landed as `95dec4ec` ("spec: MLX v15+ pass policy fix") at the end of the brainstorm session. This plan starts from that commit.
