# MLX Per-Thread Default Stream Implementation Plan

> **SUPERSEDED 2026-05-25.** The hypothesis in the linked spec was
> wrong; the implementation following this plan (commit `3b760af2`)
> did not fix the crash and was reverted in `fb0fcb89`. The actual
> root cause and fix are documented in
> `docs/superpowers/specs/2026-05-25-mlx-fp16-weight-materialization-design.md`.
> Do not execute the steps below.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the 2×GPU + 2×ANE FP16 mux config from crashing with `"There is no Stream(gpu, 0) in current thread."` by registering a per-thread MLX default stream on first use from each NNEvaluator server thread.

**Architecture:** Add one file-static helper in `cpp/neuralnet/mlxbackend.cpp` that uses a `thread_local bool` latch to call `mx::set_default_stream(mx::new_stream(mx::default_device()))` exactly once per server thread. Invoke from the GPU branches of `NeuralNet::createComputeHandle` and `NeuralNet::getOutput`. ANE branches are untouched (they don't dispatch MLX ops).

**Tech Stack:** C++, MLX 0.31.2 (`mx::Stream`, `mx::set_default_stream`, `mx::new_stream`), KataGo NNEvaluator (`cpp/neuralnet/nneval.cpp`), CMake/Ninja, KataGo `testgpuerror` and `benchmark` commands.

**Spec reference:** `docs/superpowers/specs/2026-05-25-mlx-threadlocal-stream-design.md`.

**Branch:** `mlx-backend-squash` (head at spec-commit time: `3c6734e5`).

---

## File Structure

Only `cpp/neuralnet/mlxbackend.cpp` is modified. No new files.

| File | Responsibility (relevant slice) |
|---|---|
| `cpp/neuralnet/mlxbackend.cpp` | MLX backend implementation. Adds (a) file-static helper `ensureMLXDefaultStreamForCurrentThread()` near the other file-statics at lines 56–64; (b) one call near the top of `NeuralNet::createComputeHandle` (line 1707) gated on `gpuIdx == MLX_MUX_GPU`; (c) one call inside the GPU branch of `NeuralNet::getOutput` (line 1823) — also implicitly gated since that branch is only reached when `coremlOnlyHandle` is null (i.e., GPU path). |

Other affected, non-edited files (read-only context):

| File | Why it matters |
|---|---|
| `cpp/neuralnet/nneval.cpp` | Spawns the std::thread server threads (line 393) and calls `createComputeHandle` (line 437) + `getOutput` (line 570) on them. Confirms helper is invoked on the right thread. |
| `/opt/homebrew/Cellar/mlx/0.31.2/include/mlx/stream.h` | Documents `mx::default_stream`, `mx::set_default_stream`, `mx::new_stream` signatures used by the helper. |
| `cpp/configs/gtp_example.cfg` | Already documents the 2×GPU + 2×ANE mux config that this plan unblocks (commit `64304cdb`). |
| `.claude/MLX_Validation.md` | Local-only validation snapshot. Updated in the final task. **NOT committed** (per CLAUDE.md). |

---

## Task Decomposition

Five tasks. Task 1 captures the failing baseline; Task 2 lands the fix; Tasks 3–4 verify regression and throughput; Task 5 updates the local validation snapshot.

---

### Task 1: Capture the failing repro baseline

**Why this exists:** Confirm on this machine, at this HEAD, that the bug still reproduces — and capture the exact log so Task 3 has something to diff against. If the repro doesn't fail (e.g., MLX got patched, or the test infra changed), stop and ask before implementing a fix for a bug that no longer exists.

**Files:**
- Read-only: `cpp/neuralnet/mlxbackend.cpp` (verify HEAD has the converter mutex from commit `acbd0f04`)
- Output: `cpp/tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_mux2g2a_prefix.txt`

- [ ] **Step 1: Verify HEAD has the converter mutex commit**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git log --oneline -1 -- cpp/neuralnet/mlxbackend.cpp | head -1
grep -n "computeHandleMutex" cpp/neuralnet/mlxbackend.cpp
```

Expected: the most recent change to mlxbackend.cpp is commit `acbd0f04` ("MLX backend: serialize ComputeHandle construction") or a later commit that preserves the mutex; `grep` shows the static declaration around line 64 and the `lock_guard` around line 1708.

If the mutex is missing, stop — Task 1 of the previous plan (`docs/superpowers/plans/2026-05-24-mlx-ane-converter-mutex.md`) is a prerequisite.

- [ ] **Step 2: Confirm the build is current and MLX backend**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
./katago --version 2>&1 | head -3
```

Expected: ninja reports "no work to do" or rebuilds without errors; `--version` mentions an MLX backend build.

If `ninja` fails or katago is not built against MLX, reconfigure:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
cmake -G Ninja -DUSE_BACKEND=MLX && ninja
```

- [ ] **Step 3: Verify the Eigen reference file exists**

Run:
```bash
ls -la cpp/tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt
```

Expected: file exists, non-empty. If missing, the cross-backend comparison can't run — regenerate per `CLAUDE.md` "GPU Error Testing" section before continuing.

- [ ] **Step 4: Run the failing repro and capture output**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize 19 \
  -override-config "requireMaxBoardSize=True, numNNServerThreadsPerModel=4, deviceToUseThread0=0, deviceToUseThread1=0, deviceToUseThread2=100, deviceToUseThread3=100, mlxUseFP16=true" \
  -reference-file tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt \
  2>&1 | tee tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_mux2g2a_prefix.txt
```

Expected: the run crashes with the line
```
libc++abi: terminating due to uncaught exception of type std::runtime_error: There is no Stream(gpu, 0) in current thread.
```
The command's exit status will be non-zero (`echo $?` after the run shows ≠ 0).

If the run completes successfully instead, stop and surface this to the user — the bug may have been incidentally fixed and the rest of this plan should not run.

- [ ] **Step 5: No commit**

This task captures a baseline log only. The log lives under `cpp/tests/results/gpu_error_results/` which is already untracked (per the existing `cpp/tests/results/gpu_error_results/` entry in git status). No `git add`.

---

### Task 2: Implement the per-thread stream helper and wire it into both call sites

**Why this exists:** This is the entire fix — one helper + two call sites, in one commit, mirroring the surgical structure of the converter-mutex commit `acbd0f04`. Keeping it one commit makes it easy to bisect later if any regression surfaces.

**Files:**
- Modify: `cpp/neuralnet/mlxbackend.cpp` (three hunks: helper declaration near line 64; call near line 1707; call near line 1823)

- [ ] **Step 1: Add the helper function near the file-static section**

Open `cpp/neuralnet/mlxbackend.cpp` and locate the block ending at line 64 (the closing brace of the `computeHandleMutex` declaration). Insert the helper immediately after.

Replace this exact block:

```cpp
// Serializes ComputeHandle construction across server threads. The CoreML
// converter (katagocoreml::KataGoConverter::convert) holds process-global
// MIL writer state that is not reentrant; without this lock, 2+ ANE threads
// racing at startup corrupt the .mlpackage and throw "Metadata written to
// different offset than expected." Mirrors metalbackend.cpp:442.
static std::mutex computeHandleMutex;
```

With:

```cpp
// Serializes ComputeHandle construction across server threads. The CoreML
// converter (katagocoreml::KataGoConverter::convert) holds process-global
// MIL writer state that is not reentrant; without this lock, 2+ ANE threads
// racing at startup corrupt the .mlpackage and throw "Metadata written to
// different offset than expected." Mirrors metalbackend.cpp:442.
static std::mutex computeHandleMutex;

// Register a per-thread default MLX stream on first call from a given thread.
// MLX 0.31.2's mx::default_stream(Device) is thread-local and throws if the
// calling thread never registered one - which is what happens to NNEvaluator's
// std::thread server threads. Without this, the first MLX/GPU forward pass on
// a server thread throws "There is no Stream(gpu, 0) in current thread."
// Giving each server thread its own Stream also enables CPU-side dispatch
// overlap between threads (each Stream owns its own StreamThread worker).
static void ensureMLXDefaultStreamForCurrentThread() {
  thread_local bool initialized = false;
  if(!initialized) {
    mx::set_default_stream(mx::new_stream(mx::default_device()));
    initialized = true;
  }
}
```

- [ ] **Step 2: Build to verify the helper compiles in isolation**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
```

Expected: build succeeds. If it fails complaining about `mx::set_default_stream`, `mx::new_stream`, or `mx::default_device`, check that `<mlx/stream.h>` is reachable — it is brought in transitively by the existing `<mlx/mlx.h>` include; no new include should be needed. If the error is "unused function `ensureMLXDefaultStreamForCurrentThread`", that's fine — it's resolved in the next step.

- [ ] **Step 3: Wire the helper into `NeuralNet::createComputeHandle`**

Open `cpp/neuralnet/mlxbackend.cpp` and locate lines 1704–1710. Replace this exact block:

```cpp
  if(!inputsUseNHWC)
    throw StringError("MLX backend: inputsUseNHWC = false unsupported");

  // Serialize handle construction: see computeHandleMutex declaration above.
  std::lock_guard<std::mutex> lock(computeHandleMutex);
  return new ComputeHandle(context, *loadedModel, inputsUseNHWC, requireExactNNLen, useFP16,
                           gpuIdx, maxBatchSize, serverThreadIdx);
}
```

With:

```cpp
  if(!inputsUseNHWC)
    throw StringError("MLX backend: inputsUseNHWC = false unsupported");

  // Register a per-thread MLX default stream before any MLX op runs in the
  // ctor (model construction, Winograd tuner). ANE threads skip MLX ops, so
  // we don't pay the cost of an unused stream for them. See helper comment.
  if(gpuIdx == MLX_MUX_GPU) {
    ensureMLXDefaultStreamForCurrentThread();
  }

  // Serialize handle construction: see computeHandleMutex declaration above.
  std::lock_guard<std::mutex> lock(computeHandleMutex);
  return new ComputeHandle(context, *loadedModel, inputsUseNHWC, requireExactNNLen, useFP16,
                           gpuIdx, maxBatchSize, serverThreadIdx);
}
```

Rationale for placement: outside the mutex (stream registration is per-thread and needs no serialization); after the gpuIdx validation (so we don't register a stream and then throw); before `new ComputeHandle` (so the ctor's MLX ops have a default stream available).

- [ ] **Step 4: Wire the helper into `NeuralNet::getOutput`**

Open `cpp/neuralnet/mlxbackend.cpp` and locate lines 1822–1826 (the start of the GPU branch in `NeuralNet::getOutput`). Replace this exact block:

```cpp
  } else {
    // GPU path: run the MLX compiled function exactly as before.
    const bool useMask = !computeHandle->requireExactNNLen;
    const bool hasMeta = (numMetaFeatures > 0);
    const CompiledInferenceFunc& compiledFunc = computeHandle->getCompiledFunc(batchSize, nnXLen, nnYLen, useMask, hasMeta);
```

With:

```cpp
  } else {
    // Defensive: ensure the server thread has a default MLX stream registered
    // before the first applyCompiled. Normally already set by createComputeHandle
    // on the same thread, but covered here too in case a future refactor moves
    // the first MLX op off the ctor path. Cheap after first call.
    ensureMLXDefaultStreamForCurrentThread();

    // GPU path: run the MLX compiled function exactly as before.
    const bool useMask = !computeHandle->requireExactNNLen;
    const bool hasMeta = (numMetaFeatures > 0);
    const CompiledInferenceFunc& compiledFunc = computeHandle->getCompiledFunc(batchSize, nnXLen, nnYLen, useMask, hasMeta);
```

The `else` branch is only entered when `coremlOnlyHandle` is null (i.e., GPU path), so no explicit `gpuIdx == MLX_MUX_GPU` gate is needed here.

- [ ] **Step 5: Build the full change**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
ninja
```

Expected: build succeeds with no warnings about the helper. If `ensureMLXDefaultStreamForCurrentThread` is now "unused" the compiler will be silent (file-static + used in two TUs in same file = no warning).

- [ ] **Step 6: Verify the failing repro now passes**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize 19 \
  -override-config "requireMaxBoardSize=True, numNNServerThreadsPerModel=4, deviceToUseThread0=0, deviceToUseThread1=0, deviceToUseThread2=100, deviceToUseThread3=100, mlxUseFP16=true" \
  -reference-file tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt \
  2>&1 | tee tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_mux2g2a.txt
echo "exit=$?"
```

Expected:
- No `There is no Stream(gpu, 0) in current thread` line.
- Output ends with summary error metrics (look for lines containing `winrateError`, `scoreError`, `policySurprise`).
- Final `exit=0`.

If the run still crashes with the stream error, the helper is not being called from the crashing thread — re-read Steps 3 and 4 to confirm both call sites are in place.

If the run crashes with a *different* error (e.g., a CoreML failure), that's a new bug; stop and surface to the user before committing.

- [ ] **Step 7: Verify accuracy is within tolerance**

Run:
```bash
grep -E "winrateError|FP16|fp16" tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_mux2g2a.txt | tail -30
```

Expected: maximum FP16 winrateError ≤ 3.0% (matches the existing MLX/GPU FP16 baseline of 2.63% from `.claude/MLX_Validation.md`).

If the max winrate error is > 3%, the per-thread streams may be producing diverging results between threads (very unlikely but possible if the streams use different RNG state). Stop and surface to the user.

- [ ] **Step 8: Commit**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git status cpp/neuralnet/mlxbackend.cpp
git diff --stat cpp/neuralnet/mlxbackend.cpp
```

Expected: only `cpp/neuralnet/mlxbackend.cpp` modified; diff stat shows roughly +20/-0 (helper + 2 call sites).

Then commit (only the single file — leave the existing WIP in `cpp/CMakeLists.txt` and `cpp/neuralnet/mlxtests.cpp` unstaged, per session policy):

```bash
git add cpp/neuralnet/mlxbackend.cpp
git commit -m "$(cat <<'EOF'
MLX backend: register per-thread default stream

MLX 0.31.2's mx::default_stream(Device) is thread-local and throws
"There is no Stream(gpu, 0) in current thread." on any thread that
never called set_default_stream. NNEvaluator spawns std::thread server
threads that dispatch MLX ops directly; without a default stream
registered per thread, the first MLX/GPU forward pass on a non-main
server thread crashes.

Add a file-static ensureMLXDefaultStreamForCurrentThread() helper that
uses a thread_local bool latch to call mx::set_default_stream(mx::new_stream(...))
exactly once per thread. Invoke from the GPU branches of
createComputeHandle (before the converter mutex) and getOutput (top of
GPU branch). ANE threads skip the call.

Per-thread streams also give the CPU-side dispatch overlap that lets
the 2xGPU+2xANE mux config outperform 1xGPU+1xANE - validated by
benchmark in the follow-on task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git log --oneline -1
```

Expected: commit lands on `mlx-backend-squash`, branch now at the new commit hash.

---

### Task 3: Regression suite

**Why this exists:** The fix touches the hot path for every MLX/GPU forward pass and the construction path for every server thread. Run the full unit test suite plus a single-thread default `testgpuerror` to confirm no behavior change for configurations that already worked.

**Files:** Read-only; no edits.

- [ ] **Step 1: Run `runtests`**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago runtests 2>&1 | tail -20
echo "exit=$?"
```

Expected: final line shows "All tests passed" (or equivalent) and `exit=0`. If any test fails, capture the failure name and surface to the user — the helper should be invisible to unit tests, so a failure indicates an unintended side effect.

- [ ] **Step 2: Run `runnnlayertests`**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago runnnlayertests 2>&1 | tail -40
echo "exit=$?"
```

Expected: all 14 tests pass including `runMLXCoreMLSmokeTest`; `exit=0`. The layer tests run on a single thread, so the helper is called once and the per-thread stream is harmless.

- [ ] **Step 3: Run single-thread default `testgpuerror`**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago testgpuerror \
  -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
  -config configs/gtp_example.cfg \
  -boardsize 19 \
  -reference-file tests/results/gpu_error_reference_files/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19.txt \
  2>&1 | tee tests/results/gpu_error_results/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz_size19_default_post_streamfix.txt
echo "exit=$?"
```

Expected: `exit=0`. Maximum FP16 winrate error should be ≤ 1.5% (close to the pre-fix single-thread baseline of 1.08% recorded in `.claude/MLX_Validation.md`). If it has shifted by more than ~0.5% in either direction, surface to the user before continuing.

- [ ] **Step 4: No commit**

Regression output files land under `cpp/tests/results/gpu_error_results/` (already untracked); no `git add`.

---

### Task 4: Throughput acceptance — 2+2 vs 1+1 benchmark

**Why this exists:** The spec's #1 throughput motivation is that per-thread MLX streams unlock CPU-side dispatch overlap. Confirm empirically that 2×GPU+2×ANE delivers strictly more nnEvals/s than 1×GPU+1×ANE on this hardware. If it doesn't, the per-thread streams aren't reaching MLX correctly (or this hardware isn't CPU-dispatch-bound — distinct outcomes worth distinguishing).

**Files:** Read-only; output captured under `cpp/tests/results/gpu_error_results/` (untracked).

- [ ] **Step 1: Benchmark 1×GPU+1×ANE (control)**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago benchmark \
  -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
  -config configs/gtp_example.cfg \
  -override-config "numNNServerThreadsPerModel=2, deviceToUseThread0=0, deviceToUseThread1=100, mlxUseFP16=true" \
  -threads 8 \
  -visits 800 \
  2>&1 | tee tests/results/gpu_error_results/benchmark_mux1g1a.txt
echo "exit=$?"
```

Expected: `exit=0`. Capture the reported nnEvals/sec (and visits/sec) from the final summary block.

- [ ] **Step 2: Benchmark 2×GPU+2×ANE (post-fix)**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX/cpp
./katago benchmark \
  -model models/kata1-b18c384nbt-s5832081920-d3223508649.bin.gz \
  -config configs/gtp_example.cfg \
  -override-config "numNNServerThreadsPerModel=4, deviceToUseThread0=0, deviceToUseThread1=0, deviceToUseThread2=100, deviceToUseThread3=100, mlxUseFP16=true" \
  -threads 16 \
  -visits 800 \
  2>&1 | tee tests/results/gpu_error_results/benchmark_mux2g2a.txt
echo "exit=$?"
```

Expected: `exit=0`. Capture the reported nnEvals/sec.

- [ ] **Step 3: Compare**

Extract and compare:
```bash
grep -E "nnEval|visits/s|nps " tests/results/gpu_error_results/benchmark_mux1g1a.txt | tail -10
grep -E "nnEval|visits/s|nps " tests/results/gpu_error_results/benchmark_mux2g2a.txt | tail -10
```

Expected: 2×GPU+2×ANE nnEvals/sec strictly greater than 1×GPU+1×ANE nnEvals/sec.

If 2+2 is *not* faster than 1+1:
- Re-confirm both call sites in `mlxbackend.cpp` (Task 2 Steps 3 and 4) actually compile in.
- Add a temporary `cerr << "stream init on thread " << std::this_thread::get_id() << "\n";` inside the `if(!initialized)` block, rebuild, and rerun 2+2 — confirm 4 distinct thread IDs are logged. (Remove the cerr before commit.)
- If 4 distinct threads ARE registering streams but 2+2 still isn't faster, the hardware isn't CPU-dispatch-bound; this is not a correctness failure but worth surfacing to the user as a finding (the spec calls this out as a measurement question, not a correctness blocker).

- [ ] **Step 4: No commit**

Benchmark output is local-only; under untracked results dir. No `git add`.

---

### Task 5: Update local validation snapshot

**Why this exists:** `.claude/MLX_Validation.md` is the persistent record of "what works and how fast on this machine." Refresh it with the post-fix 2+2 numbers and the throughput comparison so future sessions don't re-run benchmarks they don't need.

**Files:**
- Modify: `.claude/MLX_Validation.md` (local-only, NOT committed — per CLAUDE.md)

- [ ] **Step 1: Read the current snapshot**

Run:
```bash
ls -la /Users/chinchangyang/Code/KataGo-MLX/.claude/MLX_Validation.md
head -30 /Users/chinchangyang/Code/KataGo-MLX/.claude/MLX_Validation.md
```

Expected: file exists; the most recent snapshot at the top is dated `2026-05-24` and notes the deferred ThreadLocalStream issue.

- [ ] **Step 2: Prepend a new snapshot section above the most recent one**

Use the Edit tool to insert a new section above the existing "Snapshot — 2026-05-24 (post mux 2+2 converter mutex; ThreadLocalStream issue surfaced)" header. The new section must include:

- **Section header:** `## Snapshot — 2026-05-25 (post per-thread default stream)`
- **HEAD:** the commit hash from Task 2 Step 8 (`git log --oneline -1` output)
- **Status table:** mark `2×GPU + 2×ANE FP16` as ✅ Working with max winrate error from Task 2 Step 7
- **Throughput numbers:** 1+1 nnEvals/sec and 2+2 nnEvals/sec from Task 4 Steps 1–2, plus the ratio (2+2/1+1)
- **Regression results:** runtests pass, runnnlayertests 14/14, default testgpuerror max winrate err from Task 3 Step 3
- **Reproduction commands:** copy the three commands used in Task 2 Step 6, Task 3 Step 3, and Task 4 Steps 1–2

Keep the existing 2026-05-24 entry intact below the new one. The deferred ThreadLocalStream bug it describes is now resolved; note that in one sentence at the top of the new section.

- [ ] **Step 3: Verify the file is still untracked**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-MLX
git check-ignore -v .claude/MLX_Validation.md || echo "(not ignored - just untracked)"
git status .claude/
```

Expected: `.claude/` shows as untracked. CLAUDE.md says this file is "local-only and will not be committed" — confirm we are NOT about to stage it.

- [ ] **Step 4: No commit**

`.claude/MLX_Validation.md` stays untracked. No `git add`.

---

## Self-Review Checklist

Run after writing the plan — author check, not a subagent dispatch.

**Spec coverage:**

| Spec section | Implemented by |
|---|---|
| Problem reproduction | Task 1 (capture baseline) + Task 2 Step 6 (re-run, must pass) |
| Root cause: per-thread default stream missing | Task 2 Step 1 (helper) |
| Design: helper at file-static section near line 64 | Task 2 Step 1 (exact placement after `computeHandleMutex`) |
| Design: call from `createComputeHandle` gated on `gpuIdx == MLX_MUX_GPU` before mutex | Task 2 Step 3 |
| Design: call from `getOutput` GPU branch | Task 2 Step 4 |
| Performance: per-stream CPU dispatch overlap | Task 4 (1+1 vs 2+2 benchmark) |
| Testing #1 negative repro | Task 1 (baseline) + Task 2 Step 6 (post-fix pass) |
| Testing #2 cross-backend accuracy ≤ 3% | Task 2 Step 7 |
| Testing #3 runtests | Task 3 Step 1 |
| Testing #4 runnnlayertests | Task 3 Step 2 |
| Testing #5 single-thread default | Task 3 Step 3 |
| Testing #6 throughput smoke 2+2 > 1+1 | Task 4 Step 3 |
| Rollout: single commit on `mlx-backend-squash` | Task 2 Step 8 |
| Rollout: snapshot update post-fix | Task 5 |

All spec sections accounted for.

**Placeholder scan:** No TBD, TODO, "add appropriate error handling," or "similar to Task N" references. All code shown verbatim.

**Type consistency:** Helper name `ensureMLXDefaultStreamForCurrentThread()` matches across the spec, the helper definition (Task 2 Step 1), and both call sites (Task 2 Steps 3 and 4). `MLX_MUX_GPU` constant referenced in Task 2 Step 3 matches the existing definition at `mlxbackend.cpp:56`.

---

## Execution Notes

- The pre-existing WIP modifications to `cpp/CMakeLists.txt` and `cpp/neuralnet/mlxtests.cpp` must remain unstaged throughout. Task 2 Step 8 stages only `cpp/neuralnet/mlxbackend.cpp` by name.
- `.claude/MLX_Validation.md` is local-only and never committed (CLAUDE.md).
- `docs/superpowers/specs/...` and `docs/superpowers/plans/...` are committed (already established pattern in this repo).
- Result files under `cpp/tests/results/gpu_error_results/` are intentionally untracked.
