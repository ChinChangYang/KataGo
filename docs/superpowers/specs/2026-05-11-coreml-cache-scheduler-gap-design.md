# Core ML Cache / Precompile Scheduler — Unifying Truth

Date: 2026-05-11
Status: Design approved, pending spec review

## Problem

The model picker has two sources of truth that can disagree:

- `PrecompileScheduler.status[fileName]` — in-memory, drives the row checkmark via `ModelPickerView.badge(for:)` at `ModelPickerView.swift:244-265`.
- `CoreMLModelCache` on-disk index — drives the footer "N of M" via `CoreMLCacheFooterView.swift`.

Two concrete gaps follow:

1. **Badge under-reports cache (cold-launch false negative).** `scheduler.status` is empty on every cold launch. Even when the cache holds compiled entries for several models, only rows whose fileName the scheduler later observes (download finish, BackendConfigSheet open, `scheduleBuiltIn`) get a checkmark. The footer correctly shows "N of M"; the rows do not match.

2. **Badge over-reports compile (false positive).** `runPrecompileWorker` at `KataGo_iOSApp.swift:124` is a 1-second sleep. It flips status to `.ready` without ever calling `urlForKey`. A checkmark today means "the scheduler waited 1s," not "this file is in the cache." The placeholder is a flagged follow-up in the comment but has not been replaced.

3. **Compounded symptom: the failing UI test.** `CoreMLCacheFooterUITests.testFooterCountIncrementsAfterDownloadedModelLaunch` launches the built-in engine, then a downloaded model, and expects the footer count to increase. Because the placeholder worker doesn't warm anything and the downloaded-model launch path is the only thing that actually writes to the cache, the test exercises whether the cache write actually happens. Today the count fails to advance.

## Goal

Make `CoreMLModelCache` the single source of truth for whether a model is cache-ready. `PrecompileScheduler` retains its role as the SwiftUI-facing orchestrator (queued / compiling / failed lifecycle), but `.ready` becomes a *derived* projection from the cache index.

The badge promises strict semantics: a checkmark means a cache entry exists for the digest the *next engine launch would compute* for this model under its currently persisted backend settings.

Observability (trustworthy badge), cleanup (single source of truth), and the failing UI test all resolve once truth is unified.

## Non-Goals

- Not unifying `CoreMLModelCache` and `PrecompileScheduler` into one type. The framework/app split is intentional and `CoreMLModelCache` should not pull in SwiftUI/Observation.
- Not changing what the footer reads from. Both views converge on the cache index but the footer's path stays as it is.
- Not benchmarking precompile warm vs. cold compile times.
- Not adding an end-to-end UI test for eviction-triggered badge updates.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ KataGo iOS (app target, @MainActor, @Observable)            │
│                                                             │
│   ModelPickerView ─────► PrecompileScheduler                │
│                            ├── ephemeral[fileName]          │
│                            │     (.queued/.compiling/       │
│                            │      .failed)                  │
│                            └── cachedReady: Set<String>     │
│                                  (projection of cache)      │
│                                                             │
│   KataGo_iOSApp                                             │
│     └─ runPrecompileWorker → cache.warm(...)                │
└─────────────────────────────────────────────────────────────┘
            │                                  ▲
            ▼                                  │ index tick
