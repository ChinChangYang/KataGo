# macOS Engine Core ML Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the macOS `katago-engine` subprocess reuse the persistent `CoreMLModelCache` so relaunching with the same model skips Core ML conversion + compilation.

**Architecture:** Extract the dependency-light cache types into a new static SPM target `CoreMLCacheKit` (so a headless engine can link it without the UI core), then have the helper register the `katago_coreml_bridge` seam at startup via a small `@_cdecl` shim called from `main.cpp`.

**Tech Stack:** Swift 6.2 + Swift/C++ interop, SwiftPM (`KataGoUICore` package), Xcode `project.pbxproj` edited via the `xcodeproj` Ruby gem, Core ML, the MLX backend (`USE_MLX_BACKEND`).

## Global Constraints

- Platforms / floors: iOS 26, macOS 26, visionOS 26 (`platforms:` in `Package.swift`).
- The app is unreleased — **no** migration/back-compat code.
- **Never** modify SwiftData `@Model` types (`Config`, `GameRecord`).
- Build the Mac app with scheme **`KataGo Anytime Mac`** (NOT `KataGo Anytime`).
- Register new Xcode files/links via the `xcodeproj` Ruby gem (no synchronized groups).
- Prefer the `trash` CLI over `rm` for deletions.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Do not `git push` as part of this plan (Xcode Cloud rate) — commits only.
- New module is `.static`; the `@_silgen_name("katagocoreml_converter_version")` symbol resolves at the consumer's link against `katago.framework` (same deferred-link pattern KataGoUICore already uses).

---

### Task 1: Extract `CoreMLCacheKit` SPM module

Move the three dependency-light cache files into a new static target and re-export them so every existing `import KataGoUICore` site keeps compiling. The existing cache unit tests are the regression guard.

**Files:**
- Create dir: `ios/KataGo iOS/KataGoUICore/Sources/CoreMLCacheKit/`
- Move (git mv): `…/Sources/KataGoUICore/Bridge/CoreMLModelCache.swift` → `…/Sources/CoreMLCacheKit/CoreMLModelCache.swift`
- Move (git mv): `…/Sources/KataGoUICore/Bridge/CoreMLCacheKey.swift` → `…/Sources/CoreMLCacheKit/CoreMLCacheKey.swift`
- Move (git mv): `…/Sources/KataGoUICore/Services/BinFileHasher.swift` → `…/Sources/CoreMLCacheKit/BinFileHasher.swift`
- Create: `…/Sources/CoreMLCacheKit/Logging.swift` (internal `printError`)
- Create: `…/Sources/KataGoUICore/Exports.swift` (`@_exported import CoreMLCacheKit`)
- Modify: `ios/KataGo iOS/KataGoUICore/Package.swift` (add product + target + dependency)
- Modify: `…/Sources/KataGoUICore/Services/CoreMLCacheReadiness.swift` (add `import CoreMLCacheKit`)
- Modify: `…/Sources/KataGoUICore/Services/CoreMLCacheReadinessProjection.swift` (add `import CoreMLCacheKit`)
- Modify tests (add `@testable import CoreMLCacheKit`): `KataGo iOSTests/CoreMLModelCacheTests.swift`, `CoreMLCacheKeyTests.swift`, `BinFileHasherTests.swift`, `CoreMLCacheReadinessProjectionTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a `CoreMLCacheKit` SwiftPM **product** (static lib) exporting the public API `CoreMLModelCache` (actor; `.shared`, `start()`, `urlForKey(digest:priority:sourceFileName:missCallback:) -> PinnedCacheURL`, `invalidate(digest:epoch:)`, `cacheKey(forSourcePath:nnXLen:nnYLen:requireExactNNLen:useFP16:maxBatchSize:downloadedHasher:)`), `PinnedCacheURL` (`.url/.digest/.epoch`, `release() async`), `CoreMLCacheKey`, `CoreMLCacheKeyError`, `BinFileHasher` (`.shared`, `identityForDownloadedFile(_ url: URL) async throws -> String`). All remain visible through `import KataGoUICore` via `@_exported import`.

- [ ] **Step 1: Move the three files with git mv and create the module dir**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGoUICore/Sources"
mkdir -p CoreMLCacheKit
git mv KataGoUICore/Bridge/CoreMLModelCache.swift CoreMLCacheKit/CoreMLModelCache.swift
git mv KataGoUICore/Bridge/CoreMLCacheKey.swift   CoreMLCacheKit/CoreMLCacheKey.swift
git mv KataGoUICore/Services/BinFileHasher.swift  CoreMLCacheKit/BinFileHasher.swift
```

