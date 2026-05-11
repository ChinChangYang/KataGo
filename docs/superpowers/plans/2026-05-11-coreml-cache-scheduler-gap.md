# Core ML Cache / Precompile Scheduler — Unifying Truth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `CoreMLModelCache` the single source of truth for "is this model cache-ready," so the `ModelPickerView` row checkmark and the `CoreMLCacheFooterView` "N of M" count never disagree, and the placeholder precompile worker stops emitting false-positive `.ready` states.

**Architecture:** Approach A from the spec. `CoreMLModelCache` (in `KataGoInterface`) gains three new APIs — `hasEntry(digest:)`, `indexEvents`, `projectedDigest(...)`, `warm(...)` — and stays the on-disk truth. `PrecompileScheduler` (in the app) splits its in-memory state into `ephemeral` (queued/compiling/failed) and `cachedReady` (projection of the cache index). The `status[fileName]` view becomes computed. `runPrecompileWorker` stops sleeping and calls `cache.warm(...)` for real. App init hydrates `cachedReady` once and subscribes to `indexEvents`.

**Tech Stack:** Swift, SwiftUI, `@Observable`, `actor`, `AsyncStream`, Swift Testing (`@Test`), XCUITest, KataGo C++/Swift bridge.

**Spec:** `docs/superpowers/specs/2026-05-11-coreml-cache-scheduler-gap-design.md`

---

## Conventions for every task below

