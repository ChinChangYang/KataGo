# Reduce On-Device CoreML Conversion Peak Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the one-time `bin.gz → CoreML` conversion peak memory so the b40c768nbt Official network loads without an OOM (jetsam) kill on a 4 GB iOS device.

**Architecture:** Five independent levers on the `katagocoreml` C++ converter + the Metal backend + app entitlements, fronted by a new `./katago runcoremlconverttests` test subcommand (built only under the METAL backend) that measures conversion peak RSS and locks output byte-equivalence. Levers: A1 stop the 3× FP32 weight duplication (weights become non-owning views), A2 stream the gzip parse (no full decompressed buffer), A3 free the engine's ANE-dead `modelDesc` weights, A4 add the increased-memory-limit entitlement. A5 (full layer-streaming) is deferred unless on-device measurement after A1–A4 still doesn't fit.

**Tech Stack:** C++17 (`cpp/external/katagocoreml`, `cpp/neuralnet`), KataGo's custom `Tests::` harness (`./katago <subcommand>`), CMake + Ninja METAL build, `getrusage` for RSS, `SHA2::get256` for golden hashes, an Apple `.entitlements` plist.

**Spec:** `docs/superpowers/specs/2026-05-30-reduce-conversion-peak-memory-design.md`

---

## Key facts the engineer must know

- **`katagocoreml` is compiled ONLY under the METAL backend.** `cpp/CMakeLists.txt` does `add_subdirectory(external/katagocoreml)` inside the METAL branch. All converter tests therefore live behind `#ifdef USE_METAL_BACKEND` and run only in a METAL build.
- **Build + run commands** (run from the `cpp/` directory, which makes `tests/models/...` paths resolve):
  ```bash
  cd /Users/chinchangyang/Code/KataGo-ios-dev/cpp
  cmake . -G Ninja -DUSE_BACKEND=METAL -DNO_GIT_REVISION=1   # first time / after CMake edits
  ninja                                                       # incremental rebuild
  ./katago runcoremlconverttests                              # run the converter tests
  ```
  After the first successful `cmake`, only `ninja` is needed for rebuilds.
- **`getrusage(RUSAGE_SELF).ru_maxrss` is in BYTES on macOS** (KB on Linux). The peak is process-lifetime maximum and monotonic, which is why the peak test lives in its **own** subcommand that does nothing else first.
- **The committed test nets are tiny** (`g170-b6c96` ≈ 3.6 MB, `g170e-b10c128`). They give a strong *correctness* signal but a weak *peak-memory* signal (process baseline dominates). The strict peak-ratio assertion only bites on a large net supplied locally via the `KATAGO_COREML_PEAK_MODEL` env var (point it at the real b40c768). Without that env var the peak test logs and applies only a loose sanity bound.
- **The converter is deterministic** and these levers must produce **byte-identical** `weight.bin` + `model.mlmodel`. Do NOT bump `katagocoreml`'s `VERSION` (it is embedded in `model.mlmodel` metadata and would change the golden hash).
- **Fixtures** (relative to `cpp/`):
  - `tests/models/g170-b6c96-s175395328-d26788732.bin.gz` (binary `@BIN@`)
  - `tests/models/g170-b6c96-s175395328-d26788732.txt.gz` (text — SAME net)
  - `tests/models/g170e-b10c128-s1141046784-d204142634.bin.gz` (binary, larger)

## File structure

| File | Responsibility | Change |
|---|---|---|
| `cpp/tests/testcoremlconvert.cpp` | All converter tests + RSS/hash helpers (METAL-guarded body) | Create |
| `cpp/tests/tests.h` | Declare the new `Tests::runCoremlConvert*` functions | Modify |
| `cpp/command/runtests.cpp` | `MainCmds::runcoremlconverttests` dispatcher (METAL-guarded body) | Modify |
| `cpp/main.h` | Declare `runcoremlconverttests` | Modify |
| `cpp/main.cpp` | Wire the `"runcoremlconverttests"` subcommand string | Modify |
| `cpp/CMakeLists.txt` | Add `tests/testcoremlconvert.cpp` to the test sources | Modify |
| `cpp/external/katagocoreml/src/builder/Operations.hpp` | `WeightEntry` → non-owning view; owned-temp store | Modify |
| `cpp/external/katagocoreml/src/builder/Operations.cpp` | `registerWeight` (view) + `registerOwnedWeight` (move) | Modify |
| `cpp/external/katagocoreml/src/builder/MILBuilder.cpp` | matmul-transpose site uses owned path | Modify |
| `cpp/external/katagocoreml/src/serializer/WeightSerializer.cpp` | read view (`data`/`count`) | Modify |
| `cpp/external/katagocoreml/src/Converter.cpp` | drop `weights_copy`; scope parser | Modify |
| `cpp/external/katagocoreml/src/parser/KataGoParser.hpp` | streaming reader members | Modify |
| `cpp/external/katagocoreml/src/parser/KataGoParser.cpp` | streaming gzip parse (A2) | Modify |
| `cpp/neuralnet/desc.h` | `ModelDesc::releaseWeights()` declaration (A3) | Modify |
| `cpp/neuralnet/desc.cpp` | `releaseWeights()` walk (A3) | Modify |
| `cpp/neuralnet/metalbackend.cpp` | free W1 in ANE convert path (A3) | Modify |
| `ios/KataGo iOS/KataGo iOS/KataGo iOS.entitlements` | increased-memory-limit entitlement (A4) | Modify |

---

## Task 1: Converter test harness scaffold + smoke test

Establishes the METAL-only `./katago runcoremlconverttests` subcommand and a single smoke test that converts the committed net. This is the foundation every later task builds on.

**Files:**
- Create: `cpp/tests/testcoremlconvert.cpp`
- Modify: `cpp/tests/tests.h`, `cpp/command/runtests.cpp`, `cpp/main.h`, `cpp/main.cpp`, `cpp/CMakeLists.txt`

- [ ] **Step 1: Read `ConversionOptions` defaults**

Run: `sed -n '1,120p' "cpp/external/katagocoreml/include/katagocoreml/Options.hpp"`
Confirm the field names used below (`board_x_size`, `board_y_size`, `compute_precision`, `optimize_identity_mask`, `min_batch_size`, `max_batch_size`) and their defaults. If `min_batch_size` defaults to 0, the test must set it to 1 (the converter throws on `min_batch_size < 1`). Adjust the helper in Step 2 accordingly.

- [ ] **Step 2: Create the test file with the smoke test**

