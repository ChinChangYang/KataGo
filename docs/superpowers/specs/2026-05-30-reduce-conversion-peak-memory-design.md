# Reduce On-Device CoreML Conversion Peak Memory (b40c768 OOM Fix)

**Date:** 2026-05-30
**Status:** Design approved, pending implementation plan
**Topic:** Eliminate the out-of-memory (jetsam) crash when loading the Official b40c768nbt network on iOS

## Problem

After commit `4694079c` updated the Official network to `kata1-zhizi-b40c768nbt-fdx6d`
(40 blocks / 768 channels, ~824 MB `.bin.gz`), the app crashes on **iPhone 17** and
**iPad mini 6** immediately after the net downloads and the engine launches. The root
cause is **memory exhaustion (jetsam), not a stack overflow**: peak ~5 GB during the
one-time, on-device `bin.gz → CoreML` conversion + model load. It does **not** reproduce
on macOS or the iOS Simulator (they have enough RAM).

The crash is a *one-time conversion spike* on first load of a given model. Subsequent
launches hit the CoreML cache (`.mlmodelc/` on disk) and skip the conversion entirely.

## Goal

Make the b40c768 net's first-load conversion fit within a **4 GB device's** jetsam
budget (~2 GB raw, ~3 GB with the increased-memory-limit entitlement), so b40c768 works
as the Official network on **all** supported devices — including the 4 GB iPad mini 6.

**Constraints (decided during brainstorming):**

- **Keep on-device conversion.** Continue downloading `.bin.gz` and converting on the
  device; do not change the distribution model (no hosting of pre-converted artifacts).
- **Verify via a Mac-side conversion peak test.** Primary verification is an automated,
  CI-able test measuring the C++ converter pipeline's peak RSS. It does not capture
  `compileModel`/device jetsam directly; those are validated by on-device runs.
- Output `.mlpackage` bytes and inference precision (FP16 on ANE) must be unchanged.
- macOS GPU/MPSGraph path must remain byte-for-byte unaffected.

## Where the ~5 GB comes from

Conversion runs in **two non-overlapping phases**. The C++ converter structures are torn
down (their `convert_to_temp` call returns) *before* `MLModel.compileModel` runs, so the
two phases are budgeted separately.

| Phase | Resident today | Approx. peak today | Measured by |
|---|---|---|---|
| **Convert** (`katagocoreml_convert_to_temp`, C++) | decompressed buffer (B) + **3×** FP32 weights + per-layer FP16 temp | ~B + 3× weights | **Mac peak test** |
| **Compile** (`MLModel.compileModel`, after C++ teardown) | engine `modelDesc` weights (W1, FP32) + on-disk package + Apple working set | W1 + Apple internal | On-device only |

**The 3× FP32 duplication in the convert phase** (`cpp/external/katagocoreml/src/Converter.cpp:34,45,56-57`):

1. `model` — the parsed `KataGoModelDesc` (weights stored by value in each layer desc).
2. `builder`'s `m_ops.m_weights` — `WeightEntry.data` is `std::vector<float>` **by value**,
   so `KataGoOps::registerWeight` *copies* every tensor (`Operations.hpp:14-19,55-57`).
3. `weights_copy(weights.begin(), weights.end())` — an explicit full copy of all weights.

Plus the decompressed file buffer (`KataGoParser::m_buffer`) stays alive because the
`parser` local remains in scope until `convert()` returns. For an ~1.6 GB-decompressed
net: ≈ 1.6 (B) + 3 × 1.6 (W) + 0.8 (FP16) ≈ **5.6 GB**, matching the measured ~5 GB.

**W1 (engine `modelDesc`) is resident across both phases.** It is loaded in
`NeuralNet::loadModelFile` *before* conversion (`metalbackend.cpp:369-389`). The CoreML/ANE
inference path reads only scalar dims from it (`metalbackend.cpp:472-478`); only the
MPSGraph/GPU path consumes its weight arrays (`modelDescToSwift`, `metalbackend.cpp:347`).
On iOS (always ANE) W1's weights are dead weight.

## Strategy: five independent, individually-measurable levers

Applied in order; stop when the budget is met. **A5 is conditional** — implement only if
on-device measurement after A1–A4 still does not fit.

### A1 — Kill the redundant copies (convert phase) — low risk, big win

- **`WeightEntry` becomes a non-owning view** (`Operations.hpp`):
  ```cpp
  struct WeightEntry {
      std::string name;
      const float* data = nullptr;   // points into the live KataGoModelDesc
      size_t count = 0;
      std::vector<int64_t> shape;
      uint64_t blob_offset = 0;
  };
  ```
  `KataGoOps::registerWeight` stores `{name, vec.data(), vec.size(), shape}` instead of
  copying. Removes copy #2. `model` must stay alive through serialize — it already does
  (a `convert()` local; MILBuilder holds it by `const&`).