- [ ] **Step 2: Add an internal `printError` to the new module**

`CoreMLModelCache.swift` calls `printError` (lines ~7 comment, ~491). `printError` lives in `KataGoUICore/Services/DebugUtils.swift` which stays in KataGoUICore. To avoid a cross-module/circular dep, give CoreMLCacheKit its own **internal** copy (internal ⇒ not re-exported ⇒ no ambiguity with KataGoUICore's public `printError`). Create `…/Sources/CoreMLCacheKit/Logging.swift`:

```swift
import Foundation

// Internal stderr writer for CoreMLCacheKit. Mirrors KataGoUICore's
// DebugUtils.printError but stays `internal` so it is not re-exported and
// cannot collide with KataGoUICore's public `printError` in consumers that
// import both modules.
func printError(_ item: Any) {
    FileHandle.standardError.write(Data("\(item)\n".utf8))
}
```

- [ ] **Step 3: Add the `@_exported` umbrella so consumers are unchanged**

Create `…/Sources/KataGoUICore/Exports.swift`:

```swift
// Re-export the extracted Core ML cache module so every existing
// `import KataGoUICore` site keeps seeing CoreMLModelCache, CoreMLCacheKey,
// CoreMLCacheKeyError, PinnedCacheURL, and BinFileHasher without edits.
@_exported import CoreMLCacheKit
```

- [ ] **Step 4: Update `Package.swift` — new product, target, and dependency**

In `ios/KataGo iOS/KataGoUICore/Package.swift`:

Add to `products:` (alongside the existing `KataGoUICore` library):

```swift
        .library(name: "CoreMLCacheKit", type: .static, targets: ["CoreMLCacheKit"]),
```

Add to `targets:` (a pure-Swift target, no CKataGoBridge dep, no Cxx interop):

```swift
        .target(
            name: "CoreMLCacheKit"
        ),
```

Add `"CoreMLCacheKit"` to the `KataGoUICore` target's `dependencies:` array:

```swift
            dependencies: ["CKataGoBridge", "CoreMLCacheKit"],
```

- [ ] **Step 5: Add `import CoreMLCacheKit` to the two internal users**

The `@_exported` umbrella covers external consumers, but files **inside** KataGoUICore that reference the moved types still need an explicit import. Add `import CoreMLCacheKit` (after the existing `import Foundation`) to:
- `…/Sources/KataGoUICore/Services/CoreMLCacheReadiness.swift`
- `…/Sources/KataGoUICore/Services/CoreMLCacheReadinessProjection.swift`

- [ ] **Step 6: Add `@testable import CoreMLCacheKit` to the cache tests**

The four cache tests use `@testable import KataGoUICore` to reach internals (`acquireForTests`, `runStartupSweepForTests`) that now live in CoreMLCacheKit. Add a line `@testable import CoreMLCacheKit` next to the existing `@testable import KataGoUICore` in:
- `KataGo iOSTests/CoreMLModelCacheTests.swift`
- `KataGo iOSTests/CoreMLCacheKeyTests.swift`
- `KataGo iOSTests/BinFileHasherTests.swift`
- `KataGo iOSTests/CoreMLCacheReadinessProjectionTests.swift`

- [ ] **Step 7: Build the iOS app to verify the extraction compiles**

Run:
```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. If a file fails with "cannot find type 'CoreMLModelCache'/'BinFileHasher' in scope", add `import CoreMLCacheKit` to that file.

- [ ] **Step 8: Run the cache unit tests (regression guard)**

Run:
```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeTests/CoreMLModelCacheTests" -only-testing:"KataGo AnytimeTests/CoreMLCacheKeyTests" -only-testing:"KataGo AnytimeTests/BinFileHasherTests" -only-testing:"KataGo AnytimeTests/CoreMLCacheReadinessProjectionTests" 2>&1 | tail -25
```
Expected: `** TEST SUCCEEDED **` (all four suites pass — behavior is unchanged by the move).

- [ ] **Step 9: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add -A
git commit -m "$(cat <<'EOF'
refactor(mac): extract CoreMLCacheKit from KataGoUICore

Move CoreMLModelCache, CoreMLCacheKey, BinFileHasher into a new dependency-light
static SPM target (Foundation/OSLog/CryptoKit only) so the headless engine can
link the cache without the UI core. KataGoUICore re-exports it, so all existing
import sites and tests compile unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Register the cache bridge inside the `katago-engine` subprocess

Add a Swift shim that installs the cache-aware `katago_coreml_bridge` closure, wire the helper target to compile Swift and link `KataGoSwift` + `CoreMLCacheKit`, and call the registration from `main.cpp` before `MainCmds::gtp`.

**Files:**
- Create: `ios/KataGo iOS/KataGoEngineHelper/EngineCoreMLBridge.swift`
- Modify: `ios/KataGo iOS/KataGoEngineHelper/main.cpp` (call registration)
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (via gem script)

**Interfaces:**
- Consumes: `CoreMLCacheKit` (Task 1) — `CoreMLModelCache`, `BinFileHasher`; `KataGoSwift` — `katago_coreml_bridge`, `katagoDownloadedHasher`, `MetalComputeContext(nnXLen:nnYLen:useFP16:)`, `CoreMLComputeHandle(...)`, `createCoreMLComputeHandle(...)`.
- Produces: an exported C symbol `void katago_register_coreml_bridge(void)`.

- [ ] **Step 1: Write the registration shim**

Create `ios/KataGo iOS/KataGoEngineHelper/EngineCoreMLBridge.swift`. This is the headless counterpart of the app's `CoreMLComputeHandleLoader.swift` — same cache-aware load + timeout/fallback + corrupt-hit retry, but with **no** `EngineLaunchStatus` UI reporting (the subprocess has no UI). It registers the bridge and the downloaded-file hasher via a single `@_cdecl` entry point that `main.cpp` calls.

```swift
import CoreML
import CoreMLCacheKit
import Foundation
import KataGoSwift

// C bridge into katago.framework (mlxbackend.cpp / metalbackend.cpp).
@_silgen_name("katagocoreml_convert_to_temp")
private func katagocoreml_convert_to_temp(
    _ modelPath: UnsafePointer<CChar>,
    _ boardX: Int32, _ boardY: Int32,
    _ useFP16: Bool, _ optimizeMask: Bool,
    _ maxBatchSize: Int32, _ serverThreadIdx: Int32
) -> UnsafePointer<CChar>?

@_silgen_name("katagocoreml_free_string")
private func katagocoreml_free_string(_ s: UnsafePointer<CChar>?)

/// Cache-aware compute-handle loader for the headless engine subprocess.
/// Mirrors the app target's `loadCoreMLHandle`, minus the LoadingView status
/// reporting. One-shot corrupt-hit retry around `MLModel(contentsOf:)`.
private func loadCoreMLHandle(
    coremlModelPath: String,
    serverThreadIdx: Int,
    requireExactNNLen: Bool,
    numInputChannels: Int32,
    numInputGlobalChannels: Int32,
    numInputMetaChannels: Int32,
    numPolicyChannels: Int32,
    numValueChannels: Int32,
    numScoreValueChannels: Int32,
    numOwnershipChannels: Int32,
    context: MetalComputeContext,
    maxBatchSize: Int
) async throws -> CoreMLComputeHandle? {
    let useFP16 = context.useFP16
    let optimizeMask = requireExactNNLen
    let nnXLen = context.nnXLen
    let nnYLen = context.nnYLen
    let key = try await CoreMLModelCache.cacheKey(
        forSourcePath: coremlModelPath,
        nnXLen: nnXLen, nnYLen: nnYLen,
        requireExactNNLen: optimizeMask, useFP16: useFP16,
        maxBatchSize: maxBatchSize,
        downloadedHasher: { url in
            try await BinFileHasher.shared.identityForDownloadedFile(url)
        })
    let cache = CoreMLModelCache.shared
    await cache.start()

    let sourceFileName = (coremlModelPath as NSString).lastPathComponent
    for attempt in 0..<2 {
        let pinned = try await cache.urlForKey(
            digest: key.digest,
            priority: .userInitiated,
            sourceFileName: sourceFileName,
            missCallback: {
                return try await convertOnCooperativePool(
                    coremlModelPath: coremlModelPath,
                    boardX: nnXLen, boardY: nnYLen,
                    useFP16: useFP16, optimizeMask: optimizeMask,
                    maxBatchSize: Int32(maxBatchSize),
                    serverThreadIdx: Int32(serverThreadIdx))
            })
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: pinned.url, configuration: config)
            return CoreMLComputeHandle(
                model: model,
                nnXLen: context.nnXLen,
                nnYLen: context.nnYLen,
                optimizeIdentityMask: optimizeMask,
                numInputChannels: Int(numInputChannels),
                numInputGlobalChannels: Int(numInputGlobalChannels),
                numInputMetaChannels: Int(numInputMetaChannels),
                numPolicyChannels: Int(numPolicyChannels),
                numValueChannels: Int(numValueChannels),
                numScoreValueChannels: Int(numScoreValueChannels),
                numOwnershipChannels: Int(numOwnershipChannels),
                releaseHook: { await pinned.release() })
        } catch {
            await pinned.release()
            await cache.invalidate(digest: pinned.digest, epoch: pinned.epoch)
            if attempt == 1 { throw error }
        }
    }
    fatalError("unreachable: for-loop bound is fixed at 2")
}