Create `cpp/tests/testcoremlconvert.cpp`:

```cpp
#include "../tests/tests.h"

#ifdef USE_METAL_BACKEND

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include <sys/resource.h>
#include <zlib.h>

#include "../core/sha2.h"
#include "katagocoreml/KataGoConverter.hpp"

using namespace std;

namespace {

// Process-lifetime peak resident set size in bytes (macOS ru_maxrss is bytes).
static size_t peakRssBytes() {
  struct rusage usage;
  if(getrusage(RUSAGE_SELF, &usage) != 0)
    return 0;
  return (size_t)usage.ru_maxrss;
}

// SHA-256 hex digest of an entire file's bytes.
static string sha256OfFile(const string& path) {
  ifstream in(path, ios::binary);
  if(!in)
    throw runtime_error("sha256OfFile: cannot open " + path);
  vector<uint8_t> bytes((istreambuf_iterator<char>(in)), istreambuf_iterator<char>());
  char hash[65];
  SHA2::get256(bytes.data(), bytes.size(), hash);
  return string(hash);
}

// Number of decompressed bytes in a .gz file, using O(1) memory.
static size_t gzDecompressedSize(const string& path) {
  gzFile gz = gzopen(path.c_str(), "rb");
  if(!gz)
    throw runtime_error("gzDecompressedSize: cannot open " + path);
  vector<uint8_t> chunk(1024 * 1024);
  size_t total = 0;
  int n;
  while((n = gzread(gz, chunk.data(), (unsigned)chunk.size())) > 0)
    total += (size_t)n;
  gzclose(gz);
  return total;
}

// Convert a model and return the path to the produced weight.bin inside the .mlpackage.
// outPackageDir is the .mlpackage directory created at /tmp.
static string convertToTemp(
  const string& modelPath, const string& tag, int boardX, int boardY,
  bool fp16, bool optimizeMask, string& outPackageDir
) {
  outPackageDir = "/tmp/katago_convtest_" + tag + ".mlpackage";
  katagocoreml::ConversionOptions opts;
  opts.board_x_size = boardX;
  opts.board_y_size = boardY;
  opts.compute_precision = fp16 ? "FLOAT16" : "FLOAT32";
  opts.optimize_identity_mask = optimizeMask;
  opts.min_batch_size = 1;
  opts.max_batch_size = 8;
  katagocoreml::KataGoConverter::convert(modelPath, outPackageDir, opts);
  return outPackageDir + "/Data/com.apple.CoreML/weights/weight.bin";
}

} // namespace

void Tests::runCoremlConvertSmokeTest() {
  cout << "Running runCoremlConvertSmokeTest" << endl;
  const string model = "tests/models/g170-b6c96-s175395328-d26788732.bin.gz";
  string pkg;
  string weightBin = convertToTemp(model, "smoke", 19, 19, true, false, pkg);
  ifstream check(weightBin, ios::binary);
  testAssert(check.good());
  cout << "  weight.bin sha256 = " << sha256OfFile(weightBin) << endl;
  cout << "runCoremlConvertSmokeTest passed" << endl;
}

#endif // USE_METAL_BACKEND
```

Note: `weight.bin` is written inside the `.mlpackage` by `MPL::ModelPackage` under `Data/com.apple.CoreML/weights/weight.bin`. If Step 2's build/run shows a different layout, fix the `convertToTemp` return path to the actual location (the smoke test's `testAssert(check.good())` will catch it).

- [ ] **Step 3: Declare the test functions in `tests.h`**

In `cpp/tests/tests.h`, add at the end of the `namespace Tests {` block (before its closing `}`):

```cpp
  //testcoremlconvert.cpp (METAL backend only)
  void runCoremlConvertSmokeTest();
  void runCoremlConvertCrossFormatTest();
  void runCoremlConvertDeterminismTest();
  void runCoremlConvertGoldenTest();
  void runCoremlConvertPeakMemoryTest();
```

- [ ] **Step 4: Declare the subcommand in `main.h`**

In `cpp/main.h`, after line 37 (`int runconfigtests(...)`), add inside `namespace MainCmds {`:

```cpp
  int runcoremlconverttests(const std::vector<std::string>& args);
```

- [ ] **Step 5: Wire the subcommand string in `main.cpp`**

In `cpp/main.cpp`, after the `runconfigtests` else-if (around line 129-130), add:

```cpp
  else if(subcommand == "runcoremlconverttests")
    return MainCmds::runcoremlconverttests(subArgs);
```

- [ ] **Step 6: Implement the dispatcher in `runtests.cpp`**

In `cpp/command/runtests.cpp`, add this function (e.g. after `MainCmds::runconfigtests`). The body is METAL-guarded so non-METAL builds still compile:

```cpp
int MainCmds::runcoremlconverttests(const vector<string>& args) {
  (void)args;
#ifdef USE_METAL_BACKEND
  Tests::runCoremlConvertSmokeTest();
  Tests::runCoremlConvertCrossFormatTest();
  Tests::runCoremlConvertDeterminismTest();
  Tests::runCoremlConvertGoldenTest();
  Tests::runCoremlConvertPeakMemoryTest();
  cout << "All CoreML converter tests passed" << endl;
  return 0;
#else
  cout << "runcoremlconverttests is only available in a METAL backend build" << endl;
  return 0;
#endif
}
```

For Task 1, temporarily comment out the four not-yet-written calls (`runCoremlConvertCrossFormatTest`, `Determinism`, `Golden`, `PeakMemory`) so the build links; uncomment each as its task lands.

- [ ] **Step 7: Add the test source to CMake**

In `cpp/CMakeLists.txt`, find the test sources list (the block adding `tests/*.cpp`, near the other `tests/test*.cpp` entries) and add:

```cmake
  tests/testcoremlconvert.cpp
```

- [ ] **Step 8: Build and run the smoke test**

Run:
```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev/cpp
cmake . -G Ninja -DUSE_BACKEND=METAL -DNO_GIT_REVISION=1 && ninja && ./katago runcoremlconverttests
```
Expected: `Running runCoremlConvertSmokeTest`, a printed sha256, `runCoremlConvertSmokeTest passed`, then `All CoreML converter tests passed`.

- [ ] **Step 9: Commit**

```bash
git add cpp/tests/testcoremlconvert.cpp cpp/tests/tests.h cpp/command/runtests.cpp cpp/main.h cpp/main.cpp cpp/CMakeLists.txt
git commit -m "test: scaffold katagocoreml converter test subcommand + smoke test"
```

---