- Build/test on the iOS Simulator iPhone 17 destination per `CLAUDE.md`.
- Unit tests use Swift Testing (`@Test`), not XCTest. Filter the whole suite when running, not individual tests (Swift Testing filter syntax differs from XCTest's `-only-testing:`).
- Run unit tests with:
  ```
  xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'
  ```
- Build all three platforms (iOS, macOS, visionOS) before each commit on a Swift-only change. Build commands are in `CLAUDE.md`.
- Commit messages use the project's conventional prefixes (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`). Include `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- Never use `git commit --amend`; create new commits.
- Use `git -C "/Users/chinchangyang/Code/KataGo-ios-dev" ...` rather than `cd ... && git ...`.

---

## Task 1: Add `hasEntry(digest:)` to `CoreMLModelCache`

Cheap index-only lookup. Foundation for both the scheduler's projection check and future tests.

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift` (add method in an existing extension block, near `lookupOnDisk`)
- Test: `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`

- [ ] **Step 1: Write the failing test**

Append at the end of the `struct CoreMLModelCacheTests`:

```swift
@Test func hasEntryReturnsFalseForUnknownDigest() async throws {
    let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
    await cache.ensureCacheTreeExistsForTests()
    #expect(await cache.hasEntry(digest: "unknown") == false)
}

@Test func hasEntryReturnsTrueAfterInstall() async throws {
    let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
    await cache.ensureCacheTreeExistsForTests()

    let pinned = try await cache.urlForKey(digest: "abc123", missCallback: {
        let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
        return u
    })
    await pinned.release()

    #expect(await cache.hasEntry(digest: "abc123") == true)
    #expect(await cache.hasEntry(digest: "missing") == false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: compile error — `Value of type 'CoreMLModelCache' has no member 'hasEntry'`.

- [ ] **Step 3: Implement `hasEntry`**

In `CoreMLModelCache.swift`, inside the existing actor body (near `lookupOnDisk`), add:

```swift
/// Index-only lookup. Returns true iff a non-tombstoned entry exists
/// for `digest` in memory. No I/O. Used by `PrecompileScheduler`'s
/// `cachedReady` projection.
public func hasEntry(digest: String) -> Bool {
    guard let entry = entries[digest] else { return false }
    let key = DigestEpoch(digest: digest, epoch: entry.epoch)
    return !tombstones.contains(key)
}
```

(Verify by reading `CoreMLModelCache.swift` that `DigestEpoch` is the existing key type — if the type is named differently in your tree, mirror what `lookupOnDisk` uses.)

- [ ] **Step 4: Run tests to verify they pass**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: both tests pass, no regressions in other `CoreMLModelCacheTests`.

- [ ] **Step 5: Commit**

```bash
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" add "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift" "ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift"
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" commit -m "$(cat <<'EOF'
feat: add CoreMLModelCache.hasEntry(digest:) index lookup

Cheap index-only check needed by PrecompileScheduler to project
on-disk truth into row badges. No I/O; honors tombstones.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `indexEvents: AsyncStream<Void>` to `CoreMLModelCache`

Stream of "index mutated" ticks so the scheduler can refresh `cachedReady` on install/invalidate/clear/eviction.

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test func indexEventsTicksAfterUrlForKeyInstall() async throws {
    let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
    await cache.ensureCacheTreeExistsForTests()

    var iter = await cache.indexEvents.makeAsyncIterator()
    async let tick: Void? = iter.next()

    let pinned = try await cache.urlForKey(digest: "evt1", missCallback: {
        let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
        return u
    })
    await pinned.release()

    let observed = await tick
    #expect(observed != nil)
}

@Test func indexEventsTicksAfterClearAll() async throws {
    let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
    await cache.ensureCacheTreeExistsForTests()

    var iter = await cache.indexEvents.makeAsyncIterator()
    async let tick: Void? = iter.next()

    await cache.clearAll()
    let observed = await tick
    #expect(observed != nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: compile error — no member `indexEvents`.

- [ ] **Step 3: Implement `indexEvents`**

Add inside the actor body, near the other private state at the top of the actor:

```swift
private var indexEventContinuations: [AsyncStream<Void>.Continuation] = []

/// Emits a value whenever the on-disk index mutates: install,
/// `invalidate`, `clearAll`, or eviction. Multiple subscribers each get
/// their own stream. Buffered with `.bufferingNewest(1)` so a slow
/// consumer never falls behind further than one tick.
public var indexEvents: AsyncStream<Void> {
    AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
        indexEventContinuations.append(continuation)
        // Note: continuations are retained for the lifetime of the actor.
        // In production CoreMLModelCache.shared lives for the process
        // lifetime, so no detach logic is needed.
    }
}

private func emitIndexEvent() {
    for cont in indexEventContinuations { cont.yield() }
}
```

Then call `emitIndexEvent()` from each existing mutation site:
1. End of `commitStore(...)` (after the entry is added to `entries` and `writeIndexAtomically()` runs).
2. End of `invalidate(digest:epoch:)`.
3. End of `clearAll()` (after `entries.removeAll()` etc.).
4. End of `evictPartition(...)` if entries were removed.

Use `grep -n "writeIndexAtomically\|entries\[" "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift"` to find each mutation site. If a mutation already ends with `try? writeIndexAtomically()`, add the emit on the line below it.

- [ ] **Step 4: Run tests to verify they pass**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: both new tests pass; existing tests unchanged.

- [ ] **Step 5: Commit**

```bash
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" add "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift" "ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift"
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" commit -m "$(cat <<'EOF'
feat: emit CoreMLModelCache.indexEvents on index mutation

AsyncStream<Void> that ticks on install/invalidate/clearAll/eviction.
Lets PrecompileScheduler keep its cachedReady projection in sync
without polling.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `projectedDigest(...)` to `CoreMLModelCache`

Thin wrapper over `cacheKey(forSourcePath:...)` that returns just the digest, or `nil` when the source file isn't on disk.

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test func projectedDigestReturnsNilForMissingFile() async throws {
    let missingPath = URL.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID()).bin.gz").path
    let result = try await CoreMLModelCache.projectedDigest(
        forSourcePath: missingPath,
        nnXLen: 19, nnYLen: 19,
        requireExactNNLen: false, useFP16: true, maxBatchSize: 1,
        downloadedHasher: { _ in "stub" })
    #expect(result == nil)
}

@Test func projectedDigestMatchesCacheKeyDigest() async throws {
    let tmpFile = URL.temporaryDirectory.appendingPathComponent("\(UUID()).bin.gz")
    try Data("dummy".utf8).write(to: tmpFile)

    let key = try await CoreMLModelCache.cacheKey(
        forSourcePath: tmpFile.path,
        nnXLen: 19, nnYLen: 19,
        requireExactNNLen: false, useFP16: true, maxBatchSize: 1,
        downloadedHasher: { _ in "stub-hash" })

    let projected = try await CoreMLModelCache.projectedDigest(
        forSourcePath: tmpFile.path,
        nnXLen: 19, nnYLen: 19,
        requireExactNNLen: false, useFP16: true, maxBatchSize: 1,
        downloadedHasher: { _ in "stub-hash" })

    #expect(projected == key.digest)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: compile error — no static member `projectedDigest`.

- [ ] **Step 3: Implement `projectedDigest`**

In the `extension CoreMLModelCache` block where `cacheKey` is defined (search for `public static func cacheKey`), add:

```swift
/// Returns the digest the next engine launch would compute for these
/// inputs, or nil if the source file is not present on disk. Production
/// callers use the persisted `BackendSettings` for the model to choose
/// the primitive arguments so the projection matches what the launch
/// path computes via `cacheKey(forSourcePath:...)`.
public static func projectedDigest(
    forSourcePath sourcePath: String,
    nnXLen: Int32, nnYLen: Int32,
    requireExactNNLen: Bool, useFP16: Bool, maxBatchSize: Int,
    downloadedHasher: @Sendable (URL) async throws -> String
) async throws -> String? {
    // Built-in models live in the bundle; downloaded models live under
    // Documents/. A missing file is the "model not yet downloaded" case
    // and should yield nil, not throw.
    if !FileManager.default.fileExists(atPath: sourcePath) { return nil }
    let key = try await cacheKey(
        forSourcePath: sourcePath,
        nnXLen: nnXLen, nnYLen: nnYLen,
        requireExactNNLen: requireExactNNLen,
        useFP16: useFP16, maxBatchSize: maxBatchSize,
        downloadedHasher: downloadedHasher)
    return key.digest
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: both new tests pass.

- [ ] **Step 5: Commit**

```bash
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" add "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift" "ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift"
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" commit -m "$(cat <<'EOF'
feat: add CoreMLModelCache.projectedDigest

Wraps cacheKey() and returns just the digest, nil when the source file
is missing. Used by PrecompileScheduler to predict the cache key a
launch will compute, so badges reflect on-disk truth.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Promote `convertOnCooperativePool` to public

`warm()` needs a `missCallback`, and the natural implementation is the same converter `loadCoreMLHandle` uses. It's currently file-private.

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLComputeHandleLoader.swift`

- [ ] **Step 1: Make `convertOnCooperativePool` public**

Find `func convertOnCooperativePool(` at `CoreMLComputeHandleLoader.swift:112`. Change:

```swift
func convertOnCooperativePool(
```

to:

```swift
public func convertOnCooperativePool(
```

No other changes. The function's body is unchanged.

- [ ] **Step 2: Build all three platforms to confirm nothing else broke**

```
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -20
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -20
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **` on all three.

- [ ] **Step 3: Commit**

```bash
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" add "ios/KataGo iOS/KataGoInterface/CoreMLComputeHandleLoader.swift"
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" commit -m "$(cat <<'EOF'
refactor: expose convertOnCooperativePool publicly

PrecompileScheduler's worker needs the same converter that the engine
launch path uses, so the precompile and launch paths share one cache
miss path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add `warm(...)` to `CoreMLModelCache`

Cache-key projection + `urlForKey` + immediate release. Used by the precompile worker.

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test func warmInstallsEntryAndReleasesPin() async throws {
    let tmpFile = URL.temporaryDirectory.appendingPathComponent("\(UUID()).bin.gz")
    try Data("warm-src".utf8).write(to: tmpFile)
    let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
    await cache.ensureCacheTreeExistsForTests()

    var compiled = 0
    try await cache.warm(
        forSourcePath: tmpFile.path,
        nnXLen: 19, nnYLen: 19,
        requireExactNNLen: false, useFP16: true, maxBatchSize: 1,
        sourceFileName: "warm.bin.gz",
        downloadedHasher: { _ in "stub-hash" },
        missCallback: {
            compiled += 1
            let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            try Data("c".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
            return u
        })
    #expect(compiled == 1)

    // Calling warm again must hit the cache (no second compile).
    try await cache.warm(
        forSourcePath: tmpFile.path,
        nnXLen: 19, nnYLen: 19,
        requireExactNNLen: false, useFP16: true, maxBatchSize: 1,
        sourceFileName: "warm.bin.gz",
        downloadedHasher: { _ in "stub-hash" },
        missCallback: {
            Issue.record("missCallback should not run on second warm")
            throw CancellationError()
        })
    #expect(compiled == 1)

    // Pin must not survive — clearAll relies on no live pins to fully wipe.
    await cache.clearAll()
    let stats = await cache.statsByCategory()
    #expect(stats.main.count == 0)
    #expect(stats.auxiliary.count == 0)
}

@Test func warmIsNoOpWhenSourceFileMissing() async throws {
    let missing = URL.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID()).bin.gz").path
    let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
    await cache.ensureCacheTreeExistsForTests()

    try await cache.warm(
        forSourcePath: missing,
        nnXLen: 19, nnYLen: 19,
        requireExactNNLen: false, useFP16: true, maxBatchSize: 1,
        sourceFileName: nil,
        downloadedHasher: { _ in "stub" },
        missCallback: {
            Issue.record("missCallback should not run when file missing")
            throw CancellationError()
        })
    // No throw; nothing installed.
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: compile error — no member `warm`.

- [ ] **Step 3: Implement `warm`**

In the `extension CoreMLModelCache` block near `cacheKey`/`projectedDigest`, add:

```swift
/// Compute the projected digest and warm the cache. On miss, the
/// provided callback is invoked exactly once and the resulting
/// `.mlmodelc` is committed via the standard install path. On hit,
/// nothing runs. Either way the pin is released immediately because
/// `warm` has no consumer for the URL; the on-disk entry persists.
///
/// Returns early without throwing if the source file is missing
/// (mirrors `projectedDigest`'s nil case — pre-download is not an
/// error).
public func warm(
    forSourcePath sourcePath: String,
    nnXLen: Int32, nnYLen: Int32,
    requireExactNNLen: Bool, useFP16: Bool, maxBatchSize: Int,
    sourceFileName: String?,
    downloadedHasher: @Sendable @escaping (URL) async throws -> String,
    missCallback: @Sendable @escaping () async throws -> URL
) async throws {
    guard let digest = try await Self.projectedDigest(
        forSourcePath: sourcePath,
        nnXLen: nnXLen, nnYLen: nnYLen,
        requireExactNNLen: requireExactNNLen,
        useFP16: useFP16, maxBatchSize: maxBatchSize,
        downloadedHasher: downloadedHasher)
    else { return }

    let pinned = try await urlForKey(
        digest: digest,
        priority: .utility,
        sourceFileName: sourceFileName,
        missCallback: missCallback)
    await pinned.release()
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: both new tests pass.

- [ ] **Step 5: Commit**

```bash
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" add "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift" "ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift"
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" commit -m "$(cat <<'EOF'
feat: add CoreMLModelCache.warm for precompile

Computes the projected digest and runs urlForKey with the provided
miss callback, releasing the pin immediately. Used by
PrecompileScheduler's worker so 'compiling -> ready' transitions
correspond to an actual cache write.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Introduce `ProjectionInputs` + `ProjectionResolver` in the app target

The app-side helper that maps `fileName` → the primitives `projectedDigest` / `warm` need. Keeps `KataGoInterface` ignorant of `BackendSettings` / `NeuralNetworkModel`.

**Files:**
- Create: `ios/KataGo iOS/KataGo iOS/PrecompileProjection.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/PrecompileProjectionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/PrecompileProjectionTests.swift`:

```swift
import Foundation
import Testing
@testable import KataGo_Anytime

struct PrecompileProjectionTests {
    @Test func resolverReturnsNilForUnknownFileName() async throws {
        let inputs = makeProjectionResolver()("definitely-not-a-real-model.bin.gz")
        #expect(inputs == nil)
    }

    @Test func resolverReturnsInputsForBuiltInModel() async throws {
        let inputs = makeProjectionResolver()("default_model.bin.gz")
        #expect(inputs != nil)
        if let inputs {
            #expect(inputs.nnXLen > 0)
            #expect(inputs.nnYLen > 0)
            #expect(inputs.maxBatchSize >= 1)
            // sourcePath must end in default_model.bin.gz; for the
            // built-in this is a bundle resource path, not Documents/.
            #expect(inputs.sourcePath.hasSuffix("default_model.bin.gz"))
        }
    }
}
```

Note: the test target imports the app module as `KataGo_Anytime` (verify the exact module name from the project — match what existing app-side tests import; if there are none, the module name appears in `xcodebuild -showBuildSettings` as `PRODUCT_MODULE_NAME`). If the existing project doesn't have app-side tests, the test target may need to be added to scheme. Confirm before starting: search the `xcodeproj` for `TEST_HOST` or check `ios/KataGo iOS/KataGo iOSTests/` for any file that already imports the app module.

- [ ] **Step 2: Run tests to verify they fail**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: compile error — no file `PrecompileProjection.swift`, no `makeProjectionResolver` function.

- [ ] **Step 3: Implement `PrecompileProjection.swift`**

Create `ios/KataGo iOS/KataGo iOS/PrecompileProjection.swift`:

```swift
import Foundation
import KataGoInterface

/// Primitive inputs for `CoreMLModelCache.projectedDigest` /
/// `CoreMLModelCache.warm`. Keeps the framework ignorant of
/// app-target types like `BackendSettings` and `NeuralNetworkModel`.
public struct ProjectionInputs {
    public let sourcePath: String
    public let nnXLen: Int32
    public let nnYLen: Int32
    public let requireExactNNLen: Bool
    public let useFP16: Bool
    public let maxBatchSize: Int
}

public typealias ProjectionResolver = (_ fileName: String) -> ProjectionInputs?

/// Production resolver. Walks `NeuralNetworkModel.allCases` to find
/// the named model, computes its `BackendSettings`, and maps to the
/// engine-launch primitives. Returns nil if the file is not present
/// on disk (pre-download for non-built-in models).
///
/// NOTE: `useFP16` and `maxBatchSize` must match what the C++ launch
/// path computes. `useFP16 = true` and `maxBatchSize = 1` are the
/// values the cooperative-pool launch uses on iOS Apple Silicon today
/// (verify by reading `CoreMLComputeHandleLoader.swift:loadCoreMLHandle`
/// and the `metalbackend.cpp` site that constructs the
/// `MetalComputeContext`). If those defaults change, this resolver
/// must change with them, otherwise the projection drifts from the
/// launch's actual cache key.
func makeProjectionResolver() -> ProjectionResolver {
    return { fileName in
        guard let model = NeuralNetworkModel.allCases.first(where: { $0.fileName == fileName })
        else { return nil }

        let sourcePath: String
        if model.builtIn {
            // Built-in model lives in the bundle. The C++ engine uses
            // the bundle's resource path; mirror that here so the cache
            // key matches.
            guard let bundleURL = Bundle.main.url(
                forResource: (fileName as NSString).deletingPathExtension,
                withExtension: (fileName as NSString).pathExtension)
            else { return nil }
            sourcePath = bundleURL.path
        } else {
            guard let downloaded = model.downloadedURL,
                  FileManager.default.fileExists(atPath: downloaded.path)
            else { return nil }
            sourcePath = downloaded.path
        }

        let settings = BackendSettings(model: model)
        let nnLen = Int32(settings.effectiveMaxBoardLength)
        return ProjectionInputs(
            sourcePath: sourcePath,
            nnXLen: nnLen, nnYLen: nnLen,
            requireExactNNLen: settings.requireExactNNLen,
            useFP16: true,           // iOS Apple Silicon default; see note above
            maxBatchSize: 1)         // iOS default; see note above
    }
}
```

If `BackendSettings` does not have a `requireExactNNLen` property, search the codebase for how the launch path derives it (`grep -n "requireExactNNLen" "ios/KataGo iOS/KataGo iOS/"`) and mirror the same expression. The two callers must agree.

If the built-in resource isn't named exactly `default_model` in `Bundle.main` (some projects bundle the `.bin.gz` directly without splitting the name), fall back to `Bundle.main.path(forResource: fileName, ofType: nil)`. Verify with `find "ios/KataGo iOS/Resources" -name "default_model*"`.

- [ ] **Step 4: Run tests to verify they pass**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: both tests in `PrecompileProjectionTests` pass.

- [ ] **Step 5: Commit**

```bash
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" add "ios/KataGo iOS/KataGo iOS/PrecompileProjection.swift" "ios/KataGo iOS/KataGo iOSTests/PrecompileProjectionTests.swift"
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" commit -m "$(cat <<'EOF'
feat: ProjectionResolver maps fileName to cache-key primitives

App-side helper that walks NeuralNetworkModel.allCases and
BackendSettings to produce the inputs CoreMLModelCache.projectedDigest
needs. Keeps KataGoInterface ignorant of app-target types.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Refactor `PrecompileScheduler` to split state

Replace `status: [String: PrecompileStatus]` with `ephemeral` + `cachedReady`, expose a computed `status`. No behavioral change at view level yet — the worker still sets `.ready` directly until Task 10.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift`:

```swift
import Foundation
import Testing
@testable import KataGo_Anytime

@MainActor
struct PrecompileSchedulerTests {
    @Test func ephemeralStateAndCachedReadyMergeCorrectly() async throws {
        let scheduler = PrecompileScheduler(worker: { _ in })
        scheduler._setEphemeralForTests(["a.bin.gz": .compiling])
        scheduler._setCachedReadyForTests(["b.bin.gz", "a.bin.gz"])

        // Ephemeral wins where both exist.
        #expect(scheduler.status["a.bin.gz"] == .compiling)
        // CachedReady fills in where ephemeral is absent.
        #expect(scheduler.status["b.bin.gz"] == .ready)
        // Unknown remains nil (badge resolves to .idle via the ?? .idle
        // fallback at the call site).
        #expect(scheduler.status["c.bin.gz"] == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: compile error — `_setEphemeralForTests`, `_setCachedReadyForTests` not found.

- [ ] **Step 3: Refactor `PrecompileScheduler`**

Edit `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift`. Replace the existing class body with:

```swift
@MainActor @Observable
public final class PrecompileScheduler {
    public typealias Worker = (_ fileName: String) async throws -> Void

    private let defaults: UserDefaults
    private let worker: Worker
    private var inFlight: Set<String> = []
    private var ephemeral: [String: PrecompileStatus] = [:]
    private var cachedReady: Set<String> = []

    /// Merged read-only view used by SwiftUI bindings. Ephemeral states
    /// (queued/compiling/failed) win over cachedReady so users see live
    /// progress even when a stale cachedReady bit could otherwise show.
    public var status: [String: PrecompileStatus] {
        var merged: [String: PrecompileStatus] = [:]
        for fileName in cachedReady { merged[fileName] = .ready }
        for (fileName, state) in ephemeral { merged[fileName] = state }
        return merged
    }

    public init(defaults: UserDefaults = .standard, worker: @escaping Worker) {
        self.defaults = defaults
        self.worker = worker
    }

    public func scheduleForModel(fileName: String) async {
        if defaults.string(forKey: "backend_\(fileName)") == "mpsGPU" {
            log.info("skip-precompile reason=mpsGPU fileName=\(fileName, privacy: .public)")
            return
        }
        guard !inFlight.contains(fileName) else { return }
        inFlight.insert(fileName)
        ephemeral[fileName] = .queued
        Task(priority: .utility) {
            self.ephemeral[fileName] = .compiling
            do {
                try await self.worker(fileName)
                // Behavior change in Task 10: cachedReady refresh.
                // For now keep the original semantics so this task does
                // not regress views.
                self.ephemeral[fileName] = nil
                self.cachedReady.insert(fileName)
            } catch {
                let summary = (error as NSError).localizedDescription
                log.error("precompile.failed model=\(fileName, privacy: .public) error=\(String(describing: error), privacy: .public)")
                self.ephemeral[fileName] = .failed(message: summary)
            }
            self.inFlight.remove(fileName)
        }
    }

    public func scheduleBuiltIn() async {
        await scheduleForModel(fileName: "default_model.bin.gz")
    }

    public func cancelAllPending() {
        inFlight.removeAll()
        ephemeral.removeAll()
    }

    // MARK: - Test seams (intentionally exposed; do not call from production)

    public func _setEphemeralForTests(_ map: [String: PrecompileStatus]) {
        ephemeral = map
    }
    public func _setCachedReadyForTests(_ set: Set<String>) {
        cachedReady = set
    }
}
```

The `_set...ForTests` seams stay public because the test target is a separate module. Comment notes they are not production API.

- [ ] **Step 4: Run tests to verify they pass**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: new merge test passes; build still green elsewhere.

- [ ] **Step 5: Commit**

```bash
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" add "ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift" "ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift"
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" commit -m "$(cat <<'EOF'
refactor: split PrecompileScheduler state into ephemeral + cachedReady

status[fileName] becomes a computed merge of two stores: ephemeral
(queued/compiling/failed) and cachedReady (projection of the cache
index). No view changes yet; ready behavior preserved by inserting
into cachedReady on worker success.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Add `hydrate(...)` to `PrecompileScheduler`

Initial fill of `cachedReady` from `CoreMLModelCache.hasEntry` on cold launch.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `PrecompileSchedulerTests`:

```swift
@Test func hydratePopulatesCachedReadyFromCache() async throws {
    // Stand up a real CoreMLModelCache over a temp dir, install one entry.
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = CoreMLModelCache(cacheRoot: root)
    await cache.ensureCacheTreeExistsForTests()

    let pinned = try await cache.urlForKey(digest: "fake-digest", missCallback: {
        let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
        return u
    })
    await pinned.release()

    let scheduler = PrecompileScheduler(worker: { _ in })
    let resolver: ProjectionResolver = { fileName in
        if fileName == "match.bin.gz" {
            return ProjectionInputs(
                sourcePath: "/dev/null", // never read; we stub the digest via resolverDigest below
                nnXLen: 19, nnYLen: 19,
                requireExactNNLen: false, useFP16: true, maxBatchSize: 1)
        }
        return nil
    }
    // For the test, we bypass the real projectedDigest plumbing using an
    // injected digest map. See Step 3 — hydrate accepts a digest mapper
    // so tests don't need real source files.
    let knownFileNames: Set<String> = ["match.bin.gz", "missing.bin.gz"]
    await scheduler.hydrate(
        from: cache,
        fileNames: knownFileNames,
        digestFor: { fileName in
            fileName == "match.bin.gz" ? "fake-digest" : nil
        })

    #expect(scheduler.status["match.bin.gz"] == .ready)
    #expect(scheduler.status["missing.bin.gz"] == nil)
}
```

The `digestFor` parameter lets tests avoid creating real bundle / Documents files. Production code paths supply a closure that wraps `projectedDigest`.

- [ ] **Step 2: Run tests to verify they fail**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: compile error — `hydrate(from:fileNames:digestFor:)` not found.

- [ ] **Step 3: Implement `hydrate`**

Add inside the `PrecompileScheduler` class body:

```swift
/// Replace cachedReady with the subset of `fileNames` whose projected
/// digest is currently in the cache. Each fileName is wrapped so one
/// failure does not abort the rest. Ephemeral state is untouched.
public func hydrate(
    from cache: CoreMLModelCache,
    fileNames: Set<String>,
    digestFor: @escaping (String) async throws -> String?
) async {
    var fresh: Set<String> = []
    for fileName in fileNames {
        do {
            guard let digest = try await digestFor(fileName) else { continue }
            if await cache.hasEntry(digest: digest) {
                fresh.insert(fileName)
            }
        } catch {
            // Hash / hasher failures during hydration are non-fatal.
            // Treat as "not ready" rather than surfacing in the badge.
            continue
        }
    }
    cachedReady = fresh
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: hydrate test passes.

- [ ] **Step 5: Commit**

```bash
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" add "ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift" "ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift"
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" commit -m "$(cat <<'EOF'
feat: PrecompileScheduler.hydrate fills cachedReady from cache

Asks the cache.hasEntry for each known fileName's projected digest and
records the survivors. Cold-launch hook so row badges reflect on-disk
truth without waiting for the user to interact with the model.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Add `subscribeToCacheEvents(...)` to `PrecompileScheduler`

Auto-refresh `cachedReady` whenever the cache index mutates.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test func cacheEventTickRefreshesCachedReady() async throws {
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = CoreMLModelCache(cacheRoot: root)
    await cache.ensureCacheTreeExistsForTests()

    let scheduler = PrecompileScheduler(worker: { _ in })
    scheduler._setCachedReadyForTests(["a.bin.gz"])  // stale

    let knownFileNames: Set<String> = ["a.bin.gz"]
    scheduler.subscribeToCacheEvents(
        cache,
        fileNames: knownFileNames,
        digestFor: { _ in "absent-digest" })

    // Trigger a tick. cachedReady should drop "a.bin.gz" because
    // the digest is not in the cache.
    await cache.clearAll()

    // Allow one runloop turn for the subscription to react.
    try await Task.sleep(for: .milliseconds(50))

    #expect(scheduler.status["a.bin.gz"] == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: compile error — no member `subscribeToCacheEvents`.

- [ ] **Step 3: Implement `subscribeToCacheEvents`**

Add a guard so repeated calls (SwiftUI `.task` can re-fire across some lifecycle transitions) don't spawn multiple consumers:

```swift
private var didSubscribe = false

/// Start a long-lived task that consumes `cache.indexEvents` and
/// re-hydrates `cachedReady` after each tick. Guarded so repeated
/// calls (e.g., scene `.task` re-firing) are no-ops.
public func subscribeToCacheEvents(
    _ cache: CoreMLModelCache,
    fileNames: Set<String>,
    digestFor: @escaping (String) async throws -> String?
) {
    guard !didSubscribe else { return }
    didSubscribe = true
    Task { [weak self] in
        for await _ in await cache.indexEvents {
            guard let self else { return }
            await self.hydrate(from: cache, fileNames: fileNames, digestFor: digestFor)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: subscribe test passes.

- [ ] **Step 5: Commit**

```bash
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" add "ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift" "ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift"
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" commit -m "$(cat <<'EOF'
feat: PrecompileScheduler.subscribeToCacheEvents auto-refreshes

Consumes CoreMLModelCache.indexEvents and re-hydrates cachedReady on
every tick. Lets badges follow eviction and external installs without
polling.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Worker success refreshes `cachedReady` via hasEntry instead of unconditional insert

The Task 7 stop-gap inserts into `cachedReady` on success regardless of whether the cache actually has the entry. Replace with a hasEntry-confirmed update.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `PrecompileSchedulerTests`:

```swift
@Test func workerSuccessReflectsCacheState() async throws {
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = CoreMLModelCache(cacheRoot: root)
    await cache.ensureCacheTreeExistsForTests()

    // Pre-install the digest the worker is supposed to warm.
    let pinned = try await cache.urlForKey(digest: "real-digest", missCallback: {
        let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
        return u
    })
    await pinned.release()

    let scheduler = PrecompileScheduler(
        worker: { _ in /* simulate successful warm */ },
        cache: cache,
        digestFor: { fileName in
            fileName == "real.bin.gz" ? "real-digest" : nil
        })
    UserDefaults.standard.set("coremlNE", forKey: "backend_real.bin.gz")

    await scheduler.scheduleForModel(fileName: "real.bin.gz")
    try await Task.sleep(for: .milliseconds(100))
    #expect(scheduler.status["real.bin.gz"] == .ready)

    // Worker for a fileName the cache does not contain leaves cachedReady untouched.
    UserDefaults.standard.set("coremlNE", forKey: "backend_ghost.bin.gz")
    await scheduler.scheduleForModel(fileName: "ghost.bin.gz")
    try await Task.sleep(for: .milliseconds(100))
    #expect(scheduler.status["ghost.bin.gz"] == nil)

    UserDefaults.standard.removeObject(forKey: "backend_real.bin.gz")
    UserDefaults.standard.removeObject(forKey: "backend_ghost.bin.gz")
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: compile error — `PrecompileScheduler.init(worker:cache:digestFor:)` not found.

- [ ] **Step 3: Extend `PrecompileScheduler.init` and update success path**

Add an additional initializer (production callers will use this; existing init stays for legacy tests):

```swift
private let cache: CoreMLModelCache?
private let digestFor: ((String) async throws -> String?)?

public init(
    defaults: UserDefaults = .standard,
    worker: @escaping Worker,
    cache: CoreMLModelCache,
    digestFor: @escaping (String) async throws -> String?
) {
    self.defaults = defaults
    self.worker = worker
    self.cache = cache
    self.digestFor = digestFor
}
```

Update the original `init(defaults:worker:)` to also initialize `cache = nil`, `digestFor = nil`.

In the success branch of `scheduleForModel`, replace:

```swift
self.ephemeral[fileName] = nil
self.cachedReady.insert(fileName)
```

with:

```swift
self.ephemeral[fileName] = nil
await self.refreshCachedReady(for: fileName)
```

And add:

```swift
private func refreshCachedReady(for fileName: String) async {
    guard let cache, let digestFor else {
        // Test path that didn't wire cache/digestFor: preserve old semantics.
        cachedReady.insert(fileName)
        return
    }
    do {
        guard let digest = try await digestFor(fileName) else {
            cachedReady.remove(fileName); return
        }
        if await cache.hasEntry(digest: digest) {
            cachedReady.insert(fileName)
        } else {
            cachedReady.remove(fileName)
        }
    } catch {
        cachedReady.remove(fileName)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: new test passes; pre-existing scheduler tests still pass.

- [ ] **Step 5: Commit**

```bash
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" add "ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift" "ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift"
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" commit -m "$(cat <<'EOF'
fix: PrecompileScheduler confirms cache state after worker success

Replaces unconditional cachedReady.insert with a hasEntry check via the
projected digest. Worker no longer falsely reports ready when the cache
write did not happen.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Replace placeholder worker with real `cache.warm` call

Drop the 1-second sleep. The worker calls `cache.warm` with `convertOnCooperativePool` as miss callback.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`

- [ ] **Step 1: Replace `runPrecompileWorker`**

In `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`, replace lines 116-126 (the comment block + function body for `runPrecompileWorker`) with:

```swift
// MARK: - PrecompileScheduler worker

/// Real precompile worker. Resolves projection inputs from the named
/// model's persisted BackendSettings, then asks CoreMLModelCache.warm
/// to compute the digest and either hit the cache or invoke the same
/// converter the engine launch uses.
@MainActor
private func runPrecompileWorker(fileName: String) async throws {
    guard let inputs = makeProjectionResolver()(fileName) else { return }
    try await CoreMLModelCache.shared.warm(
        forSourcePath: inputs.sourcePath,
        nnXLen: inputs.nnXLen, nnYLen: inputs.nnYLen,
        requireExactNNLen: inputs.requireExactNNLen,
        useFP16: inputs.useFP16,
        maxBatchSize: inputs.maxBatchSize,
        sourceFileName: fileName,
        downloadedHasher: BinFileHasher.shared.identityForDownloadedFile,
        missCallback: {
            return try await convertOnCooperativePool(
                coremlModelPath: inputs.sourcePath,
                boardX: inputs.nnXLen, boardY: inputs.nnYLen,
                useFP16: inputs.useFP16,
                optimizeMask: inputs.requireExactNNLen,
                maxBatchSize: Int32(inputs.maxBatchSize),
                serverThreadIdx: 0)
        })
}
```

Note: `convertOnCooperativePool` is now public (Task 4) so the app target can call it directly.

If the build complains that `convertOnCooperativePool` isn't visible, confirm the `import KataGoInterface` line is present at the top of `KataGo_iOSApp.swift` (it is, per the existing code).

- [ ] **Step 2: Build all three platforms**

```
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -20
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -20
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **` on all three.

- [ ] **Step 3: Run the test suite**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" add "ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift"
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" commit -m "$(cat <<'EOF'
fix: runPrecompileWorker actually warms the Core ML cache

Replaces 1s sleep placeholder with a real CoreMLModelCache.warm call
using the same convertOnCooperativePool shim the engine launch path
uses. A row badge of .ready now corresponds to an on-disk entry.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Wire `hydrate` + `subscribeToCacheEvents` at app init

Make cold-launch checkmarks honest.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`

- [ ] **Step 1: Replace the existing `PrecompileScheduler` instantiation**

In `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`, lines 15-17 currently read:

```swift
@State private var precompileScheduler = PrecompileScheduler { fileName in
    try await runPrecompileWorker(fileName: fileName)
}
```

Replace with:

```swift
@State private var precompileScheduler: PrecompileScheduler = {
    let resolver = makeProjectionResolver()
    return PrecompileScheduler(
        worker: { fileName in
            try await runPrecompileWorker(fileName: fileName)
        },
        cache: .shared,
        digestFor: { fileName in
            guard let inputs = resolver(fileName) else { return nil }
            return try await CoreMLModelCache.projectedDigest(
                forSourcePath: inputs.sourcePath,
                nnXLen: inputs.nnXLen, nnYLen: inputs.nnYLen,
                requireExactNNLen: inputs.requireExactNNLen,
                useFP16: inputs.useFP16,
                maxBatchSize: inputs.maxBatchSize,
                downloadedHasher: BinFileHasher.shared.identityForDownloadedFile)
        })
}()
```

- [ ] **Step 2: Kick hydrate + subscribe at scene appearance**

Edit the scene-builder block to attach a `.task` modifier that hydrates and subscribes. In the existing scene blocks (search for `ModelRunnerView()`), wrap with a `.task` so it runs once when the view appears:

```swift
ModelRunnerView()
    .environment(precompileScheduler)
    .environment(engineLaunchStatus)
    .task {
        let knownFileNames = Set(NeuralNetworkModel.allCases.map(\.fileName))
        let resolver = makeProjectionResolver()
        let digestFor: (String) async throws -> String? = { fileName in
            guard let inputs = resolver(fileName) else { return nil }
            return try await CoreMLModelCache.projectedDigest(
                forSourcePath: inputs.sourcePath,
                nnXLen: inputs.nnXLen, nnYLen: inputs.nnYLen,
                requireExactNNLen: inputs.requireExactNNLen,
                useFP16: inputs.useFP16,
                maxBatchSize: inputs.maxBatchSize,
                downloadedHasher: BinFileHasher.shared.identityForDownloadedFile)
        }
        await CoreMLModelCache.shared.start()
        await precompileScheduler.hydrate(
            from: .shared,
            fileNames: knownFileNames,
            digestFor: digestFor)
        precompileScheduler.subscribeToCacheEvents(
            .shared,
            fileNames: knownFileNames,
            digestFor: digestFor)
    }
```

Apply this to both the `#if os(macOS)` and the `#else` branch so iOS, macOS, and visionOS share the same hook.

- [ ] **Step 3: Build all three platforms**

```
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -20
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -20
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | tail -20
```

Expected: builds succeed on all three.

- [ ] **Step 4: Manual smoke test (developer machine)**

1. Build & run the iOS Simulator target.
2. With a populated cache from a previous session, observe that on launch the built-in row eventually shows the checkmark without any user interaction. (Check via Xcode preview or by tapping into the picker.)
3. Inspect stderr in Xcode console: `CoreMLCache hit:` lines should appear from `urlForKey` calls already; hydrate itself is silent.

If the cache is empty (fresh install), the checkmark only appears after launching the built-in engine once. That's the expected post-warm flow.

- [ ] **Step 5: Commit**

```bash
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" add "ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift"
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" commit -m "$(cat <<'EOF'
feat: hydrate scheduler from CoreMLModelCache at app launch

Cold launch now reads the cache index and fills cachedReady so row
checkmarks reflect on-disk truth before any user action. Subscribes
to indexEvents to keep cachedReady in sync with installs/evictions.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Re-hydrate after Clear Cache

When the user clears the cache, drop the badges in lockstep with the footer count.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/CoreMLCacheFooterView.swift`

- [ ] **Step 1: Update `clear()` to call hydrate**

In `CoreMLCacheFooterView.swift`, the existing `clear()` is at lines 78-85. Replace with:

```swift
@MainActor private func clear() async {
    clearing = true
    defer { clearing = false }
    await CoreMLModelCache.shared.clearAll()
    UserDefaults.standard.set("", forKey: "CoreMLCache.firstLaunchPrecompileVersion")
    scheduler.cancelAllPending()
    // Re-hydrate so cachedReady drops to empty in lockstep with the
    // footer count zeroing. subscribeToCacheEvents would also fire from
    // the clearAll tick, but this explicit await guarantees the badge
    // is consistent by the time `refresh()` reads stats below.
    let knownFileNames = Set(NeuralNetworkModel.allCases.map(\.fileName))
    let resolver = makeProjectionResolver()
    await scheduler.hydrate(
        from: .shared,
        fileNames: knownFileNames,
        digestFor: { fileName in
            guard let inputs = resolver(fileName) else { return nil }
            return try await CoreMLModelCache.projectedDigest(
                forSourcePath: inputs.sourcePath,
                nnXLen: inputs.nnXLen, nnYLen: inputs.nnYLen,
                requireExactNNLen: inputs.requireExactNNLen,
                useFP16: inputs.useFP16,
                maxBatchSize: inputs.maxBatchSize,
                downloadedHasher: BinFileHasher.shared.identityForDownloadedFile)
        })
    await scheduler.scheduleBuiltIn()
    await refresh()
}
```

(Repeated digest-resolver code is intentional per the plan's DRY tradeoff — a future task can extract this into a single helper if a fourth call site appears.)

- [ ] **Step 2: Build all three platforms**

```
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -20
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug 2>&1 | tail -20
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | tail -20
```

Expected: all three succeed.

- [ ] **Step 3: Manual smoke test**

1. Run iOS Simulator with a populated cache.
2. Tap "Clear Cache" → confirm.
3. All row checkmarks disappear; footer shows 0 of 4 (or whatever the cap).
4. The built-in row should transition queued → compiling → ready over a few seconds as `scheduleBuiltIn` runs.

- [ ] **Step 4: Commit**

```bash
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" add "ios/KataGo iOS/KataGo iOS/CoreMLCacheFooterView.swift"
git -C "/Users/chinchangyang/Code/KataGo-ios-dev" commit -m "$(cat <<'EOF'
fix: re-hydrate scheduler after Clear Cache

cancelAllPending + hydrate drops all row checkmarks in lockstep with
the footer count zeroing, instead of leaving stale .ready bits in
cachedReady until the next launch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Run the existing UI regression test

`CoreMLCacheFooterUITests.testFooterCountIncrementsAfterDownloadedModelLaunch` is the end-to-end regression for Gap A+B. It should now pass.

**Files:**
- No code changes — just verification.

- [ ] **Step 1: Uninstall the simulator app for a clean cache state**

The test header says to run after a clean uninstall:

```
xcrun simctl uninstall booted chinchangyang.KataGo-iOS.tw
```

If `booted` is ambiguous, boot a specific simulator first:

```
xcrun simctl boot "iPhone 17" || true
xcrun simctl uninstall "iPhone 17" chinchangyang.KataGo-iOS.tw
```

- [ ] **Step 2: Run only the UI test**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:"KataGo AnytimeUITests/CoreMLCacheFooterUITests/testFooterCountIncrementsAfterDownloadedModelLaunch" 2>&1 | tail -60
```

Expected: `Test Case ... passed`. The footer count after Step 2 (Lionffen launch) is strictly greater than after Step 1.

If it fails with "expected count to increase":
- Check Xcode console / xcresult for `CoreMLCache hit:` and `precompile.failed` lines.
- Confirm `convertOnCooperativePool` was actually invoked for the downloaded model (it should have been on the engine-launch miss).
- Confirm projection inputs for the Lionffen file match what the actual engine launch used — if they diverge, `hasEntry` will be false even after a real launch warmed a different digest. This points back at Task 6's `useFP16` / `maxBatchSize` defaults.

- [ ] **Step 3: Run the full test suite to catch regressions**

```
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -60
```

Expected: every test passes.

- [ ] **Step 4: Final commit (only if any fix-ups were needed)**

If steps 2 or 3 required code changes to pass, commit them with a focused message describing the fix. Otherwise skip this step.

---

## Self-Review

Before declaring done, re-check the spec against the plan:

- **`hasEntry`** — Task 1.
- **`indexEvents`** — Task 2.
- **`projectedDigest`** — Task 3.
- **`warm`** — Task 5.
- **`PrecompileScheduler` split state + computed status** — Task 7.
- **`hydrate`** — Task 8.
- **`subscribeToCacheEvents`** — Task 9.
- **Worker success refreshes via hasEntry** — Task 10.
- **Real worker (no more `sleep(1)`)** — Task 11.
- **App-init hydrate + subscribe** — Task 12.
- **Clear-cache re-hydrate** — Task 13.
- **UI regression test passes** — Task 14.

Open spec questions, decided:

- Badge during in-launch miss: stays as-is (no new code, covered by existing `LoadingView` caption).
- Eviction notification: `indexEvents: AsyncStream<Void>` (Task 2).
- Projection inputs match runtime: `makeProjectionResolver()` uses `BackendSettings.effectiveMaxBoardLength` for nnXLen/nnYLen and constant `useFP16 = true` / `maxBatchSize = 1` for iOS Apple Silicon (Task 6). If smoke testing reveals a mismatch (UI test in Task 14 fails because projection differs from actual launch cache key), the resolver constants need updating — see Task 14 Step 2 debug guidance.

Future improvements deferred:
- Extracting the duplicated `digestFor` closure in `KataGo_iOSApp.swift` and `CoreMLCacheFooterView.swift` into a shared helper, when a fourth call site appears.
- Adding `BadgeReflectsCacheOnColdLaunch` UI test (optional per spec).
