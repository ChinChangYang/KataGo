# Design: Persistent Core ML model cache for the macOS engine subprocess

Date: 2026-06-19
Status: Approved for planning

## Problem (verified)

On the native **KataGo Anytime Mac** app, loading a model is slow on every
launch. Root cause, verified three ways:

1. **Code.** The persistent `CoreMLModelCache` is reached only through an
   **in-process Swift closure seam**, `katago_coreml_bridge`, installed by
   `registerCoreMLBridge()`. That call exists only in the *app* targets
   (`KataGo_iOSApp.swift:42`, Mac `AppDelegate.swift:29`).
2. **Process boundary.** The macOS engine runs as a separate `katago-engine`
   subprocess whose `main.cpp` only calls `MainCmds::gtp`; it never registers
   the bridge. A different address space ⇒ `katago_coreml_bridge == nil` ⇒
   `mlxbackend.cpp` (`convertAndCreateCoreMLOnlyHandleMLX`, ~line 2238) logs
   `"CoreML bridge not registered, using direct-compile path"` and falls to
   `CoreMLConversion::convertModelToTemp` → `createCoreMLComputeHandle`
   (`metalbackend.swift:429`, `MLModel.compileModel`) on **every** launch.
3. **Disk.** The sandbox container has PID-named `.mlmodelc` regenerated under
   `Data/tmp/` every launch (`model_<PID>_<thread>_<ts>.mlmodelc`) and **no**
   `coreml/`/`index.json` cache. The Winograd tuner cache
   (`.katago/mlxwinotuning/*.txt`) *is* persistent — only Core ML is not.

Cost: per launch the engine converts **and** compiles Core ML
**4×** (2 nets × 2 ANE threads, `deviceAssignments = [0,100,100]`), redundant
across launches *and* across the two ANE threads within one launch.

This is the deferred "Task #73 — CoreML persistent-cache port into the helper."

## Goal

The `katago-engine` subprocess reuses the existing, battle-tested
`CoreMLModelCache` so a relaunch with the same model + geometry skips Core ML
conversion and compilation entirely. Reuse, don't reinvent, the cache.

## Non-goals

- No change to the iOS/visionOS in-process path (already cache-aware).
- No change to the MLX/GPU Winograd tuner cache (already persistent).
- No change to any SwiftData `@Model` (`Config`, `GameRecord`) — frozen schema.
- No new on-disk format; reuse `CoreMLModelCache`'s `index.json` + LRU layout.

## Approach

**Option B (chosen): register the persistent cache bridge inside the
subprocess**, with the cache code **extracted into a small, dependency-light
SPM module** so the headless engine does not link the UI core.

`CoreMLModelCache.shared` already resolves to
`<App Support>/<Bundle.main.bundleIdentifier>/coreml/`, which is **persistent**
and, because the subprocess's `Bundle.main` is the app bundle, lands in the
same sandbox-container namespace the app uses. The cache key already covers all
correctness-relevant inputs: source identity (content hash via `BinFileHasher`
for downloaded nets), board X/Y, precision (FP16/FP32), `optimizeIdentityMask`,
min/max batch, `katagocoreml_converter_version()`, and OS major version.

### Why extract a module

`CoreMLModelCache` lives in `KataGoUICore`, which imports SwiftUI (20 files),
SwiftData, FoundationModels, AVKit, and Charts. Linking that into a headless
engine is wrong. But the cache itself needs only Foundation/OSLog/CryptoKit, so
it separates cleanly.

## Components / changes

### 1. New SPM target `CoreMLCacheKit` (in the `KataGoUICore` package)

Move these four files (all import only Foundation/OSLog/CryptoKit) out of
`KataGoUICore` into a new `.static` target `CoreMLCacheKit`:

- `Bridge/CoreMLModelCache.swift`  (the actor; refs `printError`, `BinFileHasher`)
- `Bridge/CoreMLCacheKey.swift`    (the key/digest; refs `BinFileHasher`)
- `Services/BinFileHasher.swift`   (SHA-256 source-identity hasher)
- `Services/DebugUtils.swift`      (`printError`; package-wide — must move to
  avoid a duplicate-symbol clash, then be re-exported)

`KataGoUICore` gains `dependencies: ["CoreMLCacheKit"]` and a single
`@_exported import CoreMLCacheKit` (e.g. in a small `Exports.swift`) so **all
existing `import KataGoUICore` consumers and unit tests compile unchanged**
(`CoreMLModelCache`, `CoreMLCacheKey`, `BinFileHasher`, `printError` stay
visible through the umbrella). `CoreMLCacheReadiness*.swift` and
`EngineLaunchStatus.swift` stay in `KataGoUICore`.

### 2. Engine-side registration shim (new, compiled into the helper)

New `KataGoEngineHelper/EngineCoreMLBridge.swift`:

- `import KataGoSwift` (bridge global `katago_coreml_bridge`,
  `katagoDownloadedHasher`, `MetalComputeContext`, `CoreMLComputeHandle`,
  `createCoreMLComputeHandle`) + `import CoreMLCacheKit` (`CoreMLModelCache`,
  `BinFileHasher`).