## Task 2: Cross-format equivalence test (the A2 safety net)

Converts the same net from `.bin.gz` (binary path) and `.txt.gz` (text path) and asserts identical `weight.bin`. This is the strongest guard for the A2 parser rewrite and needs no stored golden. Passes on current code (both paths already agree).

**Files:** Modify `cpp/tests/testcoremlconvert.cpp`

- [ ] **Step 1: Write the test**

Add to `cpp/tests/testcoremlconvert.cpp` (inside the `#ifdef USE_METAL_BACKEND` region, after the smoke test):

```cpp
void Tests::runCoremlConvertCrossFormatTest() {
  cout << "Running runCoremlConvertCrossFormatTest" << endl;
  const string binModel = "tests/models/g170-b6c96-s175395328-d26788732.bin.gz";
  const string txtModel = "tests/models/g170-b6c96-s175395328-d26788732.txt.gz";
  // Full matrix: precision x board size x optimize_identity_mask. For identical
  // options, the binary-stream parser and the text parser must agree exactly.
  for(bool fp16 : {true, false}) {
    for(auto bs : { std::pair<int,int>{19, 19}, std::pair<int,int>{9, 9} }) {
      for(bool mask : {false, true}) {
        string tag = string(fp16 ? "fp16" : "fp32") + "_" + to_string(bs.first)
                   + "_" + (mask ? "mask" : "nomask");
        string binPkg, txtPkg;
        string binWeights = convertToTemp(binModel, "xfmt_bin_" + tag, bs.first, bs.second, fp16, mask, binPkg);
        string txtWeights = convertToTemp(txtModel, "xfmt_txt_" + tag, bs.first, bs.second, fp16, mask, txtPkg);
        string binHash = sha256OfFile(binWeights);
        string txtHash = sha256OfFile(txtWeights);
        cout << "  " << tag << ": bin=" << binHash << " txt=" << txtHash << endl;
        testAssert(binHash == txtHash);
      }
    }
  }
  cout << "runCoremlConvertCrossFormatTest passed" << endl;
}
```

This runs 8 combinations (2 precisions × 2 board sizes × 2 mask settings), exercising both parser paths, both precisions, the board-size/mask-constant code, and the `optimize_identity_mask` branch — the spec's full equivalence matrix, with binary-vs-text as the assertion.

- [ ] **Step 2: Enable the call and run**

Uncomment `Tests::runCoremlConvertCrossFormatTest();` in `runtests.cpp`.
Run: `cd /Users/chinchangyang/Code/KataGo-ios-dev/cpp && ninja && ./katago runcoremlconverttests`
Expected: `runCoremlConvertCrossFormatTest passed` (binary and text paths produce identical weight blobs at both precisions).

- [ ] **Step 3: Commit**

```bash
git add cpp/tests/testcoremlconvert.cpp cpp/command/runtests.cpp
git commit -m "test: cross-format (bin vs txt) weight-blob equivalence for converter"
```

---

## Task 3: Determinism test

Converts the same input twice and asserts byte-identical `weight.bin`. Cheap insurance that conversion has no nondeterminism the refactor could perturb. Passes on current code.

**Files:** Modify `cpp/tests/testcoremlconvert.cpp`

- [ ] **Step 1: Write the test**

Add inside the `#ifdef` region:

```cpp
void Tests::runCoremlConvertDeterminismTest() {
  cout << "Running runCoremlConvertDeterminismTest" << endl;
  const string model = "tests/models/g170e-b10c128-s1141046784-d204142634.bin.gz";
  string pkgA, pkgB;
  string a = convertToTemp(model, "det_a", 19, 19, true, false, pkgA);
  string b = convertToTemp(model, "det_b", 19, 19, true, false, pkgB);
  testAssert(sha256OfFile(a) == sha256OfFile(b));
  cout << "runCoremlConvertDeterminismTest passed" << endl;
}
```

- [ ] **Step 2: Enable the call and run**

Uncomment `Tests::runCoremlConvertDeterminismTest();` in `runtests.cpp`.
Run: `cd /Users/chinchangyang/Code/KataGo-ios-dev/cpp && ninja && ./katago runcoremlconverttests`
Expected: `runCoremlConvertDeterminismTest passed`.

- [ ] **Step 3: Commit**

```bash
git add cpp/tests/testcoremlconvert.cpp cpp/command/runtests.cpp
git commit -m "test: converter output determinism"
```

---

## Task 4: Characterization golden test

Pins the exact `weight.bin` + `model.mlmodel` SHA-256 for one config, generated from the **current** converter. Catches any drift the self-comparing tests would miss (e.g. if both parser paths changed identically). Generate the golden first, then it must stay green through A1/A2.

**Files:** Modify `cpp/tests/testcoremlconvert.cpp`

- [ ] **Step 1: Write the test with placeholder golden constants**

Add inside the `#ifdef` region:

```cpp
void Tests::runCoremlConvertGoldenTest() {
  cout << "Running runCoremlConvertGoldenTest" << endl;
  // Golden hashes captured from the pre-refactor converter for
  // g170-b6c96, FP16, 19x19, optimize_identity_mask=false.
  // DO NOT change katagocoreml VERSION (embedded in model.mlmodel) or these drift.
  const string GOLDEN_WEIGHT_SHA = "<FILL_IN_STEP_2>";
  const string GOLDEN_MODEL_SHA  = "<FILL_IN_STEP_2>";

  const string model = "tests/models/g170-b6c96-s175395328-d26788732.bin.gz";
  string pkg;
  string weightBin = convertToTemp(model, "golden", 19, 19, true, false, pkg);
  string modelSpec = pkg + "/Data/com.apple.CoreML/model.mlmodel";

  string weightSha = sha256OfFile(weightBin);
  string modelSha = sha256OfFile(modelSpec);
  cout << "  weight.bin sha256 = " << weightSha << endl;
  cout << "  model.mlmodel sha256 = " << modelSha << endl;

  testAssert(weightSha == GOLDEN_WEIGHT_SHA);
  testAssert(modelSha == GOLDEN_MODEL_SHA);
  cout << "runCoremlConvertGoldenTest passed" << endl;
}
```

Note: confirm the `model.mlmodel` relative path inside the `.mlpackage` (the `model.mlmodel` filename is set in `CoreMLSerializer::createPackage`). Fix `modelSpec` if the printed path differs.

- [ ] **Step 2: Capture the golden values**

