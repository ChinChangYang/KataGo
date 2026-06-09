# Migrate KataGo Anytime to the MLX backend — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the KataGo Anytime Xcode app (iOS + macOS + visionOS) from `USE_METAL_BACKEND` to the MLX backend (PR #1199), linking MLX's C++ library via Apple's `mlx-swift` package.

**Architecture:** Spike-first, then phased. Phase 0 proves MLX's C++ API links and runs inside the Xcode app and locks the exact linking mechanism. Phase 1 lands PR #1199's full source onto `ios-dev` while the app still builds on Metal (no behavior change). Phase 2 flips macOS to MLX (target-membership swap + macro + glue). Phase 3 flips iOS + visionOS and adds memory caps. The MPSGraph GPU path is cleanly removed; the CoreML/ANE bridge (`metalbackend.swift` + `metallayers.swift`) and the `0`/`100` device convention are reused unchanged.

**Tech Stack:** Xcode (`xcodebuild`), Swift/C++ interop, Apple `mlx-swift` (`Cmlx` C++ target), the `xcodeproj` Ruby gem for `project.pbxproj` edits, KataGo C++ engine, `katagocoreml` CoreML converter.

**Spec:** `docs/superpowers/specs/2026-06-09-migrate-app-to-mlx-backend-design.md`

## Conventions used throughout

- Repo root: `/Users/chinchangyang/Code/KataGo-ios-dev`
- Project: `ios/KataGo iOS/KataGo Anytime.xcodeproj`, scheme `KataGo Anytime`, app target **`KataGo iOS`**.
- Build commands (from `CLAUDE.md`):
  - iOS sim: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
  - macOS: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug`
  - visionOS sim: `xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug` (local visionOS runtime may be missing → may only build in CI/device).
- The `xcodeproj` gem is available (used previously per repo convention). Install if needed: `gem install xcodeproj`.
- **Manual GUI steps are explicitly flagged** `[MANUAL — Xcode GUI]`. Adding a SwiftPM package is not reliably scriptable; the engineer performs those in Xcode.

---

## Phase 0 — Spike: lock the MLX↔Xcode-C++ linking mechanism (throwaway)

**Purpose:** Prove `#include <mlx/mlx.h>` + `mx::` compiles, links, and runs (JIT Metal kernels) inside the `KataGo iOS` app target on macOS + iOS simulator. Determine the concrete linking mechanism (see spec §C). This branch is discarded; only the learnings carry forward.

### Task 0.1: Create the throwaway spike branch

**Files:** none (git only)

- [ ] **Step 1: Branch from `ios-dev`**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git checkout ios-dev
git checkout -b spike/mlx-cmlx-linking
```

- [ ] **Step 2: Confirm clean starting build (macOS)**

Run:
```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **` (baseline before any change).

### Task 0.2: Add the `mlx-swift` package to the app target

**Files:** Modify `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (via Xcode)

- [ ] **Step 1: `[MANUAL — Xcode GUI]` Add the package**

In Xcode: open `KataGo Anytime.xcodeproj` → File → Add Package Dependencies… → enter `https://github.com/ml-explore/mlx-swift` → Dependency Rule: **Exact Version `0.31.4`** → Add Package → on the products sheet, add the **`MLX`** library to the **`KataGo iOS`** target (only `MLX` for now). Finish.

- [ ] **Step 2: Verify the package reference landed**

Run:
```bash
grep -c "mlx-swift" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
```
Expected: a non-zero count (XCRemoteSwiftPackageReference + product dependency entries).

- [ ] **Step 3: Commit the spike checkpoint**

```bash
git add -A && git commit -m "spike: add mlx-swift 0.31.4 (MLX product) to app target"
```

### Task 0.3: Add a C++ self-test that exercises the `mx::` API

**Files:**
- Create: `cpp/neuralnet/mlxspike.cpp`
- Create: `cpp/neuralnet/mlxspike.h`
- Modify: `ios/KataGo iOS/KataGoInterface/KataGoCpp.cpp` (call the self-test once at startup)