/// Run the C++ converter on the cooperative pool, then compile to `.mlmodelc/`
/// so the cache can store the compiled artifact (matches the app loader).
private func convertOnCooperativePool(
    coremlModelPath: String,
    boardX: Int32, boardY: Int32,
    useFP16: Bool, optimizeMask: Bool,
    maxBatchSize: Int32, serverThreadIdx: Int32
) async throws -> URL {
    let mlpackageURL = try await Task.detached(priority: .userInitiated) { () throws -> URL in
        let url = coremlModelPath.withCString { cstr -> URL? in
            guard let outCstr = katagocoreml_convert_to_temp(
                cstr, boardX, boardY, useFP16, optimizeMask,
                maxBatchSize, serverThreadIdx) else { return nil }
            defer { katagocoreml_free_string(outCstr) }
            return URL(fileURLWithPath: String(cString: outCstr))
        }
        guard let url else {
            throw NSError(domain: "katagocoreml", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "conversion failed"])
        }
        return url
    }.value
    return try await MLModel.compileModel(at: mlpackageURL)
}

// Thread-safe result box (writes happen-before signal; reads happen-after wait).
private final class ResultBox: @unchecked Sendable {
    nonisolated(unsafe) var value: Result<CoreMLComputeHandle?, Error>? = nil
}