- Implements the cache-aware loader closure: build key →
  `CoreMLModelCache.shared.urlForKey(digest:…, missCallback:)` → on miss run
  the C converter (`katagocoreml_convert_to_temp`, via `@_silgen_name`) +
  `MLModel.compileModel` → load `MLModel(computeUnits: .cpuAndNeuralEngine)` →
  `CoreMLComputeHandle(..., releaseHook:)`. This mirrors the app's
  `loadCoreMLHandle`, **minus** the `EngineLaunchStatus` UI reporting (headless
  no-op), keeping the timeout/fallback and one-shot corrupt-hit retry.
- `@_cdecl("katago_register_coreml_bridge")` sets `katago_coreml_bridge` to the
  closure and wires `katagoDownloadedHasher =
  BinFileHasher.shared.identityForDownloadedFile`. Idempotent.

### 3. Helper target wiring (`project.pbxproj`)

- Frameworks: add **KataGoSwift.framework** (link, *Do Not Embed* — already
  embedded by the app) and the **CoreMLCacheKit** package product.
- Sources: add `EngineCoreMLBridge.swift`.
- Build settings: enable Swift + Swift/C++ interop on the helper, matching the
  app target (`SWIFT_VERSION`, `-cxx-interoperability-mode=default`), so it can
  compile Swift and import `KataGoSwift`.
- Preserve the helper's sandbox + inherit entitlements and the existing
  no-`CodeSignOnCopy` embed rule.

### 4. `KataGoEngineHelper/main.cpp`

Declare `extern "C" void katago_register_coreml_bridge();` and call it once
**before** `MainCmds::gtp(args)`.

## Data flow (after)

subprocess start → `katago_register_coreml_bridge()` sets the seam →
`MainCmds::gtp` → `NNEvaluator` spawns ANE server threads →
`createComputeHandle` → `mlxbackend.cpp invokeCoreMLBridge()` is now **non-nil**
→ `CoreMLModelCache.urlForKey(digest)`: **hit** ⇒ load `.mlmodelc` from
`App Support/<bundle>/coreml/`; **miss** ⇒ convert+compile, commit to cache,
load. ANE thread 2 (same digest) hits thread 1's entry.

## Error handling

- Registration is idempotent and safe at startup.
- Unwritable App Support ⇒ `CoreMLModelCache` degrades to `temporaryDirectory`
  (existing behavior); engine still boots.
- Bridge hang/throw ⇒ existing `loadCoreMLHandleWithBridgeTimeout` falls
  through to the legacy direct-compile path → no worse than today.
- Corrupt cached `.mlmodelc` ⇒ existing one-shot invalidate + recompile retry.

## Risks / mitigations

- **Codesign.** Helper now compiles Swift + links KataGoSwift/CoreMLCacheKit;
  `codesign --verify --deep --strict` on the app must still pass and the helper
  must retain `app-sandbox` + `inherit`. Link KataGoSwift *Do Not Embed*;
  verify after build.
- **Extraction regressions.** `@_exported import` must keep every existing
  `import KataGoUICore` site (app + tests) compiling. Verify with full builds +
  the existing `CoreMLModelCacheTests` / `BinFileHasherTests`.
- **Module init.** No eager top-level UI init is pulled in (the four files are
  Foundation/OSLog/CryptoKit only).
- **Sandbox path.** `Bundle.main` = app in the subprocess ⇒ correct, persistent
  `coreml/` namespace (gotcha #4 from the subprocess-migration notes).

## Verification plan (thorough)

1. **Builds green:** iOS Simulator, macOS (`KataGo Anytime Mac` scheme),
   visionOS Simulator.
2. **Unit tests:** existing `CoreMLModelCacheTests` + `BinFileHasherTests` (now
   via re-export), `KataGoEngineIPC` swift-tests, full iOS unit suite — no
   regression.
3. **Cold/warm functional measurement** (headless helper per the
   subprocess-migration run procedure, or the real app):
   - Launch 1 (cold cache): converts+compiles; `App Support/<bundle>/coreml/`
     gains `index.json` + `models/<digest>/<epoch>.mlmodelc`; stderr shows the
     cache-aware path (no `"bridge not registered"` line).
   - Launch 2 (warm): cache **hit**, no recompile, **no** new PID-named
     `tmp/*.mlmodelc`; model-load wall time (spawn→first `"= "` GTP response)
     markedly lower. Record both numbers.
4. **Correctness:** live analysis returns sane winrates/ownership (ANE path
   works from the cached model).
5. **Codesign:** `codesign --verify --deep --strict` passes; entitlements
   intact; no orphaned child on quit (unchanged).
6. **Adversarial diff review** before completion.

## Out of scope / future

- Sharing a pre-warm between app and subprocess (the app doesn't load models on
  Mac today).
- Cache size/UX surfacing in settings.
