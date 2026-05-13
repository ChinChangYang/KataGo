# Remove Core ML Precompile — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the background Core ML precompile system from KataGo Anytime. Keep the on-disk cache (now populated lazily on first model load), keep the picker footer (counts + Clear), and keep the per-row **green checkmark** for cached models. Drop the spinner/clock badges, scenePhase sweeps, and all `PrecompileScheduler` plumbing.

**Architecture:** Replace `PrecompileScheduler` (queue + worker + status enum) with a smaller `CoreMLCacheReadiness` `@Observable` that exposes `readyFileNames: Set<String>` only. The readiness object subscribes directly to `CoreMLModelCache.indexEvents` and recomputes the set against the picker's last-known filename list via a renamed `CoreMLCacheReadinessProjection`. The footer also subscribes to `indexEvents` directly. First load of an uncompiled model now performs an inline compile via the existing `CoreMLComputeHandleLoader` miss-callback path — no background warmer.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`@Test`), XCTest UI tests, `xcodebuild` for the iOS/macOS/visionOS build matrix.

**Spec:** `docs/superpowers/specs/2026-05-13-remove-coreml-precompile-design.md`

---

## Pre-flight

- [ ] **Step 0a: Confirm current branch**

Run: `git -C "/Users/chinchangyang/Code/KataGo-ios-dev" status --short --branch`
Expected: `## ios-dev...` with no committed-but-unstaged plan-related changes (the spec commit `99076e6c` should already be in `git log`).

- [ ] **Step 0b: Verify the iOS simulator build baseline still passes**

Run from the repo root:
```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`. (If this fails before any change, stop and report; we need a clean baseline.)

---

## Task 1: Rename `PrecompileProjection` → `CoreMLCacheReadinessProjection`

**Files:**
- Rename: `ios/KataGo iOS/KataGo iOS/PrecompileProjection.swift` → `ios/KataGo iOS/KataGo iOS/CoreMLCacheReadinessProjection.swift`
- Rename: `ios/KataGo iOS/KataGo iOSTests/PrecompileProjectionTests.swift` → `ios/KataGo iOS/KataGo iOSTests/CoreMLCacheReadinessProjectionTests.swift`
- Modify: the renamed files' docstrings (strip references to `PrecompileScheduler` / `cachedReady`)
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` — Xcode tracks file paths; the rename must be reflected in the project file. Use `git mv` and the `name`/`path` references will follow.

The two existing helpers (`makeProjectionResolver()` and `makeProjectionDigestFor()`) keep the same signatures. The new `CoreMLCacheReadiness` (Task 2) will call them. `PrecompileScheduler` is still in the tree at this point and still calls `makeProjectionDigestFor()` — that compiles fine because the function name doesn't change.

- [ ] **Step 1.1: Rename source file via git**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git mv "ios/KataGo iOS/KataGo iOS/PrecompileProjection.swift" \
       "ios/KataGo iOS/KataGo iOS/CoreMLCacheReadinessProjection.swift"
```

- [ ] **Step 1.2: Rename test file via git**

```bash
git mv "ios/KataGo iOS/KataGo iOSTests/PrecompileProjectionTests.swift" \
       "ios/KataGo iOS/KataGo iOSTests/CoreMLCacheReadinessProjectionTests.swift"
```

- [ ] **Step 1.3: Update the test struct name**

Edit `ios/KataGo iOS/KataGo iOSTests/CoreMLCacheReadinessProjectionTests.swift`:

Replace:
```swift
struct PrecompileProjectionTests {
```
With:
```swift
struct CoreMLCacheReadinessProjectionTests {
```

- [ ] **Step 1.4: Strip scheduler docstring references in the renamed source**

Edit `ios/KataGo iOS/KataGo iOS/CoreMLCacheReadinessProjection.swift`:

Replace the file header:
```swift
//
//  PrecompileProjection.swift
//  KataGo Anytime
//
//  App-side mapping from a model `fileName` to the primitive inputs
//  needed by `CoreMLModelCache.projectedDigest` / `CoreMLModelCache.warm`.
//
//  Keeps the `KataGoInterface` framework ignorant of app-target types
//  like `BackendSettings` and `NeuralNetworkModel`.
//
```
With:
```swift
//
//  CoreMLCacheReadinessProjection.swift
//  KataGo Anytime
//
//  App-side mapping from a model `fileName` to the primitive inputs
//  needed by `CoreMLModelCache.projectedDigest`. Used by
//  `CoreMLCacheReadiness` to decide whether a row's green checkmark
//  should show in the model picker.
//
//  Keeps the `KataGoInterface` framework ignorant of app-target types
//  like `BackendSettings` and `NeuralNetworkModel`.
//
```

Replace the docstring above `makeProjectionDigestFor`:
```swift
/// Wraps the projection resolver into a digest-only closure suitable
/// for `PrecompileScheduler.hydrate(...)` and `subscribeToCacheEvents(...)`.
/// Walks `NeuralNetworkModel.allCases` to map a fileName to its source
/// path + backend settings, then asks `CoreMLModelCache.projectedDigest`
/// for the digest the next engine launch would compute. Returns nil
/// when the file is not downloaded (mirrors `projectedDigest`).
```
With:
```swift
/// Returns a digest-only closure that maps a fileName to the cache
/// digest the next engine launch would compute. Used by
/// `CoreMLCacheReadiness` to ask `CoreMLModelCache.hasEntry(digest:)`
/// whether a given fileName is currently cached on disk.
/// Returns nil when the file is not downloaded.
```

- [ ] **Step 1.5: Build to confirm Xcode picked up the rename**

Run:
```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`.