/// Synchronous bridge wrapper driven by `mlxbackend.cpp`. 600s primary + 60s
/// secondary wait, then cancels and falls back to the legacy direct-compile.
private func loadCoreMLHandleWithBridgeTimeout(
    coremlModelPath: String,
    serverThreadIdx: Int,
    requireExactNNLen: Bool,
    numInputChannels: Int32,
    numInputGlobalChannels: Int32,
    numInputMetaChannels: Int32,
    numPolicyChannels: Int32,
    numValueChannels: Int32,
    numScoreValueChannels: Int32,
    numOwnershipChannels: Int32,
    context: MetalComputeContext,
    maxBatchSize: Int
) -> CoreMLComputeHandle? {
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox()
    let nnXLen = context.nnXLen
    let nnYLen = context.nnYLen
    let useFP16 = context.useFP16

    let task = Task.detached(priority: .userInitiated) {
        do {
            box.value = .success(try await loadCoreMLHandle(
                coremlModelPath: coremlModelPath,
                serverThreadIdx: serverThreadIdx,
                requireExactNNLen: requireExactNNLen,
                numInputChannels: numInputChannels,
                numInputGlobalChannels: numInputGlobalChannels,
                numInputMetaChannels: numInputMetaChannels,
                numPolicyChannels: numPolicyChannels,
                numValueChannels: numValueChannels,
                numScoreValueChannels: numScoreValueChannels,
                numOwnershipChannels: numOwnershipChannels,
                context: MetalComputeContext(nnXLen: nnXLen, nnYLen: nnYLen, useFP16: useFP16),
                maxBatchSize: maxBatchSize))
        } catch {
            box.value = .failure(error)
        }
        sem.signal()
    }

    if sem.wait(timeout: .now() + .seconds(600)) == .timedOut {
        let secondary = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) { await task.value; secondary.signal() }
        if secondary.wait(timeout: .now() + .seconds(60)) == .timedOut {
            task.cancel()
            return createCoreMLComputeHandle(
                coremlModelPath: coremlModelPath,
                serverThreadIdx: serverThreadIdx,
                requireExactNNLen: requireExactNNLen,
                numInputChannels: numInputChannels,
                numInputGlobalChannels: numInputGlobalChannels,
                numInputMetaChannels: numInputMetaChannels,
                numPolicyChannels: numPolicyChannels,
                numValueChannels: numValueChannels,
                numScoreValueChannels: numScoreValueChannels,
                numOwnershipChannels: numOwnershipChannels,
                context: context)
        }
    }

    switch box.value {
    case .success(let h)?: return h
    case .failure?: return nil
    case nil: return nil
    }
}

