# Precompile Cache-Empty Sweep — Design

**Status:** Approved by user 2026-05-12
**Owner:** Chin-Chang Yang
**Related specs:** `2026-05-09-coreml-cache-design.md`, `2026-05-11-coreml-cache-scheduler-gap-design.md`

## Problem

When the Core ML cache is empty (fresh install, after a `Clear Cache`, or after an interrupted/failed previous precompile), neither the built-in network (`default_model.bin.gz`) nor the bundled human SL aux network (`b18c384nbt-humanv0.bin.gz`) gets compiled in the background. The actual compile only happens reactively when the user starts a model, at which point the engine boot path performs the conversion.

The current sole background trigger lives in `ModelRunnerView.onAppear`:

```swift
if BundleVersionWarmDecision.shouldRewarm(stored: lastWarmedVersion,
                                          current: current) {
    Task { await scheduler.scheduleBuiltIn() }
    lastWarmedVersion = current
}
```

Two problems:

1. **`lastWarmedVersion` is written eagerly** (before the detached `Task` completes). If the precompile is interrupted or fails, the cache stays empty but the AppStorage key matches the current bundle — `shouldRewarm` returns false on the next launch, so the warm never re-fires.
2. **The aux network is never auto-scheduled** at app launch. `scheduleBuiltIn()` only covers `default_model.bin.gz`.

## Expected behavior

When the cache is missing an entry for the built-in network or the human SL aux network, the scheduler should precompile it in the background at app launch. Bundle-version-based rewarming for the built-in is preserved (belt-and-suspenders).

## Design

### Section 1: Where the new logic lives

- **App-launch flow** (`KataGo_iOSApp.swift` `.task` blocks for iOS / macOS / visionOS) gains a *cache-empty sweep* that fires after `await scheduler.hydrate(...)` completes.
- **`ModelRunnerView.onAppear`'s bundle-version-based `scheduleBuiltIn()` is kept unchanged.** This is the "version changed since last warm" branch; the new sweep is the "cache is missing the entry" branch. They cooperate via `scheduleForModel`'s existing `inFlight` dedup.
- **`PrecompileScheduler` gets no new public methods.** The sweep just calls `scheduleForModel(fileName:)` per missing file.
- The app reads readiness via the existing public `status` map (`status[fileName] == .ready`).

### Section 2: Aux projection — extend `makeProjectionResolver`

`PrecompileProjection.swift`'s `makeProjectionResolver()` currently walks `NeuralNetworkModel.allCases`. The aux model is not in that list (it's not a user-selectable main), so we add a fileName special case before the `allCases` lookup:

```swift
func makeProjectionResolver() -> ProjectionResolver {
    return { fileName in
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
                nnXLen: nnLen, nnYLen: nnLen,
                requireExactNNLen: settings.requireExactNNLen,
                useFP16: true, maxBatchSize: 1)
        }
        // existing allCases path unchanged
        ...
    }
}
```

**Why built-in's settings?** The aux is loaded by the C++ engine alongside the main model, sharing `nnXLen/nnYLen/requireExactNNLen`. At app launch no main model is selected yet; the built-in is the most-common pairing and the only model guaranteed to be available without a download. Projecting against built-in's settings means the precompiled aux is reused verbatim when the user picks the built-in.

**Implication if user picks a different main with different `nnLen`:** the aux will need a separate compile at engine boot. That's an acceptable cost for keeping the cache-empty sweep simple — the alternative (precompile aux for every possible main's settings) explodes the cache.

### Section 3: Track aux in hydrate / subscription

In `KataGo_iOSApp.swift`, extend the `knownFileNames` set in both `.task` blocks:

```swift
let knownFileNames = Set(NeuralNetworkModel.allCases.map(\.fileName))
    .union(["b18c384nbt-humanv0.bin.gz"])
```

This makes `hydrate(...)` and `subscribeToCacheEvents(...)` cover the aux, so:

- `status[aux] == .ready` after hydrate iff the aux's projected digest is in the cache index.
- After a `cache.indexEvents` tick (e.g., the engine boot compiled aux on first launch), the aux's `cachedReady` bit is updated.

No UI surface change: there is no picker row for aux, so the badge view is untouched. The sweep just needs accurate `status[aux]`.

### Section 4: The cache-empty sweep

Add a free function in `KataGo_iOSApp.swift` (so both `.task` branches and the new test target call the same code path):

```swift
@MainActor
func runCacheEmptySweep(scheduler: PrecompileScheduler) async {
    let warmTargets = ["default_model.bin.gz", "b18c384nbt-humanv0.bin.gz"]
    for fileName in warmTargets {
        if scheduler.status[fileName] != .ready {
            await scheduler.scheduleForModel(fileName: fileName)
        }
    }
}
```