If Xcode reports `error: Build input file cannot be found: '.../PrecompileProjection.swift'`, the `project.pbxproj` still references the old path. Open the project once with Xcode (or use `sed` to rewrite the two `PrecompileProjection.swift` and `PrecompileProjectionTests.swift` occurrences in `project.pbxproj` to the new names — Xcode tracks files by path string).

- [ ] **Step 1.6: Run the projection tests**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/CoreMLCacheReadinessProjectionTests"
```
Expected: 3 tests pass.

- [ ] **Step 1.7: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: rename PrecompileProjection to CoreMLCacheReadinessProjection

Pure rename + docstring update. Behavior unchanged. Sets up the
upcoming swap of PrecompileScheduler for a smaller readiness
projection consumed by the model picker's green checkmark.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `CoreMLCacheReadiness` (`@Observable`)

**Files:**
- Create: `ios/KataGo iOS/KataGo iOS/CoreMLCacheReadiness.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/CoreMLCacheReadinessTests.swift`

The class owns:
- `readyFileNames: Set<String>` — read by `ModelPickerView`'s row badge.
- `update(forFileNames:)` — called by the picker whenever its displayed model list changes.
- An internal long-lived `Task` that consumes `CoreMLModelCache.shared.indexEvents` and re-runs the projection against the last-known filenames.

**Note on test isolation:** the production cache is the process-wide `CoreMLModelCache.shared`. Tests should not assume a specific cache state. We test the recompute *plumbing* by injecting a custom `DigestFor` closure and a custom `HasEntry` closure rather than reaching into `.shared`. The production `init` wires the shared cache; the test `init` accepts seams.

- [ ] **Step 2.1: Write the failing test**

Create `ios/KataGo iOS/KataGo iOSTests/CoreMLCacheReadinessTests.swift`:

```swift
import Foundation
import Testing
@testable import KataGo_Anytime

@MainActor
struct CoreMLCacheReadinessTests {
    @Test func updateForFileNamesSetsReadyFromProjectionAndCache() async throws {
        // Two filenames: "a" has a digest and is cached; "b" has a digest
        // but is not cached. Expect only "a" in readyFileNames.
        let digestFor: @Sendable (String) async throws -> String? = { fileName in
            switch fileName {
            case "a": return "digest-a"
            case "b": return "digest-b"
            default:  return nil
            }
        }
        let hasEntry: @Sendable (String) async -> Bool = { digest in
            return digest == "digest-a"
        }

        let readiness = CoreMLCacheReadiness(
            digestFor: digestFor,
            hasEntry: hasEntry)

        await readiness.update(forFileNames: ["a", "b"])

        #expect(readiness.readyFileNames == ["a"])
    }

    @Test func updateForFileNamesTreatsNilDigestAsNotReady() async throws {
        // "missing" has no digest (file not downloaded). It must not
        // appear in readyFileNames even if hasEntry would say true for
        // some other digest.
        let digestFor: @Sendable (String) async throws -> String? = { _ in nil }
        let hasEntry: @Sendable (String) async -> Bool = { _ in true }

        let readiness = CoreMLCacheReadiness(
            digestFor: digestFor,
            hasEntry: hasEntry)

        await readiness.update(forFileNames: ["missing"])

        #expect(readiness.readyFileNames.isEmpty)
    }

    @Test func updateForFileNamesSwallowsDigestErrors() async throws {
        struct E: Error {}
        let digestFor: @Sendable (String) async throws -> String? = { fileName in
            if fileName == "throws" { throw E() }
            return "digest-\(fileName)"
        }
        let hasEntry: @Sendable (String) async -> Bool = { _ in true }

        let readiness = CoreMLCacheReadiness(
            digestFor: digestFor,
            hasEntry: hasEntry)

        await readiness.update(forFileNames: ["throws", "ok"])

        // "throws" is excluded; "ok" projected to "digest-ok" and present.
        #expect(readiness.readyFileNames == ["ok"])
    }
}
```

- [ ] **Step 2.2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/CoreMLCacheReadinessTests"
```
Expected: FAIL — `CoreMLCacheReadiness` is undefined.

- [ ] **Step 2.3: Implement `CoreMLCacheReadiness`**

Create `ios/KataGo iOS/KataGo iOS/CoreMLCacheReadiness.swift`:

```swift
//
//  CoreMLCacheReadiness.swift
//  KataGo Anytime
//
//  Per-filename "is the Core ML cache populated for this model?"
//  signal consumed by the model picker's green checkmark. Replaces
//  the old PrecompileScheduler's `cachedReady` set.
//

import Foundation
import KataGoInterface
import Observation
import OSLog

private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "KataGo Anytime",
    category: "engine.coreml.readiness")

@MainActor
@Observable
public final class CoreMLCacheReadiness {
    /// Filenames whose projected digest is currently on disk.
    /// `ModelPickerView` reads this to show the green checkmark.
    public private(set) var readyFileNames: Set<String> = []

    /// Seam: filename → expected cache digest (or nil if the file is
    /// not downloaded). Production uses `makeProjectionDigestFor()`.
    private let digestFor: @Sendable (String) async throws -> String?

    /// Seam: digest → "is this entry currently on disk?". Production
    /// wraps `CoreMLModelCache.shared.hasEntry(digest:)`.
    private let hasEntry: @Sendable (String) async -> Bool

    /// Last filename set passed to `update(forFileNames:)`. The
    /// indexEvents subscription re-runs the projection against this
    /// list on every yield.
    private var lastKnown: [String] = []

    /// Guards the long-lived subscription task so repeated `start()`
    /// calls (e.g., scene `.task` re-firing) are no-ops.
    private var didStart = false

    /// Production initializer. Wires the shared cache and the
    /// production projection closure.
    public convenience init() {
        let digestFor = makeProjectionDigestFor()
        self.init(
            digestFor: digestFor,
            hasEntry: { digest in
                await CoreMLModelCache.shared.hasEntry(digest: digest)
            })
    }

    /// Designated initializer with seams for testing.
    public init(
        digestFor: @Sendable @escaping (String) async throws -> String?,
        hasEntry: @Sendable @escaping (String) async -> Bool
    ) {
        self.digestFor = digestFor
        self.hasEntry = hasEntry
    }

    /// Tell the readiness object which filenames the picker currently
    /// displays. Recomputes `readyFileNames` immediately.
    public func update(forFileNames fileNames: [String]) async {
        lastKnown = fileNames
        await recompute()
    }

    /// Subscribe to `CoreMLModelCache.shared.indexEvents` and re-run
    /// the projection on every yield. Idempotent. Call once from the
    /// app's scene `.task`.
    public func start() async {
        guard !didStart else { return }
        didStart = true

        // Ensure the on-disk index is loaded before our first read.
        await CoreMLModelCache.shared.start()

        let stream = await CoreMLModelCache.shared.indexEvents
        Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.recompute()
            }
        }
    }

    private func recompute() async {
        var fresh: Set<String> = []
        for fileName in lastKnown {
            do {
                guard let digest = try await digestFor(fileName) else { continue }
                if await hasEntry(digest) { fresh.insert(fileName) }
            } catch {
                // Best-effort UI state. A projection failure here
                // means the row simply lacks a checkmark for this
                // tick; the engine path is unaffected.
                log.info("readiness.digestFailed fileName=\(fileName, privacy: .public) error=\(String(describing: error), privacy: .public)")
                continue
            }
        }
        readyFileNames = fresh
    }
}
```