Uncomment `Tests::runCoremlConvertGoldenTest();` in `runtests.cpp`.
Run: `cd /Users/chinchangyang/Code/KataGo-ios-dev/cpp && ninja && ./katago runcoremlconverttests`
The two `testAssert` lines will fail; copy the printed `weight.bin sha256` and `model.mlmodel sha256` into `GOLDEN_WEIGHT_SHA` and `GOLDEN_MODEL_SHA`.

- [ ] **Step 3: Re-run to confirm green**

Run: `ninja && ./katago runcoremlconverttests`
Expected: `runCoremlConvertGoldenTest passed`.

- [ ] **Step 4: Commit**

```bash
git add cpp/tests/testcoremlconvert.cpp cpp/command/runtests.cpp
git commit -m "test: pin converter golden weight.bin + model.mlmodel hashes"
```

---

## Task 5: Peak-memory measurement + ratio assertion

Measures conversion peak RSS. The strict ratio gate (`peak < decompressed × R`) is enforced only when `KATAGO_COREML_PEAK_MODEL` points at a large net (run locally against b40c768); otherwise it logs and applies a loose sanity bound on the small committed net.

**Files:** Modify `cpp/tests/testcoremlconvert.cpp`

- [ ] **Step 1: Write the test**

Add inside the `#ifdef` region:

```cpp
void Tests::runCoremlConvertPeakMemoryTest() {
  cout << "Running runCoremlConvertPeakMemoryTest" << endl;
  const char* envModel = getenv("KATAGO_COREML_PEAK_MODEL");
  bool strict = (envModel != nullptr);
  string model = strict ? string(envModel)
                        : string("tests/models/g170e-b10c128-s1141046784-d204142634.bin.gz");

  size_t decompressed = gzDecompressedSize(model);
  string pkg;
  string weightBin = convertToTemp(model, "peak", 19, 19, true, false, pkg);
  (void)weightBin;
  size_t peak = peakRssBytes();

  double ratio = (double)peak / (double)decompressed;
  cout << "  model = " << model << endl;
  cout << "  decompressed = " << (decompressed / (1024 * 1024)) << " MB" << endl;
  cout << "  peak RSS     = " << (peak / (1024 * 1024)) << " MB" << endl;
  cout << "  ratio        = " << ratio << "x" << endl;

  // R: target peak/decompressed multiplier. Pre-refactor holds ~3x FP32 copies
  // + the decompressed buffer, so the real (large-net) ratio starts well above this.
  const double R = 1.5;
  if(strict) {
    testAssert(ratio < R);
  } else {
    // Small committed net: baseline RSS dominates; just guard against a runaway.
    testAssert(peak < (size_t)2 * 1024 * 1024 * 1024);
  }
  cout << "runCoremlConvertPeakMemoryTest passed" << endl;
}
```

- [ ] **Step 2: Run the loose (committed-net) path**

Uncomment `Tests::runCoremlConvertPeakMemoryTest();` in `runtests.cpp`.
Run: `cd /Users/chinchangyang/Code/KataGo-ios-dev/cpp && ninja && ./katago runcoremlconverttests`
Expected: prints the ratio and `runCoremlConvertPeakMemoryTest passed` (loose bound). Record the printed ratio as the pre-refactor baseline.

- [ ] **Step 3: Observe the RED on the real net (local, large-net gate)**

Obtain the b40c768 `.bin.gz` locally (the Official network download, or any large net) and run:
```bash
KATAGO_COREML_PEAK_MODEL=/path/to/kata1-zhizi-b40c768nbt-fdx6d.bin.gz ./katago runcoremlconverttests
```
Expected: `runCoremlConvertPeakMemoryTest` **FAILS** the `ratio < 1.5` assertion (peak ≈ 3–4× decompressed) — this is the red state A1+A2 will turn green. Record the peak MB and ratio.

- [ ] **Step 4: Commit**

```bash
git add cpp/tests/testcoremlconvert.cpp cpp/command/runtests.cpp
git commit -m "test: conversion peak-RSS ratio gate (strict on KATAGO_COREML_PEAK_MODEL)"
```

---

## Task 6: A1 — `WeightEntry` becomes a non-owning view

Remove copies #2 and #3 by making `WeightEntry` reference the weights in the live `model` instead of copying them. The one `registerWeight` site that passes a temporary (the matmul transpose) gets an owned-buffer path.

**Files:** Modify `cpp/external/katagocoreml/src/builder/Operations.hpp`, `Operations.cpp`, `MILBuilder.cpp`, `serializer/WeightSerializer.cpp`

- [ ] **Step 1: Change `WeightEntry` + `KataGoOps` to views in `Operations.hpp`**

Replace the `WeightEntry` struct (lines 13-19) with:

```cpp
/// Weight entry for blob file storage. `data`/`count` are a NON-OWNING view into
/// the live KataGoModelDesc (or into KataGoOps::m_owned for derived tensors).
struct WeightEntry {
    std::string name;
    const float* data = nullptr;
    size_t count = 0;
    std::vector<int64_t> shape;
    uint64_t blob_offset = 0;  // Set during serialization
};
```

Add `#include <deque>` near the top. In `class KataGoOps`, add a second registration method and an owned-buffer store. Replace the `registerWeight` declaration (lines 54-57) with:

```cpp
    /// Register a weight that lives in the model (stored as a non-owning view).
    std::string registerWeight(const std::string& name,
                               const std::vector<float>& data,
                               const std::vector<int64_t>& shape);

    /// Register a derived/temporary weight; KataGoOps takes ownership so the
    /// view stays valid through serialization.
    std::string registerOwnedWeight(const std::string& name,
                                    std::vector<float>&& data,
                                    const std::vector<int64_t>& shape);
```

And in the `private:` section add (a `std::deque` keeps element addresses stable across appends, unlike `std::vector`):

```cpp
    std::deque<std::vector<float>> m_owned;
```

- [ ] **Step 2: Implement both methods in `Operations.cpp`**

Replace `registerWeight` (lines 15-25) with:

```cpp
std::string KataGoOps::registerWeight(const std::string& name,
                                       const std::vector<float>& data,
                                       const std::vector<int64_t>& shape) {
    WeightEntry entry;
    entry.name = name;
    entry.data = data.data();
    entry.count = data.size();
    entry.shape = shape;
    entry.blob_offset = 0;
    m_weights.push_back(std::move(entry));
    return name;
}

std::string KataGoOps::registerOwnedWeight(const std::string& name,
                                            std::vector<float>&& data,
                                            const std::vector<int64_t>& shape) {
    m_owned.push_back(std::move(data));
    const std::vector<float>& stored = m_owned.back();
    WeightEntry entry;
    entry.name = name;
    entry.data = stored.data();
    entry.count = stored.size();
    entry.shape = shape;
    entry.blob_offset = 0;
    m_weights.push_back(std::move(entry));
    return name;
}
```