/// C entry point called once from `main.cpp` before `MainCmds::gtp`. Installs
/// the cache-aware bridge + downloaded-file hasher into the KataGoSwift seams.
@_cdecl("katago_register_coreml_bridge")
public func katago_register_coreml_bridge() {
    katagoDownloadedHasher = { url in
        try await BinFileHasher.shared.identityForDownloadedFile(url)
    }
    katago_coreml_bridge = { (
        coremlModelPath, serverThreadIdx, requireExactNNLen,
        numInputChannels, numInputGlobalChannels, numInputMetaChannels,
        numPolicyChannels, numValueChannels, numScoreValueChannels, numOwnershipChannels,
        context, maxBatchSize
    ) in
        return loadCoreMLHandleWithBridgeTimeout(
            coremlModelPath: coremlModelPath,
            serverThreadIdx: serverThreadIdx,
            requireExactNNLen: requireExactNNLen,
            numInputChannels: numInputChannels,
            numInputGlobalChannels: numInputGlobalChannels,
            numInputMetaChannels: numInputMetaChannels,
            numPolicyChannels: numPolicyChannels,
            numValueChannels: numValueChannels,
            numScoreValueChannels: numScoreValueChannels,
            numOwnershipChannels: numOwnershipChannels,
            context: context,
            maxBatchSize: maxBatchSize)
    }
}
```

- [ ] **Step 2: Call the registration from `main.cpp`**

Edit `ios/KataGo iOS/KataGoEngineHelper/main.cpp` — add the extern decl above `main` and call it first:

```cpp
namespace MainCmds {
int gtp(const std::vector<std::string>& args);
}

// Installs the persistent Core ML cache bridge (EngineCoreMLBridge.swift) so the
// MLX backend's ANE path reuses the on-disk cache instead of recompiling every
// launch. Must run before MainCmds::gtp creates any compute handle.
extern "C" void katago_register_coreml_bridge(void);