┌─────────────────────────────────────────────────────────────┐
│ KataGoInterface (framework, actor)                          │
│                                                             │
│   CoreMLModelCache                                          │
│     ├─ cacheKey(forSourcePath:...)        (existing)        │
│     ├─ urlForKey(digest:...)              (existing)        │
│     ├─ projectedDigest(forFileName:settings:)  ◄── new      │
│     ├─ hasEntry(digest:)                       ◄── new      │
│     ├─ warm(forFileName:settings:missCallback:) ◄── new     │
│     └─ indexEvents: AsyncStream<Void>          ◄── new      │
└─────────────────────────────────────────────────────────────┘
```

`scheduler.status[fileName]` resolves as: ephemeral state if present, else `.ready` if `cachedReady` contains the fileName, else `.idle`. The badge view at `ModelPickerView.swift:244-265` does not change.

## Components

### `CoreMLModelCache` (`ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`)

New surface:

All new entry points use primitive parameters so the framework does not need to import app types. The app target converts its `BackendSettings` to these primitives at the call site (same pattern the existing `cacheKey(forSourcePath:...)` uses with a `downloadedHasher` closure).

- `func projectedDigest(forSourcePath sourcePath: String, nnXLen: Int32, nnYLen: Int32, requireExactNNLen: Bool, useFP16: Bool, maxBatchSize: Int, downloadedHasher: DownloadedHasher) async throws -> String?` — wraps the existing `cacheKey(forSourcePath:...)` and returns just the digest. Returns `nil` if the source file is not present on disk. Throws on hasher failures.
- `func hasEntry(digest: String) async -> Bool` — index-only lookup against the in-memory `entries` map. No compile, no I/O beyond the existing index that `start()` loads.
- `func warm(forSourcePath sourcePath: String, nnXLen: Int32, nnYLen: Int32, requireExactNNLen: Bool, useFP16: Bool, maxBatchSize: Int, sourceFileName: String?, downloadedHasher: DownloadedHasher, missCallback: MissCallback) async throws` — computes the projected digest, calls `urlForKey(digest:priority:sourceFileName:missCallback:)`, then releases the pin immediately. The on-disk entry survives; the in-memory pin is dropped because `warm` has no consumer.
- `var indexEvents: AsyncStream<Void>` — emits a value whenever the index mutates (`clearAll`, `invalidate`, eviction, install completion). Consumers use this to refresh derived state.

### `PrecompileScheduler` (`ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift`)

Backing state splits in two:

```swift
private var ephemeral: [String: PrecompileStatus] = [:]  // .queued/.compiling/.failed only
private var cachedReady: Set<String> = []                 // projection of cache index
```

`status[fileName]` becomes a computed property:

```swift
public var status: [String: PrecompileStatus] {
    var merged: [String: PrecompileStatus] = [:]
    for fileName in cachedReady { merged[fileName] = .ready }
    for (fileName, state) in ephemeral { merged[fileName] = state }
    return merged
}
```

The scheduler stays in the app target, so it *can* construct `BackendSettings` directly. A `ProjectionResolver` closure type translates a fileName into the primitives `CoreMLModelCache` needs:

```swift
public typealias ProjectionInputs = (
    sourcePath: String,
    nnXLen: Int32, nnYLen: Int32,
    requireExactNNLen: Bool, useFP16: Bool,
    maxBatchSize: Int)

public typealias ProjectionResolver = (_ fileName: String) -> ProjectionInputs?
```

The resolver returns `nil` when the file isn't downloaded. Production wires the resolver in `KataGo_iOSApp` to read `BackendSettings(model:)` + the same `effectiveMaxBoardLength` / fp16 logic used at engine launch. Tests inject a stub.

Lifecycle:

- `func hydrate(from cache: CoreMLModelCache, resolver: @escaping ProjectionResolver, downloadedHasher: CoreMLModelCache.DownloadedHasher) async` — iterates `NeuralNetworkModel.allCases` that are downloaded, runs the resolver, computes each projected digest, asks `cache.hasEntry(digest:)`, updates `cachedReady`. Each fileName wrapped in `do/catch`; one failure does not abort the loop.
- `func subscribeToCacheEvents(_ cache: CoreMLModelCache, resolver: @escaping ProjectionResolver, downloadedHasher: CoreMLModelCache.DownloadedHasher)` — spawns a task that consumes `cache.indexEvents` and re-runs `hydrate`.
- `scheduleForModel(fileName:)` — unchanged outer behavior. On worker success it no longer writes `.ready` directly; it clears the ephemeral entry and refreshes `cachedReady` for that fileName via the same projection + `hasEntry` path.
- `cancelAllPending()` — unchanged. After it, `cachedReady` remains; only ephemeral entries clear.

The `PrecompileStatus` enum and the SwiftUI binding contract are unchanged.

### Worker (`ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift:124`)

`runPrecompileWorker(fileName:)` stops sleeping. Pseudocode:

```swift
@MainActor
private func runPrecompileWorker(fileName: String) async throws {
    guard let model = NeuralNetworkModel.allCases.first(where: { $0.fileName == fileName }),
          let inputs = projectionInputs(for: model) else { return }
    try await CoreMLModelCache.shared.warm(
        forSourcePath: inputs.sourcePath,
        nnXLen: inputs.nnXLen, nnYLen: inputs.nnYLen,
        requireExactNNLen: inputs.requireExactNNLen,
        useFP16: inputs.useFP16,
        maxBatchSize: inputs.maxBatchSize,
        sourceFileName: fileName,
        downloadedHasher: BinFileHasher.shared.identityForDownloadedFile,
        missCallback: makePrecompileMissCallback(inputs))
}
```

`makePrecompileMissCallback` is the same `convertOnCooperativePool` shim that `loadCoreMLHandle` already uses at `CoreMLComputeHandleLoader.swift:69-76`, either factored out to be reused or exposed via a precompile-only entry point. One converter, two call paths.

### App init (`ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`)

After `precompileScheduler` is constructed and the existing bridge wiring runs, define a single `ProjectionResolver` (closes over the `BackendSettings(model:)` constructor + `effectiveMaxBoardLength` derivation) and a single hasher reference, then:

```swift
Task {
    await precompileScheduler.hydrate(
        from: .shared,
        resolver: projectionResolver,
        downloadedHasher: BinFileHasher.shared.identityForDownloadedFile)
    precompileScheduler.subscribeToCacheEvents(
        .shared,
        resolver: projectionResolver,
        downloadedHasher: BinFileHasher.shared.identityForDownloadedFile)
}
```

Non-blocking; the picker shows hydrated checkmarks once the task completes (typically <100ms — index reads, not compiles).

### Cache-clear (`ios/KataGo iOS/KataGo iOS/CoreMLCacheFooterView.swift:78-85`)

After `cache.clearAll()`:

```swift
scheduler.cancelAllPending()
await scheduler.hydrate(
    from: .shared,
    resolver: projectionResolver,
    downloadedHasher: BinFileHasher.shared.identityForDownloadedFile)