- **Drop `weights_copy`** (`Converter.cpp:56-57`): pass `builder.getWeights()` straight to
  the serializer. Removes copy #3. `WeightSerializer::serialize` takes
  `const std::vector<WeightEntry>&`; since views are const, move `blob_offset` tracking to
  a returned/parallel offsets structure rather than mutating entries in place.
- **Per-tensor FP16 to blob** (`WeightSerializer.cpp:11-36`): already loops per-entry with
  one `fp16_data` temp; keep it, just read from `entry.data`/`entry.count`. No full-model
  FP16 copy ever exists.

After A1, the convert-phase live set is exactly **one** `model` + one per-layer FP16 temp
(plus B until A2 lands).

### A2 — Streaming gzip parse (convert phase)

Replace the full-file `m_buffer` + `m_pos` indexing in `KataGoParser` with a streaming
reader over `gzFile`:

- A `GzStreamReader` holding the `gzFile`, a modest refill buffer (~1 MB), and primitives:
  `skipWhitespace`, `readToken` (text), `readBinaryBlock(dst, nbytes)` (bulk `gzread`
  straight into the destination FP32 vector).
- **Format detection without a global scan:** today `parse()` does `std::search` over the
  whole buffer for the `@BIN@` marker (`KataGoParser.cpp:94`). Replace with inline
  detection at the first `readFloats` binary block (the marker immediately precedes every
  binary float block); assert consistency thereafter. Both text and binary paths preserved.
- `readFloats` binary path: consume the `@BIN@` marker from the stream, then
  `readBinaryBlock` directly into the result vector — no whole-file buffer.

Net effect: the decompressed file (B) is never materialized; only ~1 MB refill buffer plus
the growing `model` exist during parse. Convert peak → ~1× weights.

**A2 is the highest correctness risk** (byte-level parser). Gated by the golden-output test
(below).

### A3 — Free engine W1 weights in ANE mode (both phases) — bonus steady-state win

In `convertAndCreateCoreMLOnlyHandle` (`metalbackend.cpp:451-511`), the scalar dims are
already read from `modelDesc` *before* the conversion bridge call:

1. Read scalar dims as today.
2. **Free `modelDesc`'s weight arrays** via a new `ModelDesc::releaseWeights()` that clears
   the large `std::vector`s but keeps scalars/dims — gated strictly to the ANE path.
3. Then run conversion + handle creation.

Removes W1 from **both** the convert and compile phases, and drops ~1.6 GB of steady-state
RSS for the whole iOS session.

**Safety:** must be a no-op in any GPU/MPSGraph configuration (macOS), where
`modelDescToSwift` copies those arrays. Guard: release only when the model is used
exclusively for ANE (no MPSGraph handle created from this `LoadedModel`). Exact guard
mechanism is a planning detail with that hard constraint; macOS GPU path stays unchanged.

### A4 — Increased-memory-limit entitlement (compile phase ceiling)

Add to `ios/KataGo iOS/KataGo iOS/KataGo iOS.entitlements`:
```xml
<key>com.apple.developer.kernel.increased-memory-limit</key>
<true/>
<key>com.apple.developer.kernel.extended-virtual-addressing</key>
<true/>
```
Raises the per-app jetsam ceiling on supported devices (meaningful bump even on the 4 GB
iPad mini 6). Existing iCloud/APS entitlements untouched. Unreleased app → enabling the
capability is low-friction.

### A5 — (Conditional, deepest) Full layer-streaming convert

Restructure so weights stream parse → FP16 → blob → free per layer, never holding the full
`model` resident: build the MIL program structure from metadata (names/shapes/offset
placeholders) while streaming weight bytes to the on-disk blob as each layer is parsed.
Convert peak → ~one layer.

**Trigger:** only if on-device peak after A1–A4 still exceeds the device budget. Tighten the
Mac test budget accordingly when implemented.

## Verification

### Mac-side peak test (verification spine) — new `cpp/external/katagocoreml/test/`

- New CMake `add_executable` + `add_test` target, host-only (not in the app), runnable via
  `ctest` on macOS.
- Runs `KataGoConverter::convert`, samples peak RSS via `getrusage(RUSAGE_SELF).ru_maxrss`
  (bytes on macOS).
- **Ratio-based budget**, model-size-independent: assert
  `peak_RSS < decompressed_size × R` (R ≈ 1.5). **Fails on today's ~3–4× duplication**,
  passes after A1/A2. Written first (TDD): watch it fail, implement until green.
- Fixture: a committed `cpp/tests/models/` net for the always-on CI assertion (e.g.
  `g170e-b10c128-…bin.gz`, the largest committed binary net, to best stress the ratio).
  Developer runs the same test locally against the real b40c768 to confirm the absolute
  peak on a representative net.

### Golden-output equivalence (guards the A1/A2 refactor) — expanded coverage

The refactor must produce **byte-identical** output to the pre-refactor converter. Byte
identity of the weight blob + model spec strictly implies identical inference, so no
separate numeric/inference comparison is needed for the converter (engine inference tests
already cover end-to-end).

