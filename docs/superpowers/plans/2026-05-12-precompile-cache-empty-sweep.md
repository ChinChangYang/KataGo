# Precompile Cache-Empty Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-precompile the built-in network and the bundled human SL aux network at app launch whenever the Core ML cache lacks their entries — independent of the bundle-version rewarm trigger.

**Architecture:** Add a `runCacheEmptySweep` helper that runs in `KataGo_iOSApp.swift`'s `.task` blocks immediately after `scheduler.hydrate(...)`. For each of `{built-in, aux}`, if `scheduler.status[fileName] != .ready`, call `scheduler.scheduleForModel(fileName:)`. Extend `makeProjectionResolver` to map the aux fileName to bundle-resourced inputs derived from the built-in's `BackendSettings`. Extend `scheduleForModel`'s mpsGPU skip so the aux inherits its skip decision from the built-in's persisted backend key. Bundle-version rewarm in `ModelRunnerView.onAppear` stays unchanged.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`Testing` import), Xcode 16, `xcodebuild` from CLI.

**Spec:** `docs/superpowers/specs/2026-05-12-precompile-cache-empty-sweep-design.md`

**Conventions used by this codebase (read once):**
- Test target imports use `@testable import KataGo_Anytime` (space → underscore).
- Swift Testing style: `@Test func name() async throws { ... }`, `#expect(...)`.
- Per-test `UserDefaults` isolation pattern: `UserDefaults(suiteName: "test.\(UUID())")!` (see `PrecompileSchedulerTests.skipsWhenBackendIsMpsGpu`).
- Aux fileName constant: `"b18c384nbt-humanv0.bin.gz"` (also bundled as resource `b18c384nbt-humanv0.bin.gz`).
- Built-in fileName constant: `"default_model.bin.gz"`.

---

## File Structure

**Modify:**
- `ios/KataGo iOS/KataGo iOS/PrecompileProjection.swift` — add aux fileName special-case in `makeProjectionResolver`.
- `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift` — extend mpsGPU skip logic in `scheduleForModel` to inherit from built-in when fileName is the aux.
- `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift` — add `runCacheEmptySweep` free function; extend `knownFileNames` and call sweep in both `.task` branches (iOS/visionOS and macOS).
- `ios/KataGo iOS/KataGo iOSTests/PrecompileProjectionTests.swift` — add aux resolver test.
- `ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift` — add aux mpsGPU inheritance test.

**Create:**
- `ios/KataGo iOS/KataGo iOSTests/AppLaunchPrecompileSweepTests.swift` — sweep helper tests.

---

## Task 1: Aux projection in `makeProjectionResolver`

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/PrecompileProjection.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/PrecompileProjectionTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `KataGo iOSTests/PrecompileProjectionTests.swift` (inside the existing `struct PrecompileProjectionTests`):

```swift
    @Test func resolverReturnsInputsForHumanSLAux() async throws {
        let inputs = makeProjectionResolver()("b18c384nbt-humanv0.bin.gz")
        #expect(inputs != nil)
        guard let inputs else { return }
        #expect(inputs.sourcePath.hasSuffix("b18c384nbt-humanv0.bin.gz"))
        #expect(inputs.nnXLen > 0)
        #expect(inputs.nnYLen > 0)
        #expect(inputs.nnXLen == inputs.nnYLen)
        #expect(inputs.useFP16 == true)
        #expect(inputs.maxBatchSize == 1)

        // Aux projection must mirror the built-in's settings: same nnLen
        // and same requireExactNNLen so the cache key matches what the
        // engine launch will compute when the built-in is selected.
        let builtIn = makeProjectionResolver()("default_model.bin.gz")
        #expect(builtIn != nil)
        if let builtIn {
            #expect(inputs.nnXLen == builtIn.nnXLen)
            #expect(inputs.nnYLen == builtIn.nnYLen)
            #expect(inputs.requireExactNNLen == builtIn.requireExactNNLen)
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/PrecompileProjectionTests/resolverReturnsInputsForHumanSLAux"
```
Expected: FAIL with `inputs != nil` failed expectation (the current resolver returns `nil` for any fileName not in `NeuralNetworkModel.allCases`).

- [ ] **Step 3: Implement the resolver extension**

In `ios/KataGo iOS/KataGo iOS/PrecompileProjection.swift`, replace the body of `makeProjectionResolver()`:

```swift
func makeProjectionResolver() -> ProjectionResolver {
    return { fileName in
        // Human SL aux is bundled and shares the built-in's backend
        // settings (the engine loads them together with the same nnLen
        // and same fp16/maxBatchSize). Project its digest against the
        // built-in's settings so the precompiled aux is reused verbatim
        // when the user selects the built-in.
        if fileName == "b18c384nbt-humanv0.bin.gz" {
            guard let bundlePath = Bundle.main.path(
                    forResource: "b18c384nbt-humanv0",
                    ofType: "bin.gz"),
                  let builtIn = NeuralNetworkModel.builtInModel
            else { return nil }
            let settings = BackendSettings(model: builtIn)
            let nnLen = Int32(settings.effectiveMaxBoardLength)
            return ProjectionInputs(
                sourcePath: bundlePath,
                nnXLen: nnLen,
                nnYLen: nnLen,
                requireExactNNLen: settings.requireExactNNLen,
                useFP16: true,
                maxBatchSize: 1)
        }

        guard let model = NeuralNetworkModel.allCases.first(where: { $0.fileName == fileName })
        else { return nil }

        let sourcePath: String
        if model.builtIn {
            guard let bundlePath = Bundle.main.path(
                forResource: "default_model",
                ofType: "bin.gz")
            else { return nil }
            sourcePath = bundlePath
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
            nnXLen: nnLen,
            nnYLen: nnLen,
            requireExactNNLen: settings.requireExactNNLen,
            useFP16: true,
            maxBatchSize: 1)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/PrecompileProjectionTests"
```
Expected: All `PrecompileProjectionTests` cases PASS (`resolverReturnsNilForUnknownFileName`, `resolverReturnsInputsForBuiltInModel`, and the new `resolverReturnsInputsForHumanSLAux`).

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/PrecompileProjection.swift" \
        "ios/KataGo iOS/KataGo iOSTests/PrecompileProjectionTests.swift"
git commit -m "feat: project human SL aux digest against built-in's settings"
```

---

## Task 2: Aux mpsGPU skip inherits from built-in

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift:73-78`
- Test: `ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `KataGo iOSTests/PrecompileSchedulerTests.swift` (inside `struct PrecompileSchedulerTests`):

```swift
    @Test func skipsAuxWhenBuiltInBackendIsMpsGpu() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        defaults.set("mpsGPU", forKey: "backend_default_model.bin.gz")

        actor Counter { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()
        let scheduler = await PrecompileScheduler(defaults: defaults) { _ in
            await counter.inc()
        }
        await scheduler.scheduleForModel(fileName: "b18c384nbt-humanv0.bin.gz")

        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.get() == 0)
    }

    @Test func runsAuxWhenBuiltInBackendIsCoreml() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        defaults.set("coremlNE", forKey: "backend_default_model.bin.gz")

        actor Counter { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()
        let scheduler = await PrecompileScheduler(defaults: defaults) { _ in
            await counter.inc()
        }
        await scheduler.scheduleForModel(fileName: "b18c384nbt-humanv0.bin.gz")

        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.get() == 1)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/PrecompileSchedulerTests/skipsAuxWhenBuiltInBackendIsMpsGpu" \
  -only-testing:"KataGo AnytimeTests/PrecompileSchedulerTests/runsAuxWhenBuiltInBackendIsCoreml"
