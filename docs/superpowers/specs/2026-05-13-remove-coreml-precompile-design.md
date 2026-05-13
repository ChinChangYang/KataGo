# Remove Core ML Precompile, Keep Lazy Cache, Footer, and Cached-Row Checkmark

**Date:** 2026-05-13
**Status:** Draft
**Supersedes (in current behavior, not as history):**
- `2026-05-09-coreml-cache-design.md`
- `2026-05-11-coreml-cache-scheduler-gap-design.md`
- `2026-05-12-precompile-cache-empty-sweep-design.md`

## Goal

Simplify the Core ML cache subsystem in KataGo Anytime by removing the background **precompile** system, while keeping:

- The on-disk Core ML cache (populated lazily on first model use).
- The picker **footer** with per-partition counts, size, and a **Clear** button.
- The per-row **green checkmark** for models that are currently cached on disk.

What goes away:

- `PrecompileScheduler` and all its scheduling/queueing/worker code.
- Launch-time and scene-phase precompile sweeps.
- The post-download and bundle-version-bump rewarm hooks.
- The transient row states (spinner during compile, clock when queued). Without background work to indicate, only the steady-state "cached / not cached" signal remains.

After this change, the cache fills lazily on first selection of each model. The green checkmark appears on a row as soon as the cache contains an entry for that model under the current backend settings; it updates live by subscribing to `CoreMLModelCache.indexEvents`.

## Non-Goals

- Changing the on-disk cache format, digest scheme, partition budgets, or LRU eviction.
- Changing `CoreMLComputeHandleLoader` or the C++ bridge (`katagocoreml_convert_to_temp`).
- Adding new user settings to expose cache behavior.
- Migration: the app is unreleased; existing on-disk caches need no migration.

## Architecture

### Components that stay (unchanged)

| Component | Role |
|---|---|
| `CoreMLModelCache` | Disk cache of compiled `.mlmodelc/` keyed by digest; LRU per partition. Exposes `urlForKey`, `statsByCategory()`, `indexEvents: AsyncStream<Void>`. |
| `CoreMLComputeHandleLoader` | Resolves a `MLModel` for the engine; on cache miss, compiles inline via `missCallback`. |
| `convertOnCooperativePool` / C++ bridge | Performs the actual `.bin.gz` → `.mlmodelc` conversion. |

### Components that stay (modified)

| Component | Change |
|---|---|
| `CoreMLModelCache` | Drop `warm()` (used only by the removed scheduler) and any helpers only the scheduler consumed. Keep everything else listed above. Update docstrings that mention `PrecompileScheduler` / `cachedReady`. |
| `CoreMLCacheFooterView` | Drop `scheduler` property. Subscribe to `CoreMLModelCache.shared.indexEvents` directly. On Clear: wipe cache and refresh — **do not** rewarm. |

### Components added (small, replace scheduler's UI role)

| New file | Role |
|---|---|
| `ios/KataGo iOS/KataGo iOS/CoreMLCacheReadinessProjection.swift` | Renamed from `PrecompileProjection.swift`. Pure logic: given a filename and current backend settings, derive the cache key the loader would use, then ask the cache if that entry exists on disk. No scheduling, no state. |
| `ios/KataGo iOS/KataGo iOS/CoreMLCacheReadiness.swift` | `@Observable` class exposing `readyFileNames: Set<String>` and `func update(forFileNames: [String]) async`. The picker calls `update(forFileNames:)` whenever its model list changes (initial `.task`, downloads completing, deletions). Internally the object owns a `.task` that subscribes to `CoreMLModelCache.shared.indexEvents` and re-runs the projection against the **last-known** filename list on every yield. Injected via `@Environment`. Replaces the scheduler's role of feeding the per-row badge. |

### Components removed entirely

- `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift`
- `runCacheEmptySweep`, `runPrecompileWorker` (functions in `KataGo_iOSApp.swift`)
- The `@State precompileScheduler` declaration, `.environment(scheduler)` injection, and the two scenePhase hooks invoking `runCacheEmptySweep`.
- The post-download `scheduleForModel` hook in `ModelPickerView`.
- The `scheduleBuiltIn()` re-warm in `ModelRunnerView` on bundle-version change.
- The two `scheduleForModel` calls in `BackendConfigSheet`.
- The `.compiling` (spinner) and `.queued` (clock) variants of the per-row badge. Only the `.ready` (green checkmark) state survives.

## Data Flow After the Change