```

This empties `cachedReady` (clearAll removes all entries → hasEntry returns false → cachedReady set is empty), and the badge vanishes in lockstep with the footer count dropping to zero. The subsequent `scheduleBuiltIn()` re-enters the queued → compiling → ready flow.

### `ModelPickerView`

No changes. `badge(for:)` still reads `scheduler.status[fileName]`.

## Data Flows

### Cold launch with populated on-disk cache

1. App init constructs `precompileScheduler`.
2. Scene appears; picker renders with all rows in `.idle`.
3. `hydrate` task runs in background, computes projected digests for downloaded models, calls `hasEntry`.
4. `cachedReady` fills; `@Observable` flips affected rows to `.ready`.
5. Footer and badge agree.

### Download finish

1. `ModelDetailView.onDownloadComplete` at `ModelPickerView.swift:156-161` hashes the file and calls `scheduler.scheduleForModel(fileName:)`.
2. Scheduler writes `ephemeral[fileName] = .queued`, then `.compiling`, runs worker.
3. Worker calls `cache.warm` → projects digest → `urlForKey` with the converter as miss callback.
4. On success, scheduler clears `ephemeral[fileName]` and refreshes `cachedReady` membership for that file (and `cache.indexEvents` also fires, triggering a hydrate that confirms the same).
5. Badge transitions queued → compiling → ready. Footer count increments by one. **This is the path the failing UI test exercises.**

### Settings change in `BackendConfigSheet`

1. User toggles fp16 (or other backend setting).
2. `BackendConfigSheet.swift:63,68` calls `scheduleForModel(fileName:)`.
3. Scheduler writes `ephemeral[fileName] = .queued`, which overrides any stale `.ready` from `cachedReady` (the merged `status` puts ephemeral on top). The row immediately shows queued / compiling — the user never sees a stale ready under the new digest.
4. Worker warms the new digest. Old digest stays in cache (unrelated).
5. On success, scheduler refreshes `cachedReady` using the *new* projected digest. Ephemeral clears. Badge returns to `.ready` under new digest. Footer count may increase by one (a second entry for the same source file).

### Engine launch — hit

1. `loadCoreMLHandle` computes `cacheKey`, calls `urlForKey`.
2. `lookupOnDisk` returns the entry; existing `printError("CoreMLCache hit: …")` line we added (commit `a9d41c3a`) logs to stderr.
3. No badge change; row was already ready.

### Engine launch — miss

1. `urlForKey` runs `joinOrInstall`; converter produces an `.mlpackage`; index updates; `indexEvents` ticks.
2. During the compile, the row's badge may already say `.ready` (projection matched the digest now being installed) or `.idle` (not yet hydrated). Either way we do not flip the row to `.compiling` mid-launch; `LoadingView` / `EngineLaunchStatus` already carries the in-launch caption.
3. After install, `indexEvents` fires → scheduler re-hydrates → `cachedReady` confirms the row.

### Cache clear

1. `CoreMLCacheFooterView.clear` calls `cache.clearAll()`.
2. Scheduler cancels pending, hydrates (empty cache → empty `cachedReady`).
3. All checkmarks vanish; footer drops to 0.
4. `scheduleBuiltIn()` re-runs worker; built-in row transitions through queued → compiling → ready.

### Eviction

1. LRU eviction in `CoreMLModelCache` (existing) removes an entry; `indexEvents` ticks.
2. Scheduler's subscription re-hydrates; the evicted file's `cachedReady` membership drops.
3. Badge updates without user interaction.

## Error Handling

- **Projected digest, file not downloaded** → `nil`; treated as `.idle`. Correct: the row's next action is Download.
- **Projected digest, hasher throws** → logged via the `printError` helper in `CoreMLModelCache.swift`; treated as `.idle`. Hash failure on a downloaded file is exceptional; surfacing as `.failed` would be misleading because the worker hasn't been invoked.
- **`downloadedHasher` not injected** → only reachable in tests / misordered init. Production wires it at `KataGo_iOSApp.swift:41`. Log and treat as `.idle`.
- **Hydration failures** — wrap each fileName in `do/catch`; one file's failure doesn't abort the rest. Hydration is a background task; slow hashes do not delay the picker.
- **Worker failures** — `cache.warm` throws → scheduler writes `.failed(message:)` into ephemeral (existing behavior at `PrecompileScheduler.swift:58-62`). Retry on next `scheduleForModel`.
- **Corrupt entry during warm** — surface failure once; `loadCoreMLHandle`'s one-shot corrupt-hit retry handles the same digest cleanly on next engine launch. Warm stays simple.
- **`indexEvents` ends unexpectedly** — log; subsequent mutations won't refresh until next `hydrate`. Low impact (eviction is rare).
- **Settings change mid-warm** — `inFlight` dedup drops the second `scheduleForModel`. After the first warm finishes the projected digest reflects new settings; row re-evaluates to `.idle`. BackendConfigSheet's re-enqueue then warms the new digest.

## Testing

### Unit (Swift Testing, `CoreMLModelCacheTests`)

- `projectedDigest_returnsNilForMissingFile` — file absent → `nil`, no throw.
- `hasEntry_indexLookupOnly` — populated index returns true without compile; absent digest returns false.
- `warm_releasesPinAfterSuccess` — after warm returns, an immediate `clearAll` succeeds (no live pins).
- `warm_propagatesMissCallbackErrors` — throwing miss callback bubbles out, no entry installed.
- `indexEvents_tickOnInstallClearInvalidate` — three ticks observed across `urlForKey` miss install, `invalidate`, `clearAll`.

### Unit (`PrecompileSchedulerTests`)

- `hydrate_populatesCachedReadyFromStub` — stub cache with two entries; hydrate marks both ready.
- `worker_successPromotesToCachedReady` — ephemeral cleared, `cachedReady` contains fileName.
- `worker_failureSetsEphemeralFailed` — ephemeral retains `.failed`, `cachedReady` unchanged.
- `cacheEventTick_refreshesCachedReady` — emitting a tick on the stream triggers re-hydration.
- `cancelAllPending_preservesCachedReady` — only ephemeral clears.

### UI (XCUITest, `CoreMLCacheFooterUITests`)

- `testFooterCountIncrementsAfterDownloadedModelLaunch` — existing test becomes the regression for Gap A+B together. No code change to the test.
- Optional: `BadgeReflectsCacheOnColdLaunch` — launch app, launch built-in, quit, kill app, relaunch — assert built-in row shows the checkmark before any interaction.

### Manual smoke

- Cold launch with prior-run cache → built-in row checkmark appears within one second.
- Download Lionffen → queued → compiling → ready; footer increments.
- Toggle fp16 in BackendConfigSheet → row drops to idle/compiling, returns to ready; footer count increases by one.
- Clear Cache → all checkmarks vanish; built-in re-warms immediately.

## Open Questions / Decisions Recorded

- **Badge during in-launch miss:** Stays as-is (idle or ready). `LoadingView` / `EngineLaunchStatus` carries the compile caption. (Decided.)
- **Eviction notification mechanism:** `AsyncStream<Void>` emitted by `CoreMLModelCache` on every index mutation. Scheduler subscribes once at startup. (Decided.)
- **Projection inputs match runtime:** `BackendSettings(model:)` exposes `effectiveMaxBoardLength` and the backend choice (which drives fp16). `maxBatchSize` and `requireExactNNLen` must match what `loadCoreMLHandle` uses at launch — sourced from `ModelRunnerView.swift:111` (engine-launch site) and the `MetalComputeContext` it builds. Implementation must verify the resolver produces identical inputs to the launch path; a unit test asserting `projectedDigest == cacheKey(...).digest` for matching inputs is the smoke check.

## Files Touched

- `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift` — add `projectedDigest`, `hasEntry`, `warm`, `indexEvents`.
- `ios/KataGo iOS/KataGoInterface/CoreMLComputeHandleLoader.swift` — expose `convertOnCooperativePool` (or extract to a shared module) so `warm`'s miss callback reuses it.
- `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift` — split state, add `hydrate` / `subscribeToCacheEvents`, computed `status`.
- `ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift` — replace placeholder worker, wire hydrate + subscribe.
- `ios/KataGo iOS/KataGo iOS/CoreMLCacheFooterView.swift` — call `hydrate` after `clearAll`.
- New tests in `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift` and (new file) `PrecompileSchedulerTests.swift`.