- [ ] **Step 2.4: Run the test to verify it passes**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/CoreMLCacheReadinessTests"
```
Expected: 3 tests pass.

- [ ] **Step 2.5: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/CoreMLCacheReadiness.swift" \
        "ios/KataGo iOS/KataGo iOSTests/CoreMLCacheReadinessTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "$(cat <<'EOF'
feat: add CoreMLCacheReadiness observable for picker checkmark

Smaller replacement for PrecompileScheduler.cachedReady. Maintains a
readyFileNames set, recomputed against the cache on every indexEvents
yield and on explicit update(forFileNames:) calls from the picker.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If Xcode did not auto-add the new files to the project, open the project once in Xcode to add them, or edit `project.pbxproj` to add the new file references. The next build step will catch this.

---

## Task 3: Inject `CoreMLCacheReadiness` into the SwiftUI environment alongside the scheduler

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`

We add the new readiness object as a sibling environment value. The old scheduler stays in place until Task 8. Both environments are injected simultaneously so downstream views can be migrated incrementally.

- [ ] **Step 3.1: Add the readiness `@State` and inject it**

Edit `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`.

Find:
```swift
    @State private var precompileScheduler: PrecompileScheduler = PrecompileScheduler(
        worker: { fileName in
            try await runPrecompileWorker(fileName: fileName)
        },
        cache: .shared,
        digestFor: makeProjectionDigestFor())
    @State private var engineLaunchStatus: EngineLaunchStatus
```

Add a second `@State` line directly after the `precompileScheduler` line:
```swift
    @State private var precompileScheduler: PrecompileScheduler = PrecompileScheduler(
        worker: { fileName in
            try await runPrecompileWorker(fileName: fileName)
        },
        cache: .shared,
        digestFor: makeProjectionDigestFor())
    @State private var cacheReadiness: CoreMLCacheReadiness = CoreMLCacheReadiness()
    @State private var engineLaunchStatus: EngineLaunchStatus
```

Find both scene-body `.environment(precompileScheduler)` lines (one in the `#if os(macOS)` branch and one in the `#else` branch). After each one, add `.environment(cacheReadiness)`.

After macOS branch (around line 86):
```swift
                ModelRunnerView()
                    .environment(precompileScheduler)
                    .environment(cacheReadiness)
                    .environment(engineLaunchStatus)
```

After non-macOS branch (around line 107):
```swift
                ModelRunnerView()
                    .environment(precompileScheduler)
                    .environment(cacheReadiness)
                    .environment(engineLaunchStatus)
```

- [ ] **Step 3.2: Start the readiness subscription in the scene `.task`**

In both scene `.task` blocks (macOS and non-macOS branches), add a `cacheReadiness.start()` call. Find the macOS scene `.task` (around lines 88–102):
```swift
                    .task {
                        let knownFileNames = Set(NeuralNetworkModel.allCases.map(\.fileName))
                            .union(autoWarmFileNames)
                        let digestFor = makeProjectionDigestFor()
                        await CoreMLModelCache.shared.start()
                        await precompileScheduler.hydrate(
                            from: .shared,
                            fileNames: knownFileNames,
                            digestFor: digestFor)
                        await precompileScheduler.subscribeToCacheEvents(
                            .shared,
                            fileNames: knownFileNames,
                            digestFor: digestFor)
                        await runCacheEmptySweep(scheduler: precompileScheduler)
                    }
```

Replace with:
```swift
                    .task {
                        let knownFileNames = Set(NeuralNetworkModel.allCases.map(\.fileName))
                            .union(autoWarmFileNames)
                        let digestFor = makeProjectionDigestFor()
                        await CoreMLModelCache.shared.start()
                        await cacheReadiness.start()
                        await cacheReadiness.update(
                            forFileNames: Array(knownFileNames))
                        await precompileScheduler.hydrate(
                            from: .shared,
                            fileNames: knownFileNames,
                            digestFor: digestFor)
                        await precompileScheduler.subscribeToCacheEvents(
                            .shared,
                            fileNames: knownFileNames,
                            digestFor: digestFor)
                        await runCacheEmptySweep(scheduler: precompileScheduler)
                    }
```

Make the identical change in the non-macOS branch.

- [ ] **Step 3.3: Build**