- [ ] **Step 3: Route the matmul-transpose temporary through the owned path in `MILBuilder.cpp`**

The transpose site builds a local `transposed_weights` (around lines 950-961) and calls `addConstOp(block, weight_name, transposed_weights, transposed_shape);`. `addConstOp` (line 211) forwards to `m_ops.registerWeight`, which would now store a dangling view. Replace that one `addConstOp(...)` call (line 961) with a direct owned registration plus the const-op emission it needs. First inspect `addConstOp` to see what MIL op it appends besides `registerWeight`:

Run: `sed -n '205,250p' cpp/external/katagocoreml/src/builder/MILBuilder.cpp`

Then refactor `addConstOp` to split weight registration from op emission. Change `addConstOp` (line 211-217 region) so registration is a parameter:

```cpp
// New private helper: emit the const op given an already-registered weight name.
void MILBuilder::emitConstOp(CoreML::Specification::MILSpec::Block* block,
                             const std::string& name,
                             const std::vector<int64_t>& shape) {
    // <-- move here the body of the existing addConstOp that builds the const
    //     operation/attributes using `name` and `shape`, i.e. everything AFTER
    //     the m_ops.registerWeight(...) line.
}

void MILBuilder::addConstOp(CoreML::Specification::MILSpec::Block* block,
                            const std::string& name,
                            const std::vector<float>& data,
                            const std::vector<int64_t>& shape) {
    m_ops.registerWeight(name, data, shape);
    emitConstOp(block, name, shape);
}

void MILBuilder::addOwnedConstOp(CoreML::Specification::MILSpec::Block* block,
                                 const std::string& name,
                                 std::vector<float>&& data,
                                 const std::vector<int64_t>& shape) {
    m_ops.registerOwnedWeight(name, std::move(data), shape);
    emitConstOp(block, name, shape);
}
```

Declare `emitConstOp` and `addOwnedConstOp` in `MILBuilder.hpp` next to `addConstOp`. Then at line 961 replace:

```cpp
    addConstOp(block, weight_name, transposed_weights, transposed_shape);
```
with:
```cpp
    addOwnedConstOp(block, weight_name, std::move(transposed_weights), transposed_shape);
```

- [ ] **Step 4: Read the view in `WeightSerializer.cpp`**

Replace the loop body (lines 17-33) so it uses `entry.data` (pointer) and `entry.count`:

```cpp
    for(auto& entry : weights) {
        if(use_fp16) {
            std::vector<MILBlob::Fp16> fp16_data(entry.count);
            for(size_t i = 0; i < entry.count; ++i) {
                fp16_data[i] = MILBlob::Fp16::FromFloat(entry.data[i]);
            }
            MILBlob::Util::Span<const MILBlob::Fp16> span(fp16_data.data(), fp16_data.size());
            entry.blob_offset = writer.WriteData(span);
            total_bytes += entry.count * sizeof(MILBlob::Fp16);
        } else {
            MILBlob::Util::Span<const float> span(entry.data, entry.count);
            entry.blob_offset = writer.WriteData(span);
            total_bytes += entry.count * sizeof(float);
        }
    }
```

- [ ] **Step 5: Build and run all converter tests (goldens must stay green)**

Run: `cd /Users/chinchangyang/Code/KataGo-ios-dev/cpp && ninja && ./katago runcoremlconverttests`
Expected: smoke, cross-format, determinism, **golden** all pass (byte-identical output preserved), and the peak ratio (re-run with `KATAGO_COREML_PEAK_MODEL`) drops — copies #2 and #3 of the weight DATA are gone (the `weights_copy` vector now copies only view structs).

- [ ] **Step 6: Commit**

```bash
git add cpp/external/katagocoreml/src/builder/Operations.hpp cpp/external/katagocoreml/src/builder/Operations.cpp cpp/external/katagocoreml/src/builder/MILBuilder.hpp cpp/external/katagocoreml/src/builder/MILBuilder.cpp cpp/external/katagocoreml/src/serializer/WeightSerializer.cpp
git commit -m "perf(katagocoreml): weights as non-owning views to drop 2 of 3 FP32 copies"
```

---

## Task 7: A1 cleanup — drop `weights_copy` and scope the parser

`weights_copy` is now a shallow copy of view structs; remove it for clarity and pass the builder's weights directly. Also scope the parser so the (still-full, until A2) decompressed buffer is destroyed before serialize.

**Files:** Modify `cpp/external/katagocoreml/src/Converter.cpp`, `MILBuilder.hpp`

- [ ] **Step 1: Expose a mutable weights accessor on `MILBuilder`**

`WeightSerializer::serialize` and `CoreMLSerializer::serialize` take `std::vector<WeightEntry>&` (they set `blob_offset`). In `MILBuilder.hpp`, ensure there is a non-const accessor:

```cpp
    std::vector<WeightEntry>& getWeightsMutable() { return m_ops.getWeightsMutable(); }
```
and in `Operations.hpp` add to `KataGoOps`:
```cpp
    std::vector<WeightEntry>& getWeightsMutable() { return m_weights; }
```

- [ ] **Step 2: Rewrite the parse/serialize section of `Converter.cpp`**

Replace lines 32-34 (parser) so the parser is scoped, and lines 53-57 (build + `weights_copy`):