int main(int argc, const char* const* argv) {
  katago_register_coreml_bridge();
  std::vector<std::string> args;
  args.reserve(argc > 1 ? static_cast<size_t>(argc - 1) : 0);
  for (int i = 1; i < argc; ++i) {
    args.emplace_back(argv[i]);
  }
  return MainCmds::gtp(args);
}
```

- [ ] **Step 3: Inspect the app target's Swift/C++ interop build settings (to mirror onto the helper)**

Run:
```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild -showBuildSettings -project "KataGo Anytime.xcodeproj" -target "KataGo Anytime Mac" -configuration Debug 2>/dev/null | grep -iE "SWIFT_VERSION|SWIFT_OBJC_INTEROP|CXX_INTEROP|OTHER_SWIFT_FLAGS|SWIFT_OPTIMIZATION_LEVEL|cxx-interop"
```
Note the exact `SWIFT_VERSION` and the C++-interop key (`SWIFT_OBJC_INTEROP_MODE`/`SWIFT_CXX_INTEROPABILITY_MODE`, or `-cxx-interoperability-mode=default` inside `OTHER_SWIFT_FLAGS`). Use these exact values in Step 4.

- [ ] **Step 4: Wire the helper target via the `xcodeproj` gem**

Create and run `/tmp/wire_helper_cache.rb` (fill `INTEROP_SETTINGS` from Step 3):

```ruby
require 'xcodeproj'
path = "ios/KataGo iOS/KataGo Anytime.xcodeproj"
proj = Xcodeproj::Project.open(path)
helper = proj.targets.find { |t| t.name == "KataGo Engine Helper" }
raise "helper not found" unless helper

# 1) Add EngineCoreMLBridge.swift to the helper's Sources phase.
group = proj.objects_by_uuid["0E62DBC58E2CD16A457DF483"] # KataGoEngineHelper group
swift_ref = group.files.find { |f| f.path == "KataGoEngineHelper/EngineCoreMLBridge.swift" }
swift_ref ||= group.new_reference("KataGoEngineHelper/EngineCoreMLBridge.swift")
helper.source_build_phase.add_file_reference(swift_ref) unless
  helper.source_build_phase.files_references.include?(swift_ref)

# 2) Link KataGoSwift.framework (already embedded by the app → Do Not Embed).
kgs = proj.objects_by_uuid["E11887E12B0830C900637D44"] # KataGoSwift.framework fileRef
unless helper.frameworks_build_phase.files_references.include?(kgs)
  helper.frameworks_build_phase.add_file_reference(kgs)
end

# 3) Link the CoreMLCacheKit package product from the local KataGoUICore package.
pkg = proj.root_object.package_references.find { |r|
  r.respond_to?(:path) && r.path.to_s.include?("KataGoUICore") }
raise "KataGoUICore package ref not found" unless pkg
unless helper.package_product_dependencies.any? { |d| d.product_name == "CoreMLCacheKit" }
  dep = proj.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = "CoreMLCacheKit"
  dep.package = pkg
  helper.package_product_dependencies << dep
  bf = proj.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  helper.frameworks_build_phase.files << bf
end

# 4) Enable Swift compilation + C++ interop on both helper configs.
INTEROP_SETTINGS = {
  "SWIFT_VERSION" => "6.0",                       # <-- replace with Step 3 value
  "SWIFT_OBJC_INTEROP_MODE" => "objcxx",          # <-- replace with Step 3 key/value
  "SWIFT_OPTIMIZATION_LEVEL" => "-Onone",         # debug; release config keeps its own
  "CLANG_ENABLE_MODULES" => "YES",
}
helper.build_configurations.each do |cfg|
  INTEROP_SETTINGS.each { |k, v| cfg.build_settings[k] = v unless k == "SWIFT_OPTIMIZATION_LEVEL" && cfg.name == "Release" }
end