- [ ] **Step 1: Write the spike header**

`cpp/neuralnet/mlxspike.h`:
```cpp
#ifndef NEURALNET_MLXSPIKE_H_
#define NEURALNET_MLXSPIKE_H_
// Throwaway spike: returns 5.0 if the MLX C++ API compiles, links, and evaluates.
double mlxSpikeSelfTest();
#endif
```

- [ ] **Step 2: Write the spike source**

`cpp/neuralnet/mlxspike.cpp`:
```cpp
#include "mlxspike.h"
#include <mlx/mlx.h>
namespace mx = mlx::core;
double mlxSpikeSelfTest() {
  mx::array a({2.0f});
  mx::array b({3.0f});
  mx::array c = mx::add(a, b);   // forces a Metal kernel (JIT) on GPU stream
  mx::eval(c);
  return static_cast<double>(c.item<float>());  // expect 5.0
}
```

- [ ] **Step 3: Call it once from existing startup C++**

In `ios/KataGo iOS/KataGoInterface/KataGoCpp.cpp`, add near the top of the function that runs at engine launch (the one containing the `-override-config metalDeviceToUseThread0=` line, ~line 94), before building the args:
```cpp
#include "../../../cpp/neuralnet/mlxspike.h"   // add with the other includes at top
// ... inside the launch function, early:
fprintf(stderr, "[mlx-spike] self-test = %f\n", mlxSpikeSelfTest());
```

- [ ] **Step 4: `[MANUAL — Xcode GUI or xcodeproj]` Add `mlxspike.cpp` to the `KataGo iOS` target**

Either drag `mlxspike.cpp`/`.h` into the project under the `neuralnet` group with target membership `KataGo iOS`, or run:
```bash
ruby -e '
require "xcodeproj"
p = Xcodeproj::Project.open("ios/KataGo iOS/KataGo Anytime.xcodeproj")
t = p.targets.find { |x| x.name == "KataGo iOS" }
ref = p.files.find { |f| f.display_name == "metalbackend.cpp" }
grp = ref.parent
cpp = grp.new_file("../../../cpp/neuralnet/mlxspike.cpp")
grp.new_file("../../../cpp/neuralnet/mlxspike.h")
t.add_file_references([cpp])
p.save
puts "added mlxspike.cpp to KataGo iOS"
'
```
(Adjust the `new_file` relative path so it resolves to `cpp/neuralnet/mlxspike.cpp`; verify the file shows the correct path in Xcode.)

- [ ] **Step 5: Set C++20 on the app target**

```bash
ruby -e '
require "xcodeproj"
p = Xcodeproj::Project.open("ios/KataGo iOS/KataGo Anytime.xcodeproj")
t = p.targets.find { |x| x.name == "KataGo iOS" }
t.build_configurations.each { |c| c.build_settings["CLANG_CXX_LANGUAGE_STANDARD"] = "c++20" }
p.save
puts "set c++20"
'
```

### Task 0.4: Build + run on macOS — mechanism attempt (1)

**Files:** Modify `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (header search path)

- [ ] **Step 1: Build macOS, expect a header-not-found failure first**

Run the macOS build (see Conventions). Expected: **FAIL** with `'mlx/mlx.h' file not found` — because `Cmlx`'s headers are private (spec §C). This failure confirms the mechanism gap.

- [ ] **Step 2: Add the `Cmlx` header search path (mechanism 1)**

Find the SPM checkout path, then add it to `HEADER_SEARCH_PATHS`:
```bash
# locate the Cmlx headers in DerivedData SourcePackages
find ~/Library/Developer/Xcode/DerivedData -type d -path '*mlx-swift/Source/Cmlx/mlx' 2>/dev/null | head -1
```
Add the printed path (and its `mlx-c` sibling) to the app target:
```bash
ruby -e '
require "xcodeproj"
p = Xcodeproj::Project.open("ios/KataGo iOS/KataGo Anytime.xcodeproj")
t = p.targets.find { |x| x.name == "KataGo iOS" }
# Use a build-setting variable that resolves per build rather than a hardcoded DerivedData path if possible.
paths = ["$(BUILD_DIR)/../../SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx",
         "$(BUILD_DIR)/../../SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx-c"]