```
Expected: `skipsAuxWhenBuiltInBackendIsMpsGpu` FAILS (`counter.get() == 0` expectation fails — the current code reads `backend_b18c384nbt-humanv0.bin.gz`, which is unset, so the worker runs). `runsAuxWhenBuiltInBackendIsCoreml` may PASS already (it's the no-skip case) — that's fine, it's a regression guard.

- [ ] **Step 3: Implement the skip-key resolution**

In `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift`, replace the first lines of `scheduleForModel(fileName:)`:

```swift
    public func scheduleForModel(fileName: String) async {
        // Aux's projection borrows the built-in's BackendSettings, so its
        // mpsGPU-vs-CoreML skip decision must also follow the built-in.
        // The aux's own `backend_<aux>` key is never written by any UI
        // surface, so reading it would always be nil and the aux would
        // never be skipped — which would diverge from the projection.
        let backendKey: String = (fileName == "b18c384nbt-humanv0.bin.gz")
            ? "backend_default_model.bin.gz"
            : "backend_\(fileName)"
        if defaults.string(forKey: backendKey) == "mpsGPU" {
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
                self.ephemeral[fileName] = nil
                await self.refreshCachedReady(for: fileName)
            } catch {
                let summary = (error as NSError).localizedDescription
                log.error("precompile.failed model=\(fileName, privacy: .public) error=\(String(describing: error), privacy: .public)")
                self.ephemeral[fileName] = .failed(message: summary)
            }
            self.inFlight.remove(fileName)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/PrecompileSchedulerTests"
```
Expected: All `PrecompileSchedulerTests` cases PASS, including both new aux cases and the existing built-in mpsGPU / coremlNE cases.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift" \
        "ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift"
git commit -m "feat: human SL aux inherits built-in's mpsGPU skip decision"
```

---

## Task 3: `runCacheEmptySweep` helper

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/AppLaunchPrecompileSweepTests.swift`

- [ ] **Step 1: Write the failing tests (file)**

Create `ios/KataGo iOS/KataGo iOSTests/AppLaunchPrecompileSweepTests.swift` with:

```swift
import Foundation
import Testing
import KataGoInterface
@testable import KataGo_Anytime

struct AppLaunchPrecompileSweepTests {

    // Shared fixture: scheduler whose worker only counts invocations
    // per fileName. Backend keys are left unset in the per-test
    // UserDefaults suite so the mpsGPU skip never fires.
    private func makeFixture() async -> (PrecompileScheduler, FileNameCounter) {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        let counter = FileNameCounter()
        let scheduler = await PrecompileScheduler(defaults: defaults) { fileName in
            await counter.inc(fileName)
        }
        return (scheduler, counter)
    }

    actor FileNameCounter {
        private var counts: [String: Int] = [:]
        func inc(_ fileName: String) { counts[fileName, default: 0] += 1 }
        func count(_ fileName: String) -> Int { counts[fileName] ?? 0 }
        func total() -> Int { counts.values.reduce(0, +) }
    }

    @MainActor
    @Test func sweepsBothWhenCacheEmpty() async throws {
        let (scheduler, counter) = await makeFixture()
        // status is empty -> both targets are not .ready.

        await runCacheEmptySweep(scheduler: scheduler)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await counter.count("default_model.bin.gz") == 1)
        #expect(await counter.count("b18c384nbt-humanv0.bin.gz") == 1)
        #expect(await counter.total() == 2)
    }

    @MainActor
    @Test func sweepsOnlyAuxWhenBuiltInReady() async throws {
        let (scheduler, counter) = await makeFixture()
        scheduler._setCachedReadyForTests(["default_model.bin.gz"])

        await runCacheEmptySweep(scheduler: scheduler)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await counter.count("default_model.bin.gz") == 0)
        #expect(await counter.count("b18c384nbt-humanv0.bin.gz") == 1)
    }

    @MainActor
    @Test func sweepsNothingWhenBothReady() async throws {
        let (scheduler, counter) = await makeFixture()
        scheduler._setCachedReadyForTests([
            "default_model.bin.gz",
            "b18c384nbt-humanv0.bin.gz"
        ])

        await runCacheEmptySweep(scheduler: scheduler)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await counter.total() == 0)
    }

    @MainActor
    @Test func sweepDoesNotReScheduleQueuedOrCompiling() async throws {
        let (scheduler, counter) = await makeFixture()
        scheduler._setEphemeralForTests([
            "default_model.bin.gz": .compiling,
            "b18c384nbt-humanv0.bin.gz": .queued
        ])

        await runCacheEmptySweep(scheduler: scheduler)
        try await Task.sleep(for: .milliseconds(50))

        // Neither target is .ready, but both are in-flight. The sweep
        // calls scheduleForModel anyway; scheduleForModel's inFlight
        // dedup is what blocks the worker from being invoked again.
        // What we assert here is the user-visible outcome: the worker
        // is not run a second time.
        #expect(await counter.count("default_model.bin.gz") == 0)
        #expect(await counter.count("b18c384nbt-humanv0.bin.gz") == 0)
    }
}
```

- [ ] **Step 2: Add the new test file to the Xcode test target**

The test bundle must include the new file. Open `KataGo Anytime.xcodeproj` in Xcode and add `KataGo iOSTests/AppLaunchPrecompileSweepTests.swift` to the `KataGo AnytimeTests` target (drag the file into the test group, or use **File → Add Files to "KataGo Anytime"…** with the test target checked). Save the project.

If working without the Xcode UI, edit `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` to register the file under the test target (mirror an existing test file's `PBXFileReference` + `PBXBuildFile` + `PBXSourcesBuildPhase` entries, e.g. `PrecompileSchedulerTests.swift`).

- [ ] **Step 3: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/AppLaunchPrecompileSweepTests"
```
Expected: BUILD FAILURE — `runCacheEmptySweep` is undefined.

- [ ] **Step 4: Implement the helper**