proj.save
puts "Wired helper target: sources, KataGoSwift link, CoreMLCacheKit product, Swift settings."
```

Run:
```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
gem list -i xcodeproj >/dev/null 2>&1 || sudo gem install xcodeproj
ruby /tmp/wire_helper_cache.rb
```
Expected: the "Wired helper target…" line, no Ruby error.

- [ ] **Step 5: Build the macOS app (helper compiles Swift + links the cache)**

Run:
```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -25
```
Expected: `** BUILD SUCCEEDED **`. If `import KataGoSwift` fails to resolve, confirm `FRAMEWORK_SEARCH_PATHS` on the helper includes `$(BUILT_PRODUCTS_DIR)` (it already finds katago.framework). If the C++ interop setting name was wrong, fix per Step 3 and re-run Step 4 + this step.

- [ ] **Step 6: Verify the helper symbol + codesign integrity**

Run:
```bash
APP=$(ls -dt "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/DerivedData/KataGo Anytime/Build/Products/Debug/KataGo Anytime Mac.app" 2>/dev/null | head -1)
echo "APP=$APP"
nm -gU "$APP/Contents/MacOS/katago-engine" 2>/dev/null | grep -i katago_register_coreml_bridge
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -5
codesign -d --entitlements - "$APP/Contents/MacOS/katago-engine" 2>/dev/null | grep -iE "app-sandbox|inherit"
```
Expected: the `katago_register_coreml_bridge` symbol is present; codesign reports `valid on disk` / `satisfies its Designated Requirement`; the helper still has `app-sandbox` + `inherit` entitlements.

- [ ] **Step 7: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add -A
git commit -m "$(cat <<'EOF'
feat(mac): register persistent Core ML cache in the engine subprocess

The katago-engine helper now installs the katago_coreml_bridge seam at startup
(EngineCoreMLBridge.swift, @_cdecl, called from main.cpp before MainCmds::gtp),
so the MLX backend's ANE path reuses the on-disk CoreMLModelCache instead of
re-converting + recompiling Core ML to /tmp on every launch. Helper now links
KataGoSwift + CoreMLCacheKit and compiles Swift with C++ interop.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: End-to-end verification — cold vs warm load, cache hit, correctness

Prove the fix: launch 1 populates the persistent cache; launch 2 hits it with no recompile and a markedly lower model-load time; analysis still correct.

**Files:** none (verification only).

**Interfaces:** Consumes the built `KataGo Anytime Mac.app` from Task 2.

- [ ] **Step 1: Snapshot the pre-state of the cache + tmp**

```bash
C=~/Library/Containers/chinchangyang.KataGo-iOS.tw.mac/Data
ls -d "$C"/tmp/*.mlmodelc 2>/dev/null | wc -l   # current throwaway count
find "$C/Library/Application Support" -ipath '*coreml*' 2>/dev/null | head   # expect EMPTY pre-fix
```

- [ ] **Step 2: Cold launch — run the helper headless from inside the app bundle**

The bundled helper has `app-sandbox`+`inherit`, so a direct shell launch is SIGTRAP'd (exit 133). Re-sign a **copy** without sandbox to run headless (restore/rebuild after), per the subprocess-migration procedure. Drive a minimal GTP session and time spawn→first response. Create `/tmp/coreml_cache_probe.sh`:

```bash
#!/bin/bash
set -e
APP="$1"   # path to KataGo Anytime Mac.app
MODEL="$APP/Contents/Resources/default_model.bin.gz"
HUMAN="$APP/Contents/Resources/b18c384nbt-humanv0.bin.gz"
CFG="$APP/Contents/Resources/default_gtp.cfg"
WORK=$(mktemp -d)
cp "$APP/Contents/MacOS/katago-engine" "$WORK/katago-engine"
# Re-sign the copy WITHOUT sandbox so it runs headless; keep hardened runtime
# so framework library-validation still passes (same identity as the app).
ID=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
codesign --force --options runtime --sign "Apple Development" "$WORK/katago-engine" 2>/dev/null || \
  codesign --force --options runtime -s - "$WORK/katago-engine"
printf 'version\nquit\n' > "$WORK/in.gtp"
echo "=== timing model load (spawn -> first response) ==="
/usr/bin/time -p "$WORK/katago-engine" gtp \
  -model "$MODEL" -human-model "$HUMAN" -config "$CFG" \
  -override-config "numNNServerThreadsPerModel=3,mlxDeviceToUseThread0=0,mlxDeviceToUseThread1=100,mlxDeviceToUseThread2=100,logToStderr=true" \
  < "$WORK/in.gtp" 2> "$WORK/err.log" | head
echo "=== bridge path (expect NO 'bridge not registered') ==="
grep -i "bridge not registered\|direct-compile\|Compiling model\|Loading compiled" "$WORK/err.log" | head
echo "WORK=$WORK"
```

Run it (cold = first time for this model/geometry):
```bash
chmod +x /tmp/coreml_cache_probe.sh
APP=$(ls -dt "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/DerivedData/KataGo Anytime/Build/Products/Debug/KataGo Anytime Mac.app" | head -1)
/tmp/coreml_cache_probe.sh "$APP"
```
Expected (cold): `real` time on the order of several seconds; **no** `"CoreML bridge not registered"` line; the cache dir is created.

- [ ] **Step 3: Confirm the cache was populated**

```bash
C=~/Library/Containers/chinchangyang.KataGo-iOS.tw.mac/Data
find "$C/Library/Application Support" -ipath '*coreml*' \( -name index.json -o -name '*.mlmodelc' \) 2>/dev/null | head
```
Expected: `…/<bundle>/coreml/index.json` and at least one `models/<digest>/<epoch>.mlmodelc` now exist.

- [ ] **Step 4: Warm launch — run the probe again, compare**

```bash
/tmp/coreml_cache_probe.sh "$APP"
```
Expected (warm): `real` time **markedly lower** than cold (conversion + compilation skipped); `err.log` shows **no** `"Compiling model"` for the cached entries; **no** new PID-named `.mlmodelc` appear under `Data/tmp/` for this run:
```bash
C=~/Library/Containers/chinchangyang.KataGo-iOS.tw.mac/Data
ls -lt "$C"/tmp/*.mlmodelc 2>/dev/null | head   # newest should predate the warm run
```
Record both `real` numbers in this plan's results note.

- [ ] **Step 5: Correctness — live analysis in the real app**

Launch the real (sandboxed) app, set the default model active, and confirm the board renders live analysis (winrates/score/candidate overlays) — i.e. the ANE path works from the cached model. (Drive via keyboard hotkeys: `Space` toggles analysis. Computer-use clicks on the Metal board get a phantom Notification-Center hit-test block — use keys.)
```bash
open "$APP"
```
Expected: analysis updates within a couple seconds; no crash; engine + app processes healthy.

- [ ] **Step 6: Full regression builds + tests**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -3
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | tail -3
xcodebuild test  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8
swift test --package-path "KataGoEngineIPC" 2>&1 | tail -8
```
Expected: both extra builds `** BUILD SUCCEEDED **`; iOS unit suite + KataGoEngineIPC tests pass.

- [ ] **Step 7: Adversarial diff review**

Review the full branch diff (`git diff master...HEAD`) for: leftover throwaway-tmp writes on the warm path, cache-key correctness (does a board-size/precision change invalidate?), codesign/entitlement regressions, and any `@_exported`-induced symbol ambiguity. Fix findings; re-run the affected verification step.

- [ ] **Step 8: Record results + final commit (if any review fixes)**

Append the measured cold/warm numbers to this plan, then commit any review fixes:
```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git add -A && git commit -m "$(cat <<'EOF'
test(mac): verify persistent Core ML cache (cold vs warm) + review fixes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

- **Spec coverage:** §Components 1 (extract module) → Task 1; §Components 2–4 (shim, helper wiring, main.cpp) → Task 2; §Verification plan → Task 3 (builds, unit tests, cold/warm, correctness, codesign, adversarial review). All covered.
- **Placeholders:** The only intentional fill-ins are `INTEROP_SETTINGS` values, which Step 3 discovers with an exact command before Step 4 uses them — not a vague instruction.
- **Type consistency:** `katago_register_coreml_bridge` (C symbol) matches between EngineCoreMLBridge.swift `@_cdecl`, main.cpp `extern "C"`, and the Step 6 `nm` check. `CoreMLModelCache`/`PinnedCacheURL`/`BinFileHasher` APIs match Task 1's Produces block and the existing app loader. `CoreMLCacheKit` product name matches Package.swift, the gem script, and the test imports.