t.build_configurations.each do |c|
  cur = c.build_settings["HEADER_SEARCH_PATHS"] || ["$(inherited)"]
  cur = [cur] unless cur.is_a?(Array)
  c.build_settings["HEADER_SEARCH_PATHS"] = (cur + paths).uniq
end
p.save
puts "added Cmlx header search paths"
'
```

- [ ] **Step 3: Rebuild macOS**

Run the macOS build. Expected: `** BUILD SUCCEEDED **`. If headers still not found, the `$(BUILD_DIR)`-relative path is wrong — print `xcodebuild -showBuildSettings | grep BUILD_DIR` and adjust, or fall back to the absolute `find` path from Step 1.

- [ ] **Step 4: Run the macOS app and verify the self-test prints 5.0**

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "KataGo Anytime.app" -path '*Debug*' 2>/dev/null | head -1)
"$APP/Contents/MacOS/KataGo Anytime" 2>&1 | grep -m1 "mlx-spike"
```
Expected: `[mlx-spike] self-test = 5.000000`. This proves compile + link + JIT-kernel-eval on macOS. (If the app needs UI to reach the code path, instead launch it normally and check Console.app for `[mlx-spike]`.)

### Task 0.5: Build + run on iOS simulator

- [ ] **Step 1: Build iOS sim**

Run the iOS Simulator build. Expected: `** BUILD SUCCEEDED **`. If the header path differs for the simulator SDK, the same `$(BUILD_DIR)`-relative path should still resolve (SourcePackages is shared); fix per Task 0.4 Step 3 if not.

- [ ] **Step 2: Run on iOS sim and verify the self-test**

```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
# install + launch, then read the log:
xcrun simctl launch --console-pty booted $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(find ~/Library/Developer/Xcode/DerivedData -name 'KataGo Anytime.app' -path '*iphonesimulator*' | head -1)/Info.plist") 2>&1 | grep -m1 "mlx-spike"
```
Expected: `[mlx-spike] self-test = 5.000000`. This proves JIT Metal kernels run on the iOS simulator. (Simulator Metal is a software path — correctness over speed is fine here.)

### Task 0.6: Record the locked mechanism, discard the spike

**Files:** Modify `docs/superpowers/specs/2026-06-09-migrate-app-to-mlx-backend-design.md` (note the chosen mechanism)

- [ ] **Step 1: Decide & record**