```
User taps a model in picker
  → ContentView / engine init
    → CoreMLComputeHandleLoader.loadCoreMLHandle()
      → CoreMLModelCache.urlForKey(digest, fileName, missCallback)
        → on hit:  return cached .mlmodelc URL          (fast)
        → on miss: missCallback runs convertOnCooperativePool()
                   → C++ bridge → .mlmodelc written
                   → index.json updated → indexEvents.yield()
      → MLModel(contentsOf: ...)

CoreMLCacheReadiness (mounted at app level via .environment)
  ModelPickerView.onAppear / on-list-change → readiness.update(forFileNames: currentList)
  readiness internal task {
    for await _ in CoreMLModelCache.shared.indexEvents {
      readyFileNames = projection.computeReady(forFileNames: lastKnownList)
    }
  }

ModelPickerView row
  if readiness.readyFileNames.contains(fileName) {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
  } // else: no trailing icon

CoreMLCacheFooterView (mounted in picker)
  task { for await _ in CoreMLModelCache.shared.indexEvents { refresh() } }
  → refresh() calls statsByCategory(), updates labels
  → Clear button: CoreMLModelCache.shared.clear() → refresh() (no rewarm)
```

There is no scheduler in this diagram. Two independent subscribers (`CoreMLCacheReadiness` for row badges and `CoreMLCacheFooterView` for footer stats) listen to the same `indexEvents` stream.

## File-Level Changes

### Deleted

- `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift`
- `ios/KataGo iOS/KataGo iOSTests/AppLaunchPrecompileSweepTests.swift`
- `ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift`
- `ios/KataGo iOS/KataGo iOSUITests/CacheEmptySweepFooterUITests.swift`

### Renamed (same logic, new name, scheduler references removed)

- `ios/KataGo iOS/KataGo iOS/PrecompileProjection.swift` → `CoreMLCacheReadinessProjection.swift`
- `ios/KataGo iOS/KataGo iOSTests/PrecompileProjectionTests.swift` → `CoreMLCacheReadinessProjectionTests.swift`
  - Drop any test that asserts integration with `PrecompileScheduler.hydrate(...)`. Keep tests that exercise the projection logic in isolation.

### Added

- `ios/KataGo iOS/KataGo iOS/CoreMLCacheReadiness.swift`
- `ios/KataGo iOS/KataGo iOSTests/CoreMLCacheReadinessTests.swift`
  - One test: recompute fires after `indexEvents` yields, and `readyFileNames` reflects the projection result.

### Modified

- **`ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`**
  - Remove `runCacheEmptySweep(scheduler:)` and `runPrecompileWorker(fileName:)`.
  - Remove the `@State precompileScheduler` declaration and `.environment(precompileScheduler)` injection.
  - Remove the two scenePhase hooks that call `runCacheEmptySweep`.
  - Add a `@State` instance of `CoreMLCacheReadiness` and inject via `.environment(...)` at the same scope previously used for the scheduler.

