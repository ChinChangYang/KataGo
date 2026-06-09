# Migrate KataGo Anytime to the MLX backend — Design

**Date:** 2026-06-09
**Status:** Approved design, pending spec review → implementation plan
**Branch:** `ios-dev`

## Goal

Migrate the KataGo Anytime Xcode app on **all three platforms (iOS, macOS, visionOS)** from the Metal backend (`USE_METAL_BACKEND`) to the **MLX backend** (`USE_MLX_BACKEND`) from lightvector/KataGo **PR #1199** (branch `origin/mlx-backend-squash`). After migration the app runs neural-net inference through MLX, exposing the existing user-facing backend toggle as **MLX-GPU vs CoreML/NE**.

Non-goals: changing the engine's search/UI behavior, supporting non-Apple platforms, or keeping the old MPSGraph GPU path (it is removed — the app is unreleased, no back-compat needed).

## Background / current state

- `ios-dev` = `origin/master` + ~1149 iOS-app commits (master fully contained). PR #1199 is based on `master`.
- `ios-dev` currently has **none** of PR #1199: no `cpp/neuralnet/mlx*` files, and it also lacks the PR's prerequisites — the CoreML converter transformer support (#1205, `parseTransformerAttentionBlock`) and the CoreML/ANE memory levers (#1202, `ComputeContext::aneOnly`, `ModelDesc::releaseWeights()`). The migration must therefore bring the **whole** PR diff, not just the MLX files.
- The app compiles the C++ engine **directly into the Xcode targets** (~291 `cpp/` file refs) and builds with `USE_METAL_BACKEND`. `katagocoreml` is **compiled from source** in Xcode (0 refs to the prebuilt `Libraries/*/libkatagocoreml.a`), so converter source changes flow in by editing source.
- The Metal backend today provides **both** the MPSGraph GPU path and the CoreML/ANE dispatch (`gpuIdx=100`). PR #1199's MLX backend mirrors this: one backend, two dispatch paths (MLX-GPU Winograd FP16, and ANE via the same Swift CoreML bridge), selected per server thread, honoring the same `100`=ANE convention.

### How dispatch is wired (unchanged shape after migration)

```
BackendChoice (UI Picker, BackendChoice.swift)
  .mpsGPU  = "MPS/GPU"  -> metalDeviceToUse 0    (relabel -> "MLX/GPU", value stays 0)
  .coremlNE = "CoreML/NE" -> metalDeviceToUse 100  (unchanged)
        |
        v  ModelRunnerView.swift:100
KataGoHelper.runGtp(..., metalDeviceToUse:)   (KataGoHelper.swift)
        |
        v  KataGoCpp.cpp:94
-override-config metalDeviceToUseThread0=<int>   ->  mlxDeviceToUseThread0=<int>
        |
        v
C++ engine selects MLX device: 0 = MLX-GPU, 100 = MLX ANE (MLX_MUX_ANE)
```

## Decisions (locked with user)

1. **Scope:** full app migration, all 3 platforms, `USE_METAL_BACKEND` → `USE_MLX_BACKEND`.
2. **MLX linking:** depend on Apple's `mlx-swift` SwiftPM package; the C++-compiling app target links its internal **`Cmlx`** target (the MLX C++ library). Xcode compiles MLX from source per destination; Metal kernels JIT at runtime (no unsigned-`.metallib` App Store problem). Pin a tag (~`0.31.4`). Build via `xcodebuild` only. Requires C++20.
3. **Dispatch UI:** keep the existing `BackendChoice` toggle; relabel "MPS/GPU" → "MLX/GPU" (value `0` unchanged); "CoreML/NE" (`100`) unchanged. MLX honors the `100`=ANE convention, so no value remapping.
4. **Sequencing:** **spike → phased.**
5. **Old Metal-GPU path:** **clean replace** — drop `metalbackend.cpp` from the build.

## Architecture / components changed