In `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`, add this free function near the top of the file (after the imports, before `@main struct KataGo_iOSApp`):

```swift
/// File names auto-warmed at app launch when their cache entry is
/// missing. Built-in + bundled human SL aux only — downloaded mains
/// are handled by `ModelPickerView.downloader.onDownloadComplete`.
private let autoWarmFileNames: [String] = [
    "default_model.bin.gz",
    "b18c384nbt-humanv0.bin.gz"
]

/// Cache-empty sweep. For each auto-warm target whose status is not
/// `.ready`, enqueue a precompile. Runs after `scheduler.hydrate(...)`
/// in the app's scene `.task`. `scheduleForModel`'s `inFlight` dedup
/// makes repeated calls (e.g. scene reactivation) cheap, and the
/// bundle-version rewarm in `ModelRunnerView.onAppear` cooperates via
/// the same dedup path.
@MainActor
func runCacheEmptySweep(scheduler: PrecompileScheduler) async {
    for fileName in autoWarmFileNames {
        if scheduler.status[fileName] != .ready {
            await scheduler.scheduleForModel(fileName: fileName)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/AppLaunchPrecompileSweepTests"
```
Expected: All four `AppLaunchPrecompileSweepTests` cases PASS.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift" \
        "ios/KataGo iOS/KataGo iOSTests/AppLaunchPrecompileSweepTests.swift" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat: add runCacheEmptySweep helper for built-in + aux"
```

---

## Task 4: Wire sweep into app launch + extend `knownFileNames`

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift:60-90`

- [ ] **Step 1: Update both `.task` branches**

In `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`, replace the macOS `.task` block (around lines 59–71):

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

And the iOS/visionOS `.task` block (around lines 78–90):

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

(`autoWarmFileNames` was declared as a `Set` of two — `.union(autoWarmFileNames)` here uses it as a `Sequence`, which works for `[String]`. The set union dedupes the `default_model.bin.gz` entry that `allCases` already provides.)

- [ ] **Step 2: Build for all three platforms**

Run:
```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug
```
Expected: BUILD SUCCEEDED.

```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=macOS' \
  -configuration Debug
```
Expected: BUILD SUCCEEDED.

```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full test suite**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" \
  -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```
Expected: All tests PASS, including the seven new/extended tests from Tasks 1–3 and all pre-existing tests (`RootViewBundleUpgradeTests`, `PrecompileSchedulerTests`, `PrecompileProjectionTests`, `CoreMLModelCacheTests`, etc.).

- [ ] **Step 4: Manual smoke check (iOS Simulator, fresh install)**

This step verifies the end-to-end behavior the spec describes. Do not skip — the unit tests cover the helper but not the integration with `hydrate` + cache events.

1. Delete the app from the simulator: `xcrun simctl uninstall booted chinchangyang.KataGo-iOS.tw` (substitute your bundle id if different — check `Info.plist`).
2. Run the app from Xcode on the iPhone 17 simulator.
3. While the picker is on screen, watch the Console for `category: engine.coreml.cache`. Expected: a `precompile.failed` line absent; an `urlForKey` miss + commit for both `default_model.bin.gz` and `b18c384nbt-humanv0.bin.gz`.
4. Open the picker's footer. After a few seconds (compile completes), expect `Main: 1 of 4` and `Human SL: 1 of 4`.
5. Without launching the engine, force-quit the app and relaunch. Expect no new compile (cache hits) and the built-in row's checkmark visible immediately after `hydrate`.

If any check above fails, capture the log line and stop — do not proceed to the commit step.

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift"
git commit -m "feat: sweep cache at app launch for built-in + human SL aux"
```

---

## Self-review notes

- **Spec coverage:** Section 1 → Task 4. Section 2 → Task 1. Section 3 → Task 4 (knownFileNames union). Section 4 → Tasks 3 + 4. Section 5 → Task 2. Section 6 tests → Tasks 1 (test 6/7 collapsed to one positive case; nil branch is defensive-only and not tested), 2 (test 5 + a coremlNE regression guard), 3 (tests 1–4).
- **Placeholder scan:** no TBD / TODO / handle-edge-cases language. Every code step ships the full code.
- **Type consistency:** `runCacheEmptySweep(scheduler:)` signature is identical in Task 3 (definition + test calls) and Task 4 (call sites). `autoWarmFileNames` is the same identifier across Tasks 3 and 4. The aux fileName string `"b18c384nbt-humanv0.bin.gz"` is the same across Tasks 1, 2, 3 and in production (`CoreMLModelCache.swift:873`, `KataGoHelper.swift:55`).