Run:
```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3.4: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift"
git commit -m "$(cat <<'EOF'
feat: inject CoreMLCacheReadiness alongside PrecompileScheduler

Adds the new environment value and starts its indexEvents
subscription in the scene .task. The scheduler stays wired for now;
downstream views will switch over in the next tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Switch `ModelPickerView` to `CoreMLCacheReadiness`

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/ModelPickerView.swift`

Changes:
1. `ModelDetailView` and `ModelPickerView` both swap `@Environment(PrecompileScheduler.self)` for `@Environment(CoreMLCacheReadiness.self)`.
2. `badge(for:)` collapses to "checkmark if cached, else nothing" — no spinner, no clock, no failure icon.
3. The `onDownloadComplete` hook stops calling `scheduler.scheduleForModel` (it still computes the hash, which is independent of precompile).
4. The picker's outer view gains a `.task(id:)` that calls `readiness.update(forFileNames:)` whenever the visible model list changes.
5. Previews swap `PrecompileScheduler` stubs for `CoreMLCacheReadiness()` instances.

- [ ] **Step 4.1: Swap environment in `ModelDetailView`**

Find (around line 63):
```swift
    @Environment(PrecompileScheduler.self) private var scheduler
```
Replace with:
```swift
    @Environment(CoreMLCacheReadiness.self) private var readiness
```

- [ ] **Step 4.2: Drop the `scheduleForModel` call in `onDownloadComplete`**

Find (around lines 151–161):
```swift
            // Wire the post-download seam: hash the file and schedule
            // a background precompile so the cache is warm before the
            // user picks the model.
            let capturedScheduler = scheduler
            let capturedFileName = model.fileName
            downloader.onDownloadComplete = { url in
                Task.detached(priority: .userInitiated) {
                    _ = try? await BinFileHasher.shared.identityForDownloadedFile(url)
                }
                await capturedScheduler.scheduleForModel(fileName: capturedFileName)
            }
```
Replace with:
```swift
            // Compute the downloaded file's identity hash so the
            // first engine launch that selects this model can
            // construct its cache key without re-hashing on the
            // hot path. No precompile is scheduled — the cache
            // populates lazily on first selection.
            downloader.onDownloadComplete = { url in
                Task.detached(priority: .userInitiated) {
                    _ = try? await BinFileHasher.shared.identityForDownloadedFile(url)
                }
            }
```

- [ ] **Step 4.3: Swap environment in `ModelPickerView`**

Find (around line 180):
```swift
    @Environment(PrecompileScheduler.self) private var scheduler
```
Replace with:
```swift
    @Environment(CoreMLCacheReadiness.self) private var readiness
```

- [ ] **Step 4.4: Collapse `badge(for:)` to checkmark-only**

Find (around lines 243–265):
```swift
    @ViewBuilder
    private func badge(for fileName: String) -> some View {
        let status = scheduler.status[fileName] ?? .idle
        switch status {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityLabel("Core ML cache ready")
        case .compiling:
            ProgressView().controlSize(.small)
                .accessibilityLabel("Compiling Core ML model")
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Waiting to compile Core ML model")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityLabel("Compile failed; will retry")
        case .idle:
            EmptyView()
        }
    }
```
Replace with:
```swift
    @ViewBuilder
    private func badge(for fileName: String) -> some View {
        if readiness.readyFileNames.contains(fileName) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Core ML cache ready")
        }
    }
```

- [ ] **Step 4.5: Add `.task(id:)` to keep `readiness` synced with the displayed model list**

Find the `NavigationStack { ... }` body in `ModelPickerView` (around lines 192–229). After the closing `.navigationTitle("Select a Model")` line, add a `.task(id:)` modifier that recomputes whenever `NeuralNetworkModel.allCases` produces a different visible-filename set.

Find:
```swift
            .navigationTitle("Select a Model")
        }
        .onOpenURL { url in
```
Replace with:
```swift
            .navigationTitle("Select a Model")
        }
        .task(id: visibleFileNamesHash) {
            await readiness.update(forFileNames: visibleFileNames)
        }
        .onOpenURL { url in
```

Add two computed-property helpers at the top of `ModelPickerView` (right under the `@Binding var crashedModelTitle` declaration, around line 189):

```swift
    /// Filenames of currently visible / downloaded models. Drives the
    /// readiness recompute via `.task(id:)`.
    private var visibleFileNames: [String] {
        NeuralNetworkModel.allCases.compactMap { model in
            guard model.visible,
                  model.downloadedURL != nil else { return nil }
            return model.fileName
        }
    }

    /// Stable identity for `.task(id:)`. SwiftUI restarts the task
    /// whenever this changes — i.e., when a model is downloaded or
    /// removed.
    private var visibleFileNamesHash: Int {
        var hasher = Hasher()
        for name in visibleFileNames.sorted() { hasher.combine(name) }
        return hasher.finalize()
    }
```

- [ ] **Step 4.6: Update the footer mount (drop the `scheduler:` argument)**

Find (around line 224–226):
```swift
                Section {
                    CoreMLCacheFooterView(scheduler: scheduler)
                }
```
Replace with:
```swift
                Section {
                    CoreMLCacheFooterView()
                }
```

The footer's signature change happens in Task 5. Between Task 4 and Task 5 the build will fail here — that is expected. Resolve the build failure by completing Task 5 immediately after Task 4. Do **not** commit Task 4 yet.

- [ ] **Step 4.7: Update the four `#Preview` blocks at the bottom of the file**

Find each `@State private var scheduler = PrecompileScheduler { _ in }` line (there are four). Replace each with:
```swift
        @State private var readiness = CoreMLCacheReadiness()
```

Find each `.environment(scheduler)` modifier (also four). Replace each with:
```swift
            .environment(readiness)
```