Call it from each `.task` immediately after the `hydrate(...) + subscribeToCacheEvents(...)` pair:

```swift
await runCacheEmptySweep(scheduler: precompileScheduler)
```

Notes:

- Runs once per scene `.task` lifecycle (same cadence as `hydrate`). SwiftUI re-fires `.task` on scene reactivation, which is acceptable — the dedup below makes repeated calls cheap.
- `scheduleForModel`'s `inFlight` set dedupes against an already-running compile, so race with `ModelRunnerView.onAppear`'s bundle-version rewarm is harmless.
- Status check uses `!= .ready` (not `== .idle`) so that a transient `.queued` / `.compiling` / `.failed` state already produced by the bundle-version rewarm path is not double-scheduled. (`.failed` is the deliberate retry-gate; the next user-driven trigger surfaces it.)
- mpsGPU skip is enforced inside `scheduleForModel` — see Section 5.

### Section 5: mpsGPU skip semantics for aux

`scheduleForModel` currently skips when `defaults.string(forKey: "backend_\(fileName)") == "mpsGPU"`. For aux, the key `backend_b18c384nbt-humanv0.bin.gz` is never written by any UI surface (no backend picker for aux), so the existing check would never fire — but the aux's projection borrows the built-in's settings, so its mpsGPU-vs-CoreML choice should track the built-in.

**Change:** inside `scheduleForModel`, when `fileName == "b18c384nbt-humanv0.bin.gz"`, consult `backend_default_model.bin.gz` for the skip decision:

```swift
let backendKey: String
if fileName == "b18c384nbt-humanv0.bin.gz" {
    backendKey = "backend_default_model.bin.gz"
} else {
    backendKey = "backend_\(fileName)"
}
if defaults.string(forKey: backendKey) == "mpsGPU" {
    log.info("skip-precompile reason=mpsGPU fileName=\(fileName, privacy: .public)")
    return
}
```

The aux's skip policy now matches its projection policy: both inherit from the built-in.

### Section 6: Tests

#### New file: `KataGo iOSTests/AppLaunchPrecompileSweepTests.swift`

Tests call `runCacheEmptySweep(scheduler:)` directly against a `PrecompileScheduler` seeded with the desired `status` map via the existing `_setEphemeralForTests` / `_setCachedReadyForTests` debug seams. They verify:

1. **Empty cache → both scheduled.** Fake scheduler reports `status[*] = .idle`; sweep calls `scheduleForModel` for both targets exactly once.
2. **Built-in ready, aux missing → only aux scheduled.** `status[builtIn] = .ready`, `status[aux] = .idle` → one call, fileName == aux.
3. **Both ready → no schedules.** Sweep is a no-op.
4. **Queued / compiling does not re-schedule.** `status[aux] = .compiling` → sweep does not call `scheduleForModel(aux)`.

#### Extend `PrecompileSchedulerTests`

5. **`scheduleForModel(aux)` skipped when `backend_default_model.bin.gz == "mpsGPU"`.** Mirror the existing mpsGPU-skip test, with aux fileName + built-in's backend key in defaults.

#### New tests in `PrecompileProjectionTests` (or extend existing)

6. **`makeProjectionResolver()(aux)` returns non-nil with built-in's `nnLen` and `requireExactNNLen`.** Verifies the Section-2 extension without touching the cache.
7. **`makeProjectionResolver()(aux)` returns nil when `NeuralNetworkModel.builtInModel` is nil.** Edge case; defensive guard.

Existing tests stay:

- `RootViewBundleUpgradeTests` — bundle-version rewarm path is unchanged.
- `PrecompileSchedulerTests` — existing dedup / cancelAllPending / cacheEventTick tests are unaffected.

## Non-goals

- **Downloaded main models are not swept.** Per agreement, only built-in + aux. A downloaded model's precompile remains tied to its existing `downloader.onDownloadComplete` hook in `ModelPickerView`.
- **No UI surface for aux readiness.** No new badge row, no new footer line. `status[aux]` is consumed only by the sweep's gating logic.
- **No removal of bundle-version rewarm.** The two triggers cooperate.
- **No change to `cache.warm` / converter / cache-key semantics.** The sweep reuses the existing precompile worker.

## Risks / open points

- **Aux compile races with engine boot.** On a first launch, the sweep fires aux precompile in background; concurrently the user picks a model and the engine boot also compiles aux. The cache's `urlForKey` already handles concurrent misses via its per-digest `inFlight` map (see `CoreMLModelCache`); the second arriver waits on the first. No new risk introduced.
- **macOS / visionOS code duplication.** `KataGo_iOSApp.swift` has parallel `.task` blocks per platform. The sweep should be factored into a single helper called from both branches to avoid drift.