If mechanism (1) worked (MLX product + header search path) on both macOS and iOS sim → record "Mechanism 1 confirmed" in the spec §C, including the exact `HEADER_SEARCH_PATHS` value that worked. If it was too fragile (path didn't resolve, or CI concern), record the decision to use mechanism (2) (mlx-swift fork exposing `Cmlx` as a product) and stop to confirm with the user before Phase 2.

- [ ] **Step 2: Commit the spec note on `ios-dev` (not the spike branch)**

```bash
git stash push -- docs/superpowers/specs/2026-06-09-migrate-app-to-mlx-backend-design.md 2>/dev/null || true
git checkout ios-dev
git stash pop 2>/dev/null || true
git add docs/superpowers/specs/2026-06-09-migrate-app-to-mlx-backend-design.md
git commit -m "docs(mlx): record Phase 0 spike result — locked linking mechanism"
```

- [ ] **Step 3: Delete the spike branch**

```bash
git branch -D spike/mlx-cmlx-linking
```

---

## Phase 1 — Land PR #1199 source onto `ios-dev` (still on Metal)

**Purpose:** Bring the whole PR #1199 diff (MLX files + converter transformer #1205 + memory levers #1202 + desc/wiring) onto a feature branch. The app still builds on `USE_METAL_BACKEND` with no MLX dependency; the new `mlx*.cpp` files exist on disk but are **not** in the Xcode target, so they aren't compiled yet. This isolates "did the merge break the Metal build?" from "does MLX work?".

### Task 1.1: Create the migration feature branch

- [ ] **Step 1: Branch + fetch**

```bash
cd /Users/chinchangyang/Code/KataGo-ios-dev
git fetch origin
git checkout ios-dev
git checkout -b feature/mlx-app-migration
```

### Task 1.2: Merge the MLX branch and resolve conflicts

**Files:** Expected conflicts in `cpp/neuralnet/metalbackend.cpp`, `cpp/neuralnet/metalbackend.h` (both the PR and the iOS app modified them).

- [ ] **Step 1: Start the merge**

```bash
git merge --no-ff origin/mlx-backend-squash -m "merge: bring MLX backend (PR #1199) onto ios-dev"
```
Expected: merge stops with conflicts. List them:
```bash
git diff --name-only --diff-filter=U
```

- [ ] **Step 2: Resolve `metalbackend.cpp` / `.h` as a union**

For each conflict, keep **both** the iOS-app changes and the PR changes (they target different concerns: the app's iOS tweaks vs the PR's `aneOnly`/converter wiring). Where they touch the same lines, prefer the PR's version of the shared converter/`aneOnly` plumbing and re-apply the iOS-specific deltas on top. `metalbackend.cpp` stays in-tree (it is dropped from the Xcode *build* in Phase 2, not deleted from the repo, so the CMake `METAL` backend keeps working).

- [ ] **Step 3: Verify new files arrived and conflicts are resolved**

```bash
ls cpp/neuralnet/mlxbackend.cpp cpp/neuralnet/mlxwinotuner.cpp cpp/neuralnet/mlxwinotuner.h cpp/neuralnet/mlxwinograd.h cpp/neuralnet/mlxtests.cpp
git diff --name-only --diff-filter=U   # expected: empty
```
Expected: the five MLX paths exist; no unresolved conflicts remain.

### Task 1.3: Verify the Metal build still passes after the merge

The converter sources (`cpp/external/katagocoreml/src/*`, `cpp/neuralnet/desc.{cpp,h}`) and `metalbackend.cpp/.h` are already in the Xcode target, so their merged content recompiles now. The new `mlx*.cpp` are not in the target yet.

- [ ] **Step 1: Build iOS sim (still `USE_METAL_BACKEND`)**

Run the iOS Simulator build. Expected: `** BUILD SUCCEEDED **`. If the converter/desc changes fail to compile under the app's settings, fix the merge (most likely a missing include or a C++ standard mismatch — the converter changes were authored against the PR; reconcile here).

- [ ] **Step 2: Build macOS**

Run the macOS build. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the existing test suite (sanity)**

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -15
```
Expected: tests pass (no regression from the converter/desc merge).

### Task 1.4: Commit the merge

- [ ] **Step 1: Finalize**

```bash
git commit --no-edit   # completes the merge commit if not already committed
git log --oneline -1
```
Expected: the merge commit is recorded; the branch builds green on Metal.

---

## Phase 2 — Flip macOS to the MLX backend

**Purpose:** Make the macOS app actually run on MLX. Add the dependency, swap target membership, flip the macro, rewire the glue, validate both dispatch paths.

### Task 2.1: Add `mlx-swift` to the app target (real, on the migration branch)

**Files:** Modify `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj`

- [ ] **Step 1: `[MANUAL — Xcode GUI]` Add the package + product**

Same as Phase 0 Task 0.2 Step 1: add `https://github.com/ml-explore/mlx-swift` Exact `0.31.4`, link the **`MLX`** product to the **`KataGo iOS`** target.

- [ ] **Step 2: Apply the locked header-search-path + C++20 settings**

Apply the exact mechanism recorded in Phase 0 Task 0.6 (the `HEADER_SEARCH_PATHS` that worked, plus `CLANG_CXX_LANGUAGE_STANDARD = c++20`) using the `xcodeproj` Ruby snippets from Phase 0 Tasks 0.3 Step 5 and 0.4 Step 2.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(mlx): add mlx-swift dependency + C++20 to the app target"
```

### Task 2.2: Swap C++ backend file membership (drop Metal, add MLX)

**Files:** Modify `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj`

- [ ] **Step 1: Remove `metalbackend.cpp` from the build, add the MLX sources**

```bash
ruby -e '
require "xcodeproj"
p = Xcodeproj::Project.open("ios/KataGo iOS/KataGo Anytime.xcodeproj")
t = p.targets.find { |x| x.name == "KataGo iOS" }
# remove metalbackend.cpp from the compile sources (keep the file ref/in-tree)
t.source_build_phase.files.dup.each do |bf|
  if bf.file_ref && bf.file_ref.display_name == "metalbackend.cpp"
    t.source_build_phase.remove_build_file(bf)
    puts "removed metalbackend.cpp from build"
  end
end
# add the MLX sources to the same group as the (now spike-removed) backend files
grp = p.files.find { |f| f.display_name == "metalbackend.swift" }.parent
%w[mlxbackend.cpp mlxwinotuner.cpp mlxtests.cpp].each do |name|
  ref = grp.new_file("../../../cpp/neuralnet/#{name}")
  t.add_file_references([ref])
  puts "added #{name}"
end
%w[mlxwinograd.h mlxwinotuner.h].each { |h| grp.new_file("../../../cpp/neuralnet/#{h}") }
p.save
'
```
Verify the relative paths resolve to `cpp/neuralnet/...` (open in Xcode or check the produced `path =` lines).

- [ ] **Step 2: Verify membership**

```bash
grep -E "mlxbackend.cpp in Sources|mlxwinotuner.cpp in Sources|mlxtests.cpp in Sources" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj" | wc -l   # expect 3
grep -c "metalbackend.cpp in Sources" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"   # expect 0
```

### Task 2.3: Flip the backend macro

**Files:** Modify `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (the 2 build configs with `USE_METAL_BACKEND`, ~lines 3248 & 3316)

- [ ] **Step 1: Replace the define**

```bash
ruby -e '
require "xcodeproj"
p = Xcodeproj::Project.open("ios/KataGo iOS/KataGo Anytime.xcodeproj")
t = p.targets.find { |x| x.name == "KataGo iOS" }
t.build_configurations.each do |c|
  d = c.build_settings["GCC_PREPROCESSOR_DEFINITIONS"]
  next if d.nil?
  d = [d] unless d.is_a?(Array)
  c.build_settings["GCC_PREPROCESSOR_DEFINITIONS"] = d.map { |x| x == "USE_METAL_BACKEND" ? "USE_MLX_BACKEND" : x }
end
p.save
puts "flipped macro to USE_MLX_BACKEND"
'
grep -c "USE_MLX_BACKEND" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"   # expect >= 2
grep -c "USE_METAL_BACKEND" "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj" # expect 0
```

### Task 2.4: Rewire the C++ glue

**Files:** Modify `ios/KataGo iOS/KataGoInterface/KataGoCpp.cpp`

- [ ] **Step 1: Switch the backend include**

Change the include from `metalbackend.h` to `mlxbackend.h`:
```cpp
#include "../../../cpp/neuralnet/mlxbackend.h"
```
Remove the temporary spike include/call if any leftover (there should be none on this branch).

- [ ] **Step 2: Switch the device config key**

Change the override-config line (~line 94) from:
```cpp
subArgs.push_back(string("-override-config metalDeviceToUseThread0=") + to_string(metalDeviceToUse));
```
to:
```cpp
subArgs.push_back(string("-override-config mlxDeviceToUseThread0=") + to_string(metalDeviceToUse));
```
(The `metalDeviceToUse` parameter name can stay; only the emitted key changes. `0`→MLX-GPU, `100`→MLX ANE.)

### Task 2.5: Build macOS and resolve fallout

- [ ] **Step 1: Build macOS**

Run the macOS build. Expected eventually: `** BUILD SUCCEEDED **`. Likely issues to resolve:
- **Undefined symbols from `metalbackend.swift`/`metallayers.swift`** that previously came from `metalbackend.cpp`. If the Swift bridge calls C++ symbols only `metalbackend.cpp` defined, provide them from `mlxbackend.cpp` (which the PR already does in the CMake build) or add a thin shim. Compare against `origin/mlx-backend-squash`'s `metalbackend.swift` to confirm the expected symbol surface.
- **`mlxtests.cpp`** referencing a test harness symbol — keep it in the target (the PR gates it under `runnnlayertests`); if it pulls in unwanted deps, confirm it compiles standalone.

- [ ] **Step 2: Confirm the MLX backend is the active one**

```bash
grep -n "USE_MLX_BACKEND\|USE_METAL_BACKEND" cpp/neuralnet/mlxbackend.cpp cpp/neuralnet/metalbackend.cpp | head
```
Confirm `mlxbackend.cpp` is guarded by `USE_MLX_BACKEND` and `metalbackend.cpp` by `USE_METAL_BACKEND` (so only MLX compiles now).

### Task 2.6: Run the macOS app and validate both dispatch paths

- [ ] **Step 1: Launch and exercise MLX-GPU**

Launch the macOS app (Xcode Run, or the `find … KataGo Anytime.app` binary). In the app's backend setting, select **MLX/GPU** (still labeled "MPS/GPU" until Task 2.7). Load a model, start analysis on an empty 19×19 board. Expected: analysis runs, a non-zero **visits/s** appears, moves can be played. Watch the console for MLX errors.

- [ ] **Step 2: Exercise CoreML/NE**

Switch the backend setting to **CoreML/NE**, restart the engine. Expected: analysis runs via the ANE path (the same `katagocoreml` conversion the Metal backend used). Confirm a legal genmove and stable visits/s.

- [ ] **Step 3: Record results**

Note visits/s for both paths on a known position (sanity vs the PR's macOS numbers). No assertion threshold — this is a functional smoke test.

### Task 2.7: Relabel the UI option

**Files:** Modify `ios/KataGo iOS/KataGo iOS/BackendChoice.swift`

- [ ] **Step 1: Rename the raw value**

Change line 9 from:
```swift
case mpsGPU = "MPS/GPU"
```
to:
```swift
case mpsGPU = "MLX/GPU"
```
(Keep the enum case name `mpsGPU` to avoid churn across call sites; only the user-visible string and persisted value change. Acceptable — the app is unreleased and `platformDefault` covers any unknown stored value.)

- [ ] **Step 2: Build macOS to confirm no call-site breakage**

Run the macOS build. Expected: `** BUILD SUCCEEDED **`.

### Task 2.8: Commit Phase 2

- [ ] **Step 1: Commit**

```bash
git add -A
git commit -m "feat(mlx): flip macOS app to USE_MLX_BACKEND (swap sources, macro, glue, UI label)"
```

---

## Phase 3 — Flip iOS + visionOS and harden memory

**Purpose:** Get the same MLX build running on iOS (simulator + device) and visionOS, and add MLX memory caps to avoid iOS jetsam (prior b40c768 OOM at ~5 GB).

### Task 3.1: Build and run on the iOS simulator

- [ ] **Step 1: Build iOS sim**

Run the iOS Simulator build. Expected: `** BUILD SUCCEEDED **` (the header-search-path mechanism from Phase 0 already covers the simulator SDK). Resolve any simulator-only link issues.

- [ ] **Step 2: Run on iOS sim, validate both paths**

Launch on `iPhone 17` sim. Repeat Task 2.6 Steps 1–2 (MLX/GPU and CoreML/NE) on a 19×19 board. Expected: both run; CoreML/NE remains the iOS power-efficient default (`platformDefault` returns `.coremlNE` on non-macOS).

### Task 3.2: Add MLX memory caps for iOS/visionOS

**Files:** Modify `cpp/neuralnet/mlxbackend.cpp` (or the app's engine-launch C++ in `KataGoCpp.cpp`)

- [ ] **Step 1: Set conservative limits at backend init**

In the MLX backend's context/handle creation (or once at engine launch), on iOS/visionOS set MLX memory limits. Use platform guards so macOS keeps defaults:
```cpp
#if TARGET_OS_IOS || TARGET_OS_VISION
  // Cap MLX buffer cache / wired memory to avoid iOS jetsam (see b40c768 OOM history).
  mx::set_memory_limit(/* bytes, sized to the smallest target device, e.g. */ (size_t)2 * 1024 * 1024 * 1024);
  mx::set_cache_limit((size_t)256 * 1024 * 1024);
  mx::set_wired_limit((size_t)0);   // confirm the exact MLX 0.31.x API names/signatures
#endif
```
Verify the exact `mx::` memory API names and signatures against the linked MLX version (the names may live under `mx::set_memory_limit` / `mx::metal::*`); adjust to what the headers expose. Choose the cap by testing the largest model the app ships against the smallest supported device.

- [ ] **Step 2: Build iOS sim**

Run the iOS Simulator build. Expected: `** BUILD SUCCEEDED **`.

### Task 3.3: Validate on an iOS device

- [ ] **Step 1: `[MANUAL — device]` Run on a real device**

Build+run on a physical iPhone (signing required). Exercise CoreML/NE and MLX/GPU on 19×19 with the app's default model. Watch Xcode's memory gauge. Expected: no OOM/jetsam; visits/s plausible; JIT first-move latency acceptable (one-time).

- [ ] **Step 2: Tune caps if needed**

If memory pressure is high, lower the Task 3.2 limits and re-test. Record the chosen values in the spec.

### Task 3.4: visionOS

- [ ] **Step 1: Build visionOS (best effort locally)**

Run the visionOS Simulator build. Expected: `** BUILD SUCCEEDED **` **if** the visionOS sim runtime is installed; otherwise this fails with rc=70 locally (known: runtime not installed) → defer to CI/device. Record which.

- [ ] **Step 2: `[MANUAL]` Validate on visionOS where a runtime exists** (CI or device).

### Task 3.5: Finalize the branch

- [ ] **Step 1: Full build sweep**

```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -3
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -3
```
Expected: both `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Run tests**

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -15
```
Expected: tests pass.

- [ ] **Step 3: Commit + push**

```bash
git add -A
git commit -m "feat(mlx): iOS/visionOS on MLX backend + memory caps"
git push -u origin feature/mlx-app-migration
```

- [ ] **Step 4: Update project memory**

Update `project_migrate_app_to_mlx_backend.md` with the final linking mechanism, the memory-cap values, and visionOS validation status. Use the `superpowers:finishing-a-development-branch` skill to decide merge/PR.

---

## Self-review notes (coverage map)

- Spec §A (source merge) → Phase 1. §B (target membership swap) → Task 2.2. §C (MLX dependency + linking mechanism) → Phase 0 + Task 2.1. §D (macro + glue) → Tasks 2.3, 2.4. §E (UI label) → Task 2.7. §F (iOS memory caps) → Task 3.2.
- Phasing (spike → source → macOS → iOS/visionOS) → Phases 0–3.
- Clean replace of MPSGraph → Task 2.2 (drop `metalbackend.cpp` from build; kept in-tree for CMake `METAL`).
- Risks: MLX-in-Xcode → Phase 0; `metalbackend.swift` missing symbols → Task 2.5 Step 1; C++20 ripple → Phase 0 + Task 2.1; iOS memory → Task 3.2/3.3; visionOS local → Task 3.4.