(Defer build/commit to after Task 5.)

---

## Task 5: Switch `CoreMLCacheFooterView` to subscribe to `indexEvents`

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/CoreMLCacheFooterView.swift`

Remove the scheduler property. On Clear, wipe the cache and refresh — no rewarm. Subscribe to `indexEvents` so the footer auto-updates after lazy compiles.

- [ ] **Step 5.1: Replace the file contents**

Overwrite `ios/KataGo iOS/KataGo iOS/CoreMLCacheFooterView.swift` with:

```swift
//
//  CoreMLCacheFooterView.swift
//  KataGo iOS
//

import SwiftUI
import KataGoInterface

struct CoreMLCacheFooterView: View {
    @State private var mainCount: Int = 0
    @State private var mainBytes: Int64 = 0
    @State private var auxCount: Int = 0
    @State private var auxBytes: Int64 = 0
    @State private var showConfirm = false
    @State private var clearing = false

    private var mainCap: Int { 4 }
    private var auxCap: Int { 4 }
    private var totalCount: Int { mainCount + auxCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Core ML Cache")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line(label: "Main", count: mainCount, cap: mainCap, bytes: mainBytes))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CoreMLCache.footerMainStats")
                    Text(line(label: "Human SL", count: auxCount, cap: auxCap, bytes: auxBytes))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CoreMLCache.footerAuxStats")
                }
                Spacer()
                if totalCount > 0 {
                    Button("Clear Cache") { showConfirm = true }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .disabled(clearing)
                }
            }
        }
        .padding(.vertical, 12)
        .task {
            // Initial render uses current on-disk state.
            await refresh()
            // Then auto-refresh whenever the cache mutates (lazy
            // compile inserts, eviction, clearAll).
            let stream = await CoreMLModelCache.shared.indexEvents
            for await _ in stream {
                await refresh()
            }
        }
        .confirmationDialog("Clear Core ML Cache?",
                            isPresented: $showConfirm,
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                Task { await clear() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(totalCount) compiled models will be removed. They will recompile on next use.")
        }
    }

    private func line(label: String, count: Int, cap: Int, bytes: Int64) -> String {
        let size = ByteCountFormatter().string(fromByteCount: bytes)
        return "\(label): \(count) of \(cap) · \(size)"
    }

    @MainActor private func refresh() async {
        // Ensure the on-disk index is loaded into memory before
        // reading stats. start() is idempotent.
        await CoreMLModelCache.shared.start()
        let stats = await CoreMLModelCache.shared.statsByCategory()
        mainCount = stats.main.count
        mainBytes = stats.main.totalBytes
        auxCount  = stats.auxiliary.count
        auxBytes  = stats.auxiliary.totalBytes
    }

    @MainActor private func clear() async {
        clearing = true
        defer { clearing = false }
        await CoreMLModelCache.shared.clearAll()
        // clearAll() emits an indexEvents tick, so the task-bound
        // subscription will refresh us. Call refresh() explicitly too
        // to guarantee the user sees 0/0 before the next event loop
        // iteration in case the subscription is mid-iteration.
        await refresh()
    }
}
```

- [ ] **Step 5.2: Build (combined Task 4 + Task 5)**

Run:
```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5.3: Run unit tests to confirm nothing regressed**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/CoreMLCacheReadinessTests" \
  -only-testing:"KataGo AnytimeTests/CoreMLCacheReadinessProjectionTests"
```
Expected: 6 tests pass.

- [ ] **Step 5.4: Commit Tasks 4 + 5 together**

```bash
git add "ios/KataGo iOS/KataGo iOS/ModelPickerView.swift" \
        "ios/KataGo iOS/KataGo iOS/CoreMLCacheFooterView.swift"
git commit -m "$(cat <<'EOF'
feat: drive picker checkmark + footer from cache directly

ModelPickerView consumes CoreMLCacheReadiness for the per-row green
checkmark (only state remaining); badge spinner and clock variants
are gone. Post-download hook no longer schedules a precompile.
CoreMLCacheFooterView subscribes to CoreMLModelCache.indexEvents and
clears without rewarming.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Drop `PrecompileScheduler` from `ModelRunnerView`

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/ModelRunnerView.swift`

Remove the bundle-version-aware rewarm, the scheduler environment, and the now-unused `lastWarmedVersion` storage.

- [ ] **Step 6.1: Remove scheduler env and rewarm**

Find (around line 25–26):
```swift
    @AppStorage("CoreMLCache.firstLaunchPrecompileVersion") private var lastWarmedVersion: String = ""
    @Environment(PrecompileScheduler.self) private var scheduler