- **`ios/KataGo iOS/KataGo iOS/ModelPickerView.swift`**
  - Replace `@Environment(PrecompileScheduler.self) private var scheduler` with `@Environment(CoreMLCacheReadiness.self) private var readiness` in all views in this file.
  - Replace the existing `badge(for fileName:)` switch with: if `readiness.readyFileNames.contains(fileName)` show `checkmark.circle.fill` in green; otherwise render nothing. No spinner. No clock.
  - Call `await readiness.update(forFileNames: currentModelFileNames)` from a `.task(id: modelListHash)` on the picker's outer view so the readiness object always tracks the displayed list.
  - Remove the `onDownloadComplete` seam that captured the scheduler and called `scheduleForModel`. (Download completion still triggers the picker's existing model-list refresh, which re-fires the `.task(id:)` above and recomputes readiness — no separate hook needed.)
  - Keep the `CoreMLCacheFooterView` mount in the picker; pass no scheduler.
  - Update SwiftUI previews: drop scheduler stubs; inject a `CoreMLCacheReadiness` configured with an empty or seeded `readyFileNames` for the relevant preview variants.

- **`ios/KataGo iOS/KataGo iOS/ModelRunnerView.swift`**
  - Remove `@Environment(PrecompileScheduler.self)`.
  - Remove the bundle-version-aware `Task { await scheduler.scheduleBuiltIn() }` re-warm.

- **`ios/KataGo iOS/KataGo iOS/BackendConfigSheet.swift`**
  - Remove `@Environment(PrecompileScheduler.self)`.
  - Remove both `scheduleForModel` calls in the backend-setting change handlers.
  - Remove `.environment(PrecompileScheduler { _ in })` from previews. Inject a `CoreMLCacheReadiness` if the preview otherwise crashes on the `@Environment` lookup; otherwise no replacement needed.

- **`ios/KataGo iOS/KataGo iOS/CoreMLCacheFooterView.swift`**
  - Remove `let scheduler: PrecompileScheduler` property and any callsite arguments that pass it.
  - In `clear()`: call `CoreMLModelCache.shared.clear()` then `refresh()`. Do **not** call `scheduleBuiltIn()`.
  - Use a `.task` modifier to subscribe to `CoreMLModelCache.shared.indexEvents` and call `refresh()` on each yield. Call `refresh()` once before entering the loop for the initial render.

- **`ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`**
  - Remove `warm()` and any helpers used only by the scheduler.
  - Keep `urlForKey`, `statsByCategory()`, `indexEvents`, persistence, eviction.
  - Update docstrings to remove `PrecompileScheduler` / `cachedReady` references.

- **`ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`**
  - Remove tests that exercise `warm()` or scheduler-projection helpers that no longer exist.
  - Keep tests for put/get, eviction per partition, persistence round-trip, `statsByCategory`, and `indexEvents` emission.

- **`ios/KataGo iOS/KataGo iOSUITests/CoreMLCacheFooterUITests.swift`**
  - Update post-Clear expectation from `Main: 1 of 4 · ...` (which relied on `scheduleBuiltIn` rewarm) to `Main: 0 of 4 · 0 B` (or whatever zero-size string the existing formatter produces).
  - Keep the pre-Clear assertion that the footer displays the expected counts after the user has loaded a model at least once. If a test only validated the rewarm pathway, delete that test.

### Unchanged (verified during implementation)

- `CoreMLCacheKeyTests.swift`
- `CoreMLComputeHandleLoader.swift`
- C++ bridge and `convertOnCooperativePool` infrastructure
- Other backends (Metal, Eigen) and their selection paths

## UI Specification

### Picker rows

Each row renders the model's name, source, any selection state already present, and **one optional trailing icon**:

- If `CoreMLCacheReadiness.readyFileNames` contains the row's filename: `checkmark.circle.fill` in green.
- Otherwise: no trailing icon. No spinner. No clock.

The checkmark updates live as the cache changes (via the `indexEvents` subscription).

### Footer

Two lines, vertically stacked, with a trailing **Clear** button (existing layout preserved):

```
Main:     N of 4 · <human-readable size>
Human SL: N of 4 · <human-readable size>            [Clear]
```

- `N` reflects current on-disk entry count in each partition.
- Size is the sum of bytes for entries in that partition, rendered with the existing formatter.
- The footer updates whenever `CoreMLModelCache.shared.indexEvents` yields (insert, evict, clear).
- Tapping **Clear** wipes both partitions on disk and immediately refreshes the footer (showing 0 / 0 B). The cache repopulates naturally as the user loads models.

## Error Handling

- If the lazy compile fails during model load (existing `CoreMLComputeHandleLoader` retry path), the user sees the existing error surface in `ContentView`. No new error paths.
- `CoreMLCacheReadiness.recompute()` swallows projection errors and treats them as "not ready" for that filename. Recompute is best-effort UI state; failures do not block engine operation.

## Performance / Tradeoffs

- **First selection of an uncompiled model:** visible compile delay during model load (typically a few seconds on modern Apple Silicon). On subsequent loads, the cache hits and load is sub-second. The row's green checkmark appears as soon as the compile completes.
- **App launch / scene foregrounding:** zero precompile work. Faster cold start.
- **Cache stays bounded.** LRU eviction at 4 entries per partition still applies.
- **`CoreMLCacheReadiness` recompute cost:** O(picker filenames) per `indexEvents` yield. Picker filenames are bounded (well under 20); each projection lookup is a digest computation plus a hash-map probe. Negligible.

## Testing Strategy

- **Unit (`CoreMLModelCacheTests`)** — put/get, eviction per partition, `statsByCategory`, `indexEvents` fires on insert and clear.
- **Unit (`CoreMLCacheReadinessProjectionTests`)** — projection returns true iff the digest derived from filename + current backend settings is present on disk; false otherwise.
- **Unit (`CoreMLCacheReadinessTests`)** — `readyFileNames` updates after `indexEvents` yields; reflects projection results.
- **UI (`CoreMLCacheFooterUITests`)** — footer renders, reflects counts after a lazy compile, resets to 0 / 0 B after Clear with no rewarm.
- **Build** — must succeed for iOS Simulator, macOS, and visionOS Simulator (per CLAUDE.md build matrix).

## Rollout

Single PR. No feature flag (app is unreleased; no users to gate against).

## Open Items

None.