### A. C++ source — bring PR #1199 onto `ios-dev`
Merge `origin/mlx-backend-squash` into `ios-dev`. Pulls:
- New: `cpp/neuralnet/mlxbackend.cpp`, `mlxwinotuner.{cpp,h}`, `mlxwinograd.h`, `mlxtests.cpp`.
- Prerequisites `ios-dev` lacks: converter transformer support (#1205), memory levers (#1202), `desc.cpp/.h` changes, and the `setup.cpp` / `main.cpp` / `benchmark.cpp` / `tune.cpp` wiring.
- Expected conflicts **only** where both the PR and the iOS app modified `metalbackend.cpp` / `metalbackend.h`. Resolve as a union; `metalbackend.cpp` is being dropped from the Xcode build anyway (still kept in-tree for the CMake `METAL` backend).

### B. Xcode target membership (the swap)
- **Remove** `metalbackend.cpp` from the app target's compile sources.
- **Add** `mlxbackend.cpp`, `mlxwinotuner.cpp`, `mlxtests.cpp`, plus headers `mlxwinograd.h`, `mlxwinotuner.h`. (`mlxbackend.cpp` and `metalbackend.cpp` both implement `nninterface.h`; exactly one may be compiled or duplicate symbols result.)
- **Keep** `metalbackend.swift` + `metallayers.swift` unchanged — the MLX ANE path reuses them (mirrors the PR's `KataGoSwift` static lib, which compiles exactly these two Swift files).
- Register new files in `project.pbxproj` via the `xcodeproj` Ruby gem (app target = `KataGo Anytime`, tests = `KataGo AnytimeTests`), per existing convention.

### C. MLX dependency
- Add `mlx-swift` (pinned tag) as an SPM package dependency of the project.
- Set `CLANG_CXX_LANGUAGE_STANDARD = c++20` (Cmlx requires C++20).
- Build via Xcode/`xcodebuild` only (the project already does for all 3 platforms).
- **Linking mechanism (nuance — Phase 0 locks the exact path).** `Cmlx` is the MLX C++
  library *target* but is **not a declared package product** (mlx-swift exposes only
  `MLX`, `MLXNN`, `MLXFast`, `MLXRandom`, `MLXOptimizers`, `MLXFFT`, `MLXLinalg`), and its
  `mlx`/`mlx-c` header search paths are **private** to building Cmlx — so they are not
  propagated to a C++ consumer. Concretely, to make `#include <mlx/mlx.h>` + `mx::` resolve
  and link from `mlxbackend.cpp`, the candidate mechanisms, in order of preference:
  1. **Link the `MLX` product** (transitively builds/links `Cmlx`'s objects) **+ add an
     explicit `HEADER_SEARCH_PATHS`** entry pointing at the SPM checkout's
     `…/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx` (and `…/mlx-c`). Least invasive;
     risk is the DerivedData-relative path being fragile across machines/CI.
  2. **Thin `mlx-swift` fork** (or local SwiftPM package) that adds `Cmlx` to `products:` as a
     `.library` with a proper public-headers layout, pinned like the main fork. Keeps the
     SPM/source-compiled model; robust headers; cost is maintaining a small fork.
  3. **Prebuilt `Cmlx.xcframework`** via mlx-swift's `tools/create-xcframework.sh`, vendored
     under `Libraries/` (matches the `libkatagocoreml` pattern). Robust; departs from the
     pure-SPM choice — fallback only.
  Phase 0 tries (1); if it proves too fragile, choose (2) (preferred, stays SPM) or (3).

### D. Backend macro + C++ glue
- Flip the preprocessor define `USE_METAL_BACKEND` → `USE_MLX_BACKEND` in the 2 build configs (`project.pbxproj` lines ~3248, ~3316).
- `KataGoCpp.cpp`: include `mlxbackend.h` instead of `metalbackend.h`; change the override-config key `metalDeviceToUseThread0=` → `mlxDeviceToUseThread0=` (the direct analog of the Metal key, and the key PR #1199 documents; the backend-agnostic `deviceToUseThread0=` is an equivalent fallback if needed).

### E. UI label
- `BackendChoice.mpsGPU` raw value "MPS/GPU" → "MLX/GPU" (cosmetic; the enum case, persisted UserDefaults key behavior, and value `0` stay the same). `coremlNE` untouched. Note: changing the raw string changes the persisted value — acceptable since the app is unreleased and `platformDefault` covers unknown stored values.

### F. iOS/visionOS hardening
- Set conservative MLX memory limits on iOS/visionOS (`mx::set_memory_limit` / `set_cache_limit` / `set_wired_limit`, or the equivalent) given the prior b40c768 OOM (~5 GB peak on iOS). Tune against the smallest target device.
- Accept JIT first-call kernel-compilation latency (one-time per kernel/shape).

## Phased plan

- **Phase 0 — Spike (throwaway):** In a scratch branch/target, add `mlx-swift`, link `Cmlx`, bump C++20, and compile + run a trivial `mx::array` / `mx::eval` from a C++ TU inside the *Xcode app* on **macOS + iOS simulator**. Confirms: header visibility to C++, C++20 ripple, JIT Metal kernels run at runtime, and whether `metalbackend.swift` needs symbols from the (to-be-dropped) `metalbackend.cpp`. Discard the spike; carry the learnings.
- **Phase 1 — Source landing:** Merge `origin/mlx-backend-squash` into `ios-dev`; resolve `metalbackend` conflicts. App **still builds on `USE_METAL_BACKEND`** with no MLX dependency and no behavior change. Gate: all 3 platforms build green (visionOS may be CI/device only).
- **Phase 2 — Flip macOS:** Add `mlx-swift`, perform the target-membership swap (B), macro flip + glue (D), UI label (E). Validate the **macOS** app runs on MLX-GPU and on CoreML/NE.
- **Phase 3 — Flip iOS + visionOS:** Add memory caps (F). Validate on iOS simulator + device. visionOS validated where a runtime is available (local sim runtime is not installed here).

## Validation

- Each phase ends with a green `xcodebuild` for iOS sim + macOS (+ visionOS where runtime available).
- Functional: launch the app, run analysis, confirm visits/s on both MLX-GPU and CoreML/NE selections; confirm move play/analysis correctness on a known position.
- Optional engine-level parity: `testgpuerror` / `runtests` per the PR's own validation, if run through the desktop CMake build.

## Risks

| Risk | Mitigation |
|---|---|
| MLX C++ won't compile/run inside the Xcode app (headers, C++20, JIT kernels) | **Phase 0 spike** proves it before any real change |
| `Cmlx` is not a package product; C++ headers not propagated to consumers | Phase 0 locks the mechanism (MLX product + header search path → fork exposing `Cmlx` product → prebuilt xcframework) |
| `metalbackend.swift` references C++ symbols from the dropped `metalbackend.cpp` | Detected in spike/Phase 2; provide the needed symbols or keep a thin shim |
| C++20 bump ripples into other engine TUs | Spike compiles the full target at C++20; fix fallout there |
| iOS memory / jetsam (prior b40 OOM) | MLX memory/cache/wired caps in Phase 3; test smallest device |
| Binary size from source-compiled MLX | Accepted per linking decision; revisit with prebuilt xcframework if needed |
| visionOS not validatable locally | Defer visionOS validation to CI/device; sim runtime not installed |

## References

- PR #1199 (branch `origin/mlx-backend-squash`): the MLX backend implementation.
- `mlx-swift`: https://github.com/ml-explore/mlx-swift (Package.swift, `Cmlx` target, `tools/create-xcframework.sh`).
- Key local files: `BackendChoice.swift`, `BackendConfigSheet.swift`, `ModelRunnerView.swift`, `KataGoInterface/KataGoHelper.swift`, `KataGoInterface/KataGoCpp.cpp` (line ~94), `cpp/CMakeLists.txt` (MLX branch), `cpp/neuralnet/metalbackend.{swift,cpp,h}`.