```
Replace with: (delete both lines)

Find (around lines 43–51):
```swift
        .onAppear {
            // Bundle-version-aware re-warm: fire scheduleBuiltIn() when the
            // app has been updated since the last precompile warm.
            let current = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
            if BundleVersionWarmDecision.shouldRewarm(stored: lastWarmedVersion, current: current) {
                Task { await scheduler.scheduleBuiltIn() }
                lastWarmedVersion = current
            }

            // Guard against re-appearance (e.g. scene lifecycle transitions)
```
Replace with:
```swift
        .onAppear {
            // Guard against re-appearance (e.g. scene lifecycle transitions)
```

- [ ] **Step 6.2: Build**

Run:
```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`. (The unused `BundleVersionWarmDecision` symbol may still be referenced elsewhere — that's fine; we are not deleting it in this task. If the compiler complains about it being unused at file scope, it is module-level and won't.)

- [ ] **Step 6.3: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/ModelRunnerView.swift"
git commit -m "$(cat <<'EOF'
refactor: drop PrecompileScheduler env from ModelRunnerView

Removes the bundle-version-aware scheduleBuiltIn() rewarm. With no
background warmer, there is nothing to fire on app update — the
cache will populate lazily on first model selection instead.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Drop `PrecompileScheduler` from `BackendConfigSheet`

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/BackendConfigSheet.swift`

- [ ] **Step 7.1: Remove scheduler env and scheduling calls**

Find (around line 13):
```swift
    @Environment(PrecompileScheduler.self) private var scheduler
```
Delete that line.

Find (around lines 60–69):
```swift
            .onChange(of: backend) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.backend = newValue
                Task { await scheduler.scheduleForModel(fileName: model.fileName) }
            }
            .onChange(of: coremlBoardSize) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.coremlBoardSize = newValue
                Task { await scheduler.scheduleForModel(fileName: model.fileName) }
            }
```
Replace with:
```swift
            .onChange(of: backend) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.backend = newValue
            }
            .onChange(of: coremlBoardSize) { _, newValue in
                var settings = BackendSettings(model: model)
                settings.coremlBoardSize = newValue
            }
```

(The `var settings = BackendSettings(model: model); settings.<x> = newValue` pattern relies on `BackendSettings`'s mutating setter to persist via UserDefaults. Keep it — the persistence side effect is pre-existing and out of scope for this refactor.)

Find (around lines 74–77):
```swift
#Preview {
    BackendConfigSheet(model: NeuralNetworkModel.allCases[0])
        .environment(PrecompileScheduler { _ in })
}
```
Replace with:
```swift
#Preview {
    BackendConfigSheet(model: NeuralNetworkModel.allCases[0])
}
```

- [ ] **Step 7.2: Build**

Run:
```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7.3: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/BackendConfigSheet.swift"
git commit -m "$(cat <<'EOF'
refactor: drop PrecompileScheduler env from BackendConfigSheet

Backend setting changes no longer enqueue a precompile. The new
cache key will be hit (or compiled inline) on the next engine
launch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Delete the scheduler, sweep helpers, and `warm()`

**Files:**
- Delete: `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/AppLaunchPrecompileSweepTests.swift`
- Delete: `ios/KataGo iOS/KataGo iOSUITests/CacheEmptySweepFooterUITests.swift`
- Delete: `ios/KataGo iOS/KataGo iOSTests/RootViewBundleUpgradeTests.swift`
- Modify: `ios/KataGo iOS/KataGo iOS/EngineLifecycle.swift` — remove `BundleVersionWarmDecision` (orphaned after the ModelRunnerView rewarm is gone).
- Modify: `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift` — remove `runCacheEmptySweep`, `runPrecompileWorker`, `autoWarmFileNames` constant, scheduler `@State`, both `.environment(precompileScheduler)` lines, both `precompileScheduler.hydrate` + `subscribeToCacheEvents` + `runCacheEmptySweep` calls in the scene `.task`s, and `kPrecompileServerThreadIdx`.
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift` — remove `public func warm(...)` and update the `hasEntry` docstring.
- Modify: `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift` — remove `warmInstallsEntryAndReleasesPin`, `warmIsNoOpWhenSourceFileMissing`, and any other tests whose name starts with `warm`.

This is the largest task. Do it in slices, building between slices to keep error surface small.

- [ ] **Step 8.1: Trim `KataGo_iOSApp.swift` to remove scheduler wiring**

Open `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`. Replace its full contents with:

```swift
//
//  KataGo_iOSApp.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/7/2.
//

import CoreData
import SwiftData
import SwiftUI
import KataGoInterface

@main
struct KataGo_iOSApp: App {
    @State private var cacheReadiness: CoreMLCacheReadiness = CoreMLCacheReadiness()
    @State private var engineLaunchStatus: EngineLaunchStatus

    init() {
        // Create the EngineLaunchStatus object first so we can capture a
        // direct reference to it in the updater closure — at init() time
        // the @State wrapper backing store isn't yet reachable via `self`.
        let status = EngineLaunchStatus()
        _engineLaunchStatus = State(initialValue: status)

        #if false
            removeAllGameRecords()
        #endif

        #if false
            initializeCloutKitDevSchema(
                containerIdentifier: "iCloud.chinchangyang.KataGo-iOS.tw")
        #endif

        KataGoShortcuts.updateAppShortcutParameters()

        // Wire the bridge's downloaded-hasher seam so downloaded models
        // can compute their `sourceIdentity` for cache-key construction.
        registerDownloadedHasher(BinFileHasher.shared.identityForDownloadedFile)

        // Wire the engine-launch status updater seam so LoadingView can
        // show a secondary caption during cache-miss compiles.
        registerEngineLaunchStatusUpdater { phase in
            await MainActor.run { status.phase = phase }
        }
    }

    var scene: some Scene {
        #if os(macOS)
            Window("KataGo Anytime", id: "KataGo Anytime") {
                ModelRunnerView()
                    .environment(cacheReadiness)
                    .environment(engineLaunchStatus)
                    .task {
                        await CoreMLModelCache.shared.start()
                        await cacheReadiness.start()
                        let knownFileNames = NeuralNetworkModel.allCases.map(\.fileName)
                        await cacheReadiness.update(forFileNames: knownFileNames)
                    }
            }
        #else
            WindowGroup {
                ModelRunnerView()
                    .environment(cacheReadiness)
                    .environment(engineLaunchStatus)
                    .task {
                        await CoreMLModelCache.shared.start()
                        await cacheReadiness.start()
                        let knownFileNames = NeuralNetworkModel.allCases.map(\.fileName)
                        await cacheReadiness.update(forFileNames: knownFileNames)
                    }
            }
        #endif
    }

    var body: some Scene {
        scene.modelContainer(for: GameRecord.self)
    }

    private func removeAllGameRecords() {
        try! autoreleasepool {
            let container = try ModelContainer(for: GameRecord.self)
            let context = container.mainContext
            try context.delete(model: GameRecord.self)
            try context.delete(model: Config.self)
        }
    }

    private func initializeCloutKitDevSchema(containerIdentifier: String) {
        let config = ModelConfiguration()

        // Use an autorelease pool to make sure Swift deallocates the persistent
        // container before setting up the SwiftData stack.
        try! autoreleasepool {
            let desc = NSPersistentStoreDescription(url: config.url)
            let opts = NSPersistentCloudKitContainerOptions(
                containerIdentifier: containerIdentifier)
            desc.cloudKitContainerOptions = opts
            // Load the store synchronously so it completes before initializing the
            // CloudKit schema.
            desc.shouldAddStoreAsynchronously = false
            if let mom = NSManagedObjectModel.makeManagedObjectModel(for: [
                GameRecord.self
            ]) {
                let container = NSPersistentCloudKitContainer(
                    name: "GameRecords", managedObjectModel: mom)
                container.persistentStoreDescriptions = [desc]
                container.loadPersistentStores { _, err in
                    if let err {
                        fatalError(err.localizedDescription)
                    }
                }
                // Initialize the CloudKit schema after the store finishes loading.
                try container.initializeCloudKitSchema()
                // Remove and unload the store from the persistent container.
                if let store = container.persistentStoreCoordinator
                    .persistentStores.first
                {
                    try container.persistentStoreCoordinator.remove(store)
                }
            }
        }
    }
}
```

- [ ] **Step 8.2: Build (expected to still succeed: `PrecompileScheduler.swift` is still in the tree but no longer referenced)**

Run:
```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`. (`PrecompileScheduler` will be flagged as unused-but-public by some linters, ignore — it goes away in the next step.)

- [ ] **Step 8.3: Delete the scheduler source and its tests**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev"
git rm "ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift" \
       "ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift" \
       "ios/KataGo iOS/KataGo iOSTests/AppLaunchPrecompileSweepTests.swift" \
       "ios/KataGo iOS/KataGo iOSUITests/CacheEmptySweepFooterUITests.swift" \
       "ios/KataGo iOS/KataGo iOSTests/RootViewBundleUpgradeTests.swift"
```

If `git rm` fails because Xcode is open holding the project — close Xcode and retry. The `project.pbxproj` references to these files must also go; `git rm` plus a project-file edit (or one Xcode open) will sync it.

- [ ] **Step 8.3b: Remove `BundleVersionWarmDecision` from `EngineLifecycle.swift`**

Find the `BundleVersionWarmDecision` enum in `ios/KataGo iOS/KataGo iOS/EngineLifecycle.swift` (declaration starts around line 58). Delete the entire enum block (from `public enum BundleVersionWarmDecision {` through its closing `}`). If there is a leading docstring or a `// MARK:` divider attached to it, remove those too. Do not touch any other types in the file.

- [ ] **Step 8.4: Strip the matching references in `project.pbxproj`**

Run:
```bash
grep -n "PrecompileScheduler\|AppLaunchPrecompileSweep\|CacheEmptySweepFooter\|RootViewBundleUpgradeTests" \
  "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
```
Expected: any lines printed must be removed. The references live in `PBXBuildFile`, `PBXFileReference`, and `PBXGroup` sections. Either edit the file manually (search-and-delete each matched section by its parent `/* ... */` block) or open and close the project once in Xcode, which prunes broken references.

- [ ] **Step 8.5: Delete `warm()` from `CoreMLModelCache.swift`**

Find (around lines 815–840 in `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`):
```swift
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
Delete the entire function (including the preceding docstring if any). Leave the closing `}` of the class body intact.

- [ ] **Step 8.6: Update `hasEntry` docstring**

Find (around lines 286–289):
```swift
    /// Index-only lookup. Returns true iff a non-tombstoned entry exists
    /// for `digest` in memory. No I/O. Used by `PrecompileScheduler`'s
    /// `cachedReady` projection.
    public func hasEntry(digest: String) -> Bool {
```
Replace with:
```swift
    /// Index-only lookup. Returns true iff a non-tombstoned entry exists
    /// for `digest` in memory. No I/O. Used by `CoreMLCacheReadiness`
    /// to decide whether to show the picker's green checkmark.
    public func hasEntry(digest: String) -> Bool {
```

- [ ] **Step 8.7: Remove `warm`-named tests from `CoreMLModelCacheTests.swift`**

```bash
grep -n "@Test func warm" \
  "ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift"
```

For each printed line: open `CoreMLModelCacheTests.swift`, find the `@Test func warmXxx() ...` block, and delete from the `@Test` annotation through the closing `}` of the function body. The `CoreMLModelCacheTests.swift` file may have multiple `warm`-prefixed tests (e.g. `warmInstallsEntryAndReleasesPin`, `warmIsNoOpWhenSourceFileMissing`). Delete each one.

If the file imports any helper symbol only used by deleted tests (e.g. a temp-file helper), keep it — other tests may also use it.

- [ ] **Step 8.8: Build**

Run:
```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8.9: Run unit tests**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests"
```
Expected: all remaining unit tests pass. No `Precompile`-prefixed tests should be listed.

- [ ] **Step 8.10: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: delete PrecompileScheduler, warm(), and sweep helpers

Removes the background precompile system entirely. The on-disk cache
is now populated lazily by CoreMLComputeHandleLoader's miss callback
on first model load. CoreMLCacheReadiness drives the per-row green
checkmark; the footer subscribes directly to indexEvents.

Drops PrecompileScheduler.swift, AppLaunchPrecompileSweepTests.swift,
PrecompileSchedulerTests.swift, CacheEmptySweepFooterUITests.swift,
RootViewBundleUpgradeTests.swift, BundleVersionWarmDecision,
the warm() public method on CoreMLModelCache, the runCacheEmptySweep
and runPrecompileWorker helpers, autoWarmFileNames, the
firstLaunchPrecompileVersion AppStorage, and the bundle-version-
aware re-warm in ModelRunnerView.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Update `CoreMLCacheFooterUITests` for the no-rewarm post-Clear state

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOSUITests/CoreMLCacheFooterUITests.swift`

After this refactor, tapping **Clear** wipes the cache and the footer shows `Main: 0 of 4 · 0 B` and `Human SL: 0 of 4 · 0 B`. Any UI test that previously expected the footer to immediately repopulate (via `scheduleBuiltIn`) must change.

- [ ] **Step 9.1: Read the current expectations**

```bash
cat "ios/KataGo iOS/KataGo iOSUITests/CoreMLCacheFooterUITests.swift"
```

- [ ] **Step 9.2: Adjust assertions**

For each test in the file, identify which scenarios survive without precompile:
- **Scenarios to keep:** footer renders; counts reflect a model the user just loaded; tapping Clear with `totalCount > 0` is enabled; after Clear, the labels read `Main: 0 of 4 · 0 B` and `Human SL: 0 of 4 · 0 B`; the Clear button hides (because `totalCount == 0` gates the button).
- **Scenarios to delete:** anything that expected the footer to repopulate to `1 of 4` automatically after Clear.

For each surviving assertion that originally read e.g.:
```swift
let mainStats = app.staticTexts["CoreMLCache.footerMainStats"]
XCTAssertTrue(mainStats.waitForExistence(timeout: 18 * 60))
XCTAssertTrue(mainStats.label.contains("Main: 1 of 4"))
```
Change to:
```swift
let mainStats = app.staticTexts["CoreMLCache.footerMainStats"]
XCTAssertTrue(mainStats.waitForExistence(timeout: 30))
XCTAssertTrue(mainStats.label.contains("Main: 0 of 4"))
XCTAssertTrue(mainStats.label.contains("0 B")
              || mainStats.label.contains("Zero bytes"))
```
(`ByteCountFormatter` may render zero as `"0 B"` or `"Zero bytes"` depending on locale; allow either to keep the test locale-tolerant.)

If a test's whole purpose was to validate the rewarm pathway (filename like `testFooterRepopulatesAfterClear` or similar), delete that test function.

- [ ] **Step 9.3: Run the UI test target to confirm**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeUITests/CoreMLCacheFooterUITests"
```
Expected: all surviving tests pass. (Some UI tests are long; allow up to 10 minutes.)

- [ ] **Step 9.4: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOSUITests/CoreMLCacheFooterUITests.swift"
git commit -m "$(cat <<'EOF'
test: update CoreMLCacheFooterUITests for no-rewarm post-clear

After dropping PrecompileScheduler, tapping Clear leaves the footer
at 0 of 4 in both partitions until the user loads a model. Tests
that expected automatic repopulation are removed or updated to
assert the zero state.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Full platform build verification

**Goal:** Confirm clean builds for iOS Simulator, macOS, and visionOS Simulator (per `CLAUDE.md` build matrix), and that the unit-test suite still passes.

- [ ] **Step 10.1: iOS Simulator build**

```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 10.2: macOS build**

```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=macOS' \
  -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 10.3: visionOS Simulator build**

```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 10.4: Full unit test suite**

```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```
Expected: all tests pass. No leftover `Precompile`-prefixed tests should appear in the output.

- [ ] **Step 10.5: Manual UI smoke (cannot be automated here)**

Launch the iOS Simulator build of "KataGo Anytime". Verify by inspection:
- Model picker shows no per-row spinner or clock icons. Models the cache has compiled show a small green checkmark; uncompiled rows show no trailing icon.
- The footer reads `Core ML Cache` / `Main: N of 4 · <size>` / `Human SL: N of 4 · <size>`.
- Selecting an uncompiled model performs the compile during the engine-load LoadingView, then returns to the picker (later) showing a checkmark on that row.
- Tapping **Clear Cache** confirms, then the footer reads `Main: 0 of 4 · 0 B` and `Human SL: 0 of 4 · 0 B`. Picker row checkmarks all clear. No background activity follows.

If any of the above fails, file a follow-up before merging.

- [ ] **Step 10.6: No-op commit gate**

If steps 10.1–10.5 all succeed, no further changes are needed — the work is ready for review. Confirm `git status` is clean:

```bash
git status --short
```
Expected: empty output (all changes are committed).

---

## Self-Review (skip if you're the executor)

The author should verify before handing off:

1. **Spec coverage:**
   - "Remove precompile" — Tasks 6, 7, 8.
   - "Keep cache + footer + Clear" — Task 5.
   - "Keep green checkmark" — Tasks 2, 4.
   - "Live update via indexEvents" — Tasks 2 (`CoreMLCacheReadiness.start`), 5 (footer task body).
   - "Rename projection" — Task 1.
   - "Test updates" — Tasks 1, 2, 8, 9.
   - "Build for iOS/macOS/visionOS" — Task 10.
2. **Placeholder scan:** No "TBD", "fill in", or vague "handle edge cases". Each step has either the exact diff or the exact command.
3. **Type consistency:**
   - `CoreMLCacheReadiness` API: `init()`, `init(digestFor:hasEntry:)`, `update(forFileNames:)`, `start()`, `readyFileNames` — used consistently in Tasks 2, 3, 4, 8.
   - `CoreMLCacheReadinessProjection` keeps `makeProjectionResolver()` and `makeProjectionDigestFor()` — both used in `CoreMLCacheReadiness.init` (Task 2).
4. **Order safety:** Each modification step is followed by a build before commit. The deletion of `warm()` (Task 8) happens after both callsites (`runPrecompileWorker` in Task 8.1, and `CoreMLCacheFooterView.clear()` in Task 5) stop using it.