**Fixtures (already committed under `cpp/tests/models/`):**

- `g170-b6c96-s175395328-d26788732.bin.gz` (binary `@BIN@`) **and**
  `g170-b6c96-s175395328-d26788732.txt.gz` (text) — the *same* net in both formats.
- `g170e-b10c128-s1141046784-d204142634.bin.gz` (binary, larger).
- `g103-b6c96-…txt.gz`, `grun2-b6c96-…txt.gz`, `grun50-b6c96-…txt.gz`,
  `run4-…b6c96.txt.gz` (older model versions, text) — exercise different version branches.

**Test types:**

1. **Characterization goldens (matrix).** For each committed fixture, across
   {FP16, FP32} × {19×19, 9×9} × {`optimize_identity_mask` on, off}, assert the refactored
   converter reproduces a committed golden — **SHA-256 of the weight blob** and **SHA-256
   of `model.mlmodel`** — generated from the pre-refactor converter at the start of
   implementation (goldens frozen as step 1, then the refactor must keep them green). The
   matrix exercises both parser paths, both precisions, the mask-constant/board-size paths,
   and the `optimize_identity_mask` branch.
2. **Cross-format equivalence.** Convert `g170-b6c96` from `.bin.gz` (streaming binary path)
   and from `.txt.gz` (text path); assert **identical weight blob**. Pits the rewritten
   streaming binary parser directly against the text parser — the core A2 risk — without
   relying on a frozen golden.
3. **Determinism.** Convert the same input twice → byte-identical output.

**Equivalence granularity:** weight blob bytes byte-identical (SHA-256); `model.mlmodel`
protobuf byte-identical (SHA-256), falling back to structural protobuf equality only if
serialization ordering proves unstable across runs.

**Named coverage gap (no silent gaps).** The committed CI fixtures are old (≈ v8–10,
ordinary + global-pooling blocks). They do **not** exercise **nested-bottleneck blocks**,
the **SGF metadata encoder**, or **model versions ≥ 15** — precisely the code paths the
target b40c768**nbt** uses. Those are covered by a **developer-run (not CI) golden** that
compares the refactored converter against a pre-refactor baseline on the real b40c768
(and/or a smaller modern nbt net), committing only the golden hashes. Closing this gap in
CI requires adding a small modern-architecture fixture (tracked as follow-up); until then
the developer-run golden is the gate for the nbt/metadata/v16 paths.

### Existing coverage

- Engine/inference tests must still load the compiled `.mlmodelc` and produce sane outputs.
- All three platforms (iOS / macOS / visionOS) must still build (per CLAUDE.md). The Mac
  test target is host-only and not part of the app.

## Error handling & fallbacks

- Streaming reader throws on truncated/corrupt gzip; `convert_to_temp` still returns
  `nullptr` on exception — no change to error reporting.
- The existing crash sentinel (`pendingLoadModelTitle`, `ModelRunnerView.swift`) +
  "may not have enough free memory" recovery banner (`ModelPickerView`) remain as the
  last-resort safety net; not removed.
- Precision unchanged (FP16 on ANE); golden test confirms identical weights.
- A3 release is a no-op in GPU/MPSGraph configs; macOS GPU build + inference must still pass.

## Expected outcome

A1 + A2 roughly quarter the convert peak (≈1.6 GB → ~1× weights, no B). A3 removes ~1.6 GB
of W1 from both phases. A4 raises the compile-phase ceiling. The bet: A1–A4 hit the 4 GB
target without needing A5. If not, A5 brings the convert peak to ~one layer.

## Affected files (anticipated)

- `cpp/external/katagocoreml/src/builder/Operations.hpp` (`WeightEntry`, `registerWeight`)
- `cpp/external/katagocoreml/src/builder/Operations.cpp`
- `cpp/external/katagocoreml/src/serializer/WeightSerializer.{hpp,cpp}`
- `cpp/external/katagocoreml/src/Converter.cpp`
- `cpp/external/katagocoreml/src/parser/KataGoParser.{hpp,cpp}` (streaming reader, A2)
- `cpp/external/katagocoreml/CMakeLists.txt` + new `cpp/external/katagocoreml/test/`
  (peak test + golden matrix + cross-format + determinism; reuses `cpp/tests/models/`
  fixtures; committed golden hashes). Follow-up: add a small modern-architecture
  (nested-bottleneck / v15+ / SGF-metadata) fixture to close the named CI coverage gap.
- `cpp/neuralnet/desc.h` / `desc.cpp` (`ModelDesc::releaseWeights`, A3)
- `cpp/neuralnet/metalbackend.cpp` (call `releaseWeights` in ANE path, A3)
- `ios/KataGo iOS/KataGo iOS/KataGo iOS.entitlements` (A4)

## Out of scope

- Hosting pre-converted models / changing the distribution model.
- Pointing the Official entry at a smaller net.
- The `requireExactNNLen`/`requireMaxBoardSize` MPS experiment (separate future work).