```cpp
    // Parse KataGo model (parser + its decompressed buffer freed at end of scope)
    KataGoModelDesc model;
    {
        KataGoParser parser(input_path);
        model = parser.parse();
    }
```
and:
```cpp
    auto program = builder.build();
    // Serialize directly from the builder's weight views (no copy).
    std::vector<WeightEntry>& weights = builder.getWeightsMutable();
```
Then update the final serialize call (line 85) to pass `weights` instead of `weights_copy`:
```cpp
    serializer.serialize(program.get(), weights, output_path, final_options);
```
Confirm `KataGoModelDesc` is movable (it has `std::vector`/`std::optional` members and no deleted move) so `model = parser.parse();` compiles; if not, keep `KataGoModelDesc model = parser.parse();` but wrap only the `KataGoParser` lifetime — i.e. make `parse()` the last use of the parser and let the `parser` local fall out of scope naturally before `builder.build()` (move the `MILBuilder` construction after a `}` that ends the parser's scope).

- [ ] **Step 3: Build and run all converter tests**

Run: `cd /Users/chinchangyang/Code/KataGo-ios-dev/cpp && ninja && ./katago runcoremlconverttests`
Expected: all converter tests pass (goldens unchanged).

- [ ] **Step 4: Commit**

```bash
git add cpp/external/katagocoreml/src/Converter.cpp cpp/external/katagocoreml/src/builder/MILBuilder.hpp cpp/external/katagocoreml/src/builder/Operations.hpp
git commit -m "perf(katagocoreml): drop weights_copy, scope parser buffer before serialize"
```

---

## Task 8: A2 — streaming gzip parse (no full decompressed buffer)

Replace the whole-file `m_buffer` with an on-demand gzip stream so the ~decompressed-file-sized buffer is never resident. Highest correctness risk; the cross-format + golden tests are the gate.

**Files:** Modify `cpp/external/katagocoreml/src/parser/KataGoParser.hpp`, `KataGoParser.cpp`

- [ ] **Step 1: Replace the parser's buffer members in `KataGoParser.hpp`**

Replace lines 33-36 (`m_model_path`, `m_buffer`, `m_pos`, `m_binary_floats`) with a streaming reader holding the gz handle and a small refill buffer:

```cpp
    std::string m_model_path;
    gzFile m_gz = nullptr;
    std::vector<uint8_t> m_refill;   // bounded refill buffer (~1 MB)
    size_t m_refillPos = 0;          // read cursor within m_refill
    size_t m_refillLen = 0;          // valid bytes in m_refill
    bool m_binary_floats = true;
    bool m_formatDetected = false;
```
Add `#include <zlib.h>` to the header (or forward via `typedef` if you prefer keeping zlib out of the header — simplest is to include it). Add private stream primitives:

```cpp
    // Streaming primitives (read from m_gz via m_refill)
    bool refill();                   // returns false at EOF
    int  peekByte();                 // -1 at EOF
    int  getByte();                  // -1 at EOF
    void readExact(uint8_t* dst, size_t n, const std::string& name);
```
Remove `loadFile()`. Keep `readUntilWhitespace`, `skipWhitespace`, `readString`, `readInt`, `readFloat`, `readBool`, `readFloats` (their implementations change).

- [ ] **Step 2: Implement the streaming primitives in `KataGoParser.cpp`**

Replace `loadFile()` and the low-level readers (lines 36-184) with a streaming implementation. Open the gz in the constructor body or at start of `parse()`:

```cpp
bool KataGoParser::refill() {
    if(m_gz == nullptr) return false;
    int n = gzread(m_gz, m_refill.data(), (unsigned)m_refill.size());
    if(n < 0) {
        int errnum;
        const char* errmsg = gzerror(m_gz, &errnum);
        throw std::runtime_error("Error reading gzip stream: " + std::string(errmsg));
    }
    m_refillPos = 0;
    m_refillLen = (size_t)n;
    return n > 0;
}

int KataGoParser::peekByte() {
    if(m_refillPos >= m_refillLen) {
        if(!refill()) return -1;
    }
    return (int)m_refill[m_refillPos];
}

int KataGoParser::getByte() {
    int c = peekByte();
    if(c >= 0) m_refillPos++;
    return c;
}

void KataGoParser::readExact(uint8_t* dst, size_t n, const std::string& name) {
    size_t got = 0;
    while(got < n) {
        if(m_refillPos >= m_refillLen) {
            if(!refill())
                throw std::runtime_error(name + ": unexpected EOF in binary block");
        }
        size_t avail = m_refillLen - m_refillPos;
        size_t take = std::min(avail, n - got);
        std::memcpy(dst + got, m_refill.data() + m_refillPos, take);
        m_refillPos += take;
        got += take;
    }
}
```

Rewrite the text readers against the stream:

```cpp
void KataGoParser::skipWhitespace() {
    int c;
    while((c = peekByte()) >= 0) {
        if(c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
        m_refillPos++;
    }
}

void KataGoParser::readUntilWhitespace(std::string& out) {
    out.clear();
    int c;
    while((c = peekByte()) >= 0) {
        if(c == ' ' || c == '\t' || c == '\n' || c == '\r') break;
        out += (char)c;
        m_refillPos++;
    }
}
```
`readString`/`readInt`/`readFloat`/`readBool` keep their bodies (they call `readString` then `std::stoi`/`std::stof`).

- [ ] **Step 3: Open the stream and detect format in `parse()`**

Replace `parse()` (lines 88-99). KataGo `.bin.gz` model files put their float blocks behind a `@BIN@` marker; the old code scanned the whole file. Stream version: detect on the first `readFloats` binary block instead. Also support a plain (non-`.gz`) path by wrapping with `gzopen` (zlib transparently reads uncompressed files too):

```cpp
KataGoModelDesc KataGoParser::parse() {
    m_gz = gzopen(m_model_path.c_str(), "rb");
    if(m_gz == nullptr)
        throw std::runtime_error("Cannot open file: " + m_model_path);
    m_refill.resize(1024 * 1024);
    m_refillPos = 0;
    m_refillLen = 0;
    m_formatDetected = false;   // decided at first readFloats
    m_binary_floats = true;
    KataGoModelDesc model;
    try {
        model = parseModel();
    } catch(...) {
        gzclose(m_gz);
        m_gz = nullptr;
        throw;
    }
    gzclose(m_gz);
    m_gz = nullptr;
    return model;
}
```
Note: `gzopen` reads uncompressed files transparently, so the previous separate `.gz`-vs-plain branch is no longer needed.

- [ ] **Step 4: Stream `readFloats` with inline `@BIN@` detection**

Replace `readFloats` (lines 148-184). The format is: optional whitespace, then either ASCII float tokens or a `@BIN@` marker immediately preceding `count*4` little-endian float32 bytes. Detect format once, at the first call, by peeking for `@`:

```cpp
std::vector<float> KataGoParser::readFloats(size_t count, const std::string& name) {
    std::vector<float> floats(count);
    skipWhitespace();

    if(!m_formatDetected) {
        m_binary_floats = (peekByte() == '@');
        m_formatDetected = true;
    }

    if(!m_binary_floats) {
        for(size_t i = 0; i < count; i++)
            floats[i] = readFloat();
        return floats;
    }

    // Binary: consume the "@BIN@" marker, then read count*4 raw bytes.
    char marker[5];
    readExact(reinterpret_cast<uint8_t*>(marker), 5, name);
    if(std::memcmp(marker, "@BIN@", 5) != 0)
        throw std::runtime_error(name + ": expected @BIN@ marker for binary float block");

    readExact(reinterpret_cast<uint8_t*>(floats.data()), count * 4, name);
    return floats;
}
```
Notes: the old code scanned forward past arbitrary bytes to the `@`; here `skipWhitespace` + the per-block `@BIN@` consume is equivalent because in KataGo binary files each float block is preceded only by whitespace then the marker. Keep `#include <cstring>` and `#include <algorithm>`.

- [ ] **Step 5: Build and run all converter tests — equivalence MUST hold**

Run: `cd /Users/chinchangyang/Code/KataGo-ios-dev/cpp && ninja && ./katago runcoremlconverttests`
Expected: smoke, **cross-format** (binary stream vs text), **determinism**, **golden** all pass — byte-identical output. If the golden fails, the streaming parser diverged; debug against the cross-format test (it isolates binary-vs-text).

- [ ] **Step 6: Confirm the peak drop on the real net**

Run: `KATAGO_COREML_PEAK_MODEL=/path/to/b40c768.bin.gz ./katago runcoremlconverttests`
Expected: the peak ratio now satisfies `ratio < 1.5` (the decompressed buffer is gone and only one FP32 copy remains) — the test that was RED in Task 5 Step 3 is now GREEN. Record the new peak MB.

- [ ] **Step 7: Commit**

```bash
git add cpp/external/katagocoreml/src/parser/KataGoParser.hpp cpp/external/katagocoreml/src/parser/KataGoParser.cpp
git commit -m "perf(katagocoreml): stream gzip parse, drop full decompressed buffer (A2)"
```

---

## Task 9: A3 — free the engine's ANE-dead `modelDesc` weights

The engine loads the full `ModelDesc` (W1) before conversion; in ANE mode its weight arrays are never read again (only MPSGraph/GPU uses them). Free them right after reading the scalar dims the bridge needs, removing W1 from both the convert and compile phases (and ~1.6 GB of steady-state RSS on iOS).

**Files:** Modify `cpp/neuralnet/desc.h`, `cpp/neuralnet/desc.cpp`, `cpp/neuralnet/metalbackend.cpp`

- [ ] **Step 1: Declare `releaseWeights()` on `ModelDesc`**

In `cpp/neuralnet/desc.h`, in `struct ModelDesc` (after `getSupportedRules`, around line 389), add:

```cpp
  // Frees all weight arrays (conv/matmul/bias/batchnorm), keeping scalar shape
  // metadata intact. Safe to call once the weights are no longer needed (e.g.
  // CoreML/ANE inference, which reads weights from the compiled .mlmodelc).
  void releaseWeights();
```

- [ ] **Step 2: Implement the walk in `desc.cpp`**

At the end of `cpp/neuralnet/desc.cpp` (before the final namespace/`#endif` if any; this file is plain global-namespace functions), add file-local helpers and the method. Mirror the existing `iterConvLayers` block-dispatch (`desc.cpp:742-762`, `1143-1160`) for the type-erased `blocks`:

```cpp
static void releaseVec(std::vector<float>& v) { std::vector<float>().swap(v); }

static void releaseConv(ConvLayerDesc& c) { releaseVec(c.weights); }

static void releaseBN(BatchNormLayerDesc& b) {
  releaseVec(b.mean); releaseVec(b.variance); releaseVec(b.scale);
  releaseVec(b.bias); releaseVec(b.mergedScale); releaseVec(b.mergedBias);
}

static void releaseMatMul(MatMulLayerDesc& m) { releaseVec(m.weights); }
static void releaseMatBias(MatBiasLayerDesc& m) { releaseVec(m.weights); }

static void releaseResidual(ResidualBlockDesc& b) {
  releaseBN(b.preBN); releaseConv(b.regularConv);
  releaseBN(b.midBN); releaseConv(b.finalConv);
}

static void releaseGPool(GlobalPoolingResidualBlockDesc& b) {
  releaseBN(b.preBN); releaseConv(b.regularConv); releaseConv(b.gpoolConv);
  releaseBN(b.gpoolBN); releaseMatMul(b.gpoolToBiasMul);
  releaseBN(b.midBN); releaseConv(b.finalConv);
}

static void releaseBlocks(std::vector<std::pair<int, unique_ptr_void>>& blocks);

static void releaseNested(NestedBottleneckResidualBlockDesc& b) {
  releaseBN(b.preBN); releaseConv(b.preConv);
  releaseBlocks(b.blocks);
  releaseBN(b.postBN); releaseConv(b.postConv);
}

static void releaseBlocks(std::vector<std::pair<int, unique_ptr_void>>& blocks) {
  for(size_t i = 0; i < blocks.size(); i++) {
    if(blocks[i].first == ORDINARY_BLOCK_KIND)
      releaseResidual(*(ResidualBlockDesc*)blocks[i].second.get());
    else if(blocks[i].first == GLOBAL_POOLING_BLOCK_KIND)
      releaseGPool(*(GlobalPoolingResidualBlockDesc*)blocks[i].second.get());
    else if(blocks[i].first == NESTED_BOTTLENECK_BLOCK_KIND)
      releaseNested(*(NestedBottleneckResidualBlockDesc*)blocks[i].second.get());
    else
      testAssert(false);
  }
}

static void releaseSGFEncoder(SGFMetadataEncoderDesc& e) {
  releaseMatMul(e.mul1); releaseMatBias(e.bias1);
  releaseMatMul(e.mul2); releaseMatBias(e.bias2);
  releaseMatMul(e.mul3);
}

void ModelDesc::releaseWeights() {
  // Trunk
  releaseConv(trunk.initialConv);
  releaseMatMul(trunk.initialMatMul);
  if(trunk.metaEncoderVersion > 0)
    releaseSGFEncoder(trunk.sgfMetadataEncoder);
  releaseBlocks(trunk.blocks);
  releaseBN(trunk.trunkTipBN);
  // Policy head
  releaseConv(policyHead.p1Conv); releaseConv(policyHead.g1Conv);
  releaseBN(policyHead.g1BN); releaseMatMul(policyHead.gpoolToBiasMul);
  releaseBN(policyHead.p1BN); releaseConv(policyHead.p2Conv);
  releaseMatMul(policyHead.gpoolToPassMul); releaseMatBias(policyHead.gpoolToPassBias);
  releaseMatMul(policyHead.gpoolToPassMul2);
  // Value head
  releaseConv(valueHead.v1Conv); releaseBN(valueHead.v1BN);
  releaseMatMul(valueHead.v2Mul); releaseMatBias(valueHead.v2Bias);
  releaseMatMul(valueHead.v3Mul); releaseMatBias(valueHead.v3Bias);
  releaseMatMul(valueHead.sv3Mul); releaseMatBias(valueHead.sv3Bias);
  releaseConv(valueHead.vOwnershipConv);
}
```
Note: confirm `testAssert` is available in `desc.cpp` (it is used by `iterConvLayers` in the same file). If `desc.cpp` has a trailing `#endif`, insert the code before it.

- [ ] **Step 3: Free W1 in the ANE convert path of `metalbackend.cpp`**

In `convertAndCreateCoreMLOnlyHandle` (`metalbackend.cpp:451`), the function is reached only for ANE (its caller returns `none()` unless `gpuIdx == METAL_MUX_ANE`). The bridge call reads scalar dims from `modelDesc` at lines 472-478. Capture those scalars into locals first, then release W1's weights before the (file-re-reading) conversion. Right before the `invokeCoreMLBridge(...)` call (line 468), insert:

```cpp
  // ANE path only: the compiled .mlmodelc carries the weights; the engine's
  // ModelDesc weight arrays are never read again. Free them to remove ~1 net's
  // worth of FP32 weights from the conversion peak and from steady-state RSS.
  // (modelDesc scalar dims below stay valid; releaseWeights() keeps them.)
  const_cast<LoadedModel*>(loadedModel)->modelDesc.releaseWeights();
```
The scalar fields passed to `invokeCoreMLBridge` (`numInputChannels`, etc., lines 472-478) and to the legacy fallback (lines 502-508) are untouched by `releaseWeights()`. The `ComputeHandle` constructor's later reads of `modelDesc->modelVersion`/`metaEncoderVersion` (lines 585-586) and `InputBuffers`' `m.policyHead.p2Conv.outChannels` (line 648) are also scalar and remain valid.

- [ ] **Step 4: Build all three platforms (A3 touches shared engine code)**

This task changes `desc.h`/`desc.cpp` (shared) and `metalbackend.cpp`. Verify the METAL C++ build first, then the three app platforms.
```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev/cpp && ninja && ./katago runcoremlconverttests
```
Expected: converter tests still pass (this task does not change conversion output).
Then the app builds (from `ios/KataGo iOS`):
```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug
```
Expected: both build succeed. (visionOS sim runtime may be unavailable locally — skip if it fails to install per project memory.)

- [ ] **Step 5: Sanity-check inference still works (ANE weights freed)**

Launch the macOS app (or run on a device) and confirm a model loads and analysis produces moves — i.e. freeing W1 did not break CoreML inference (which reads from the compiled `.mlmodelc`, not `modelDesc`).
Run: `xcodebuild build ...` already done; then run the app via the `run` skill or Xcode and load a net.
Expected: analysis runs normally; no crash referencing empty weight arrays.

- [ ] **Step 6: Commit**

```bash
git add cpp/neuralnet/desc.h cpp/neuralnet/desc.cpp cpp/neuralnet/metalbackend.cpp
git commit -m "perf(metal): free ANE-dead ModelDesc weights after dim read (A3)"
```

---

## Task 10: A4 — increased-memory-limit entitlement

Raise the per-app jetsam ceiling on supported devices.

**Files:** Modify `ios/KataGo iOS/KataGo iOS/KataGo iOS.entitlements`

- [ ] **Step 1: Add the entitlement keys**

In `ios/KataGo iOS/KataGo iOS/KataGo iOS.entitlements`, inside the top-level `<dict>` (after the existing iCloud array, before `</dict>`), add:

```xml
	<key>com.apple.developer.kernel.increased-memory-limit</key>
	<true/>
	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
	<true/>
```

- [ ] **Step 2: Build for iOS to confirm signing accepts the entitlement**

Run (from `ios/KataGo iOS`):
```bash
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug
```
Expected: build succeeds. (If a provisioning-profile error appears for the increased-memory-limit capability, enable the capability in the target's Signing & Capabilities, or note it for the device build — the simulator build should not require it.)

- [ ] **Step 3: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/KataGo iOS.entitlements"
git commit -m "feat(ios): add increased-memory-limit entitlement (A4)"
```

---

## Task 11: Final verification & device measurement

- [ ] **Step 1: Full converter test suite (Mac)**

Run: `cd /Users/chinchangyang/Code/KataGo-ios-dev/cpp && ninja && ./katago runcoremlconverttests`
Expected: all converter tests pass. Also run the broader suite to confirm no regression: `./katago runtests`.

- [ ] **Step 2: Strict peak gate on the real net (Mac)**

Run: `KATAGO_COREML_PEAK_MODEL=/path/to/b40c768.bin.gz ./katago runcoremlconverttests`
Expected: `runCoremlConvertPeakMemoryTest passed` with `ratio < 1.5`. Record before/after peak MB in the commit message.

- [ ] **Step 3: All three app platforms build**

From `ios/KataGo iOS`, build iOS Simulator, macOS, and (if the runtime is installed) visionOS Simulator per `CLAUDE.md`.
Expected: builds succeed.

- [ ] **Step 4: On-device load test (the real acceptance gate)**

Install on the iPhone 17 and the iPad mini 6. Download/select the Official b40c768 net and confirm it loads and runs analysis without a jetsam kill. Capture the on-device peak (Xcode memory gauge / Instruments).
- If both devices load successfully: the OOM is fixed; proceed to Step 5.
- If the 4 GB iPad mini 6 still OOMs: implement **A5** (full layer-streaming convert) per the spec, then re-measure. A5 is out of scope for this plan's tasks and triggers only here.

- [ ] **Step 5: Final commit / branch wrap-up**

Use the finishing-a-development-branch skill to merge/PR. Note in the PR the measured before/after conversion peak and the on-device load results.

---

## Notes on deferred work

- **A5 (full layer-streaming convert)** is intentionally NOT a task here. It is triggered only if Task 11 Step 4 shows the 4 GB device still OOMs after A1–A4. It would restructure the converter to stream weights parse→FP16→blob→free per layer (peak ≈ one layer) and tighten the peak test's `R`.
- **Modern-architecture CI fixture:** the committed nets don't exercise nested-bottleneck blocks / SGF-metadata / model versions ≥ 15 (what b40c768nbt uses). The developer-run `KATAGO_COREML_PEAK_MODEL` golden/peak run against the real b40c768 is the gate for those paths until a small modern fixture is committed (spec follow-up).
