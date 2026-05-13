# Remove Core ML Precompile, Keep Lazy Cache and Footer

**Date:** 2026-05-13
**Status:** Draft
**Supersedes (in current behavior, not as history):**
- `2026-05-09-coreml-cache-design.md`
- `2026-05-11-coreml-cache-scheduler-gap-design.md`
- `2026-05-12-precompile-cache-empty-sweep-design.md`

## Goal

Simplify the Core ML cache subsystem in KataGo Anytime by removing the background **precompile** system and its per-model UI surface. Keep the on-disk Core ML cache (it is populated lazily on first use), and keep the picker **footer** showing cache stats with a Clear button.

After this change:

- Model picker rows show **no badges** (no green checkmark, no spinner, no clock icon).
- Model picker still shows a **footer**: `Main: N of 4 · <size>` and `Human SL: N of 4 · <size>` plus a **Clear** button.
- The footer **live-updates** when a lazy compile populates the cache (it subscribes to `CoreMLModelCache.indexEvents`).
- No work runs at launch or scene-phase transitions to "warm" Core ML.
- First selection of a never-compiled model performs the compile inline during model load (one-time cost). Subsequent loads hit the disk cache.

## Non-Goals

- Changing the on-disk cache format, digest scheme, partition budgets, or LRU eviction.
- Changing `CoreMLComputeHandleLoader` or the C++ bridge (`katagocoreml_convert_to_temp`).
- Adding new user settings to expose cache behavior.
- Migration: the app is unreleased; existing on-disk caches need no migration.

## Architecture

### Components that stay

| Component | Role | Change |
|---|---|---|
| `CoreMLModelCache` | Disk cache of compiled `.mlmodelc/` keyed by digest; LRU per partition | Drop `warm()` and any helpers only used by the scheduler; **keep** `urlForKey`, `statsByCategory()`, `indexEvents: AsyncStream<Void>`, eviction, persistence |
| `CoreMLComputeHandleLoader` | Resolves a `MLModel` for the engine; on cache miss, compiles inline via `missCallback` | Unchanged |
| `convertOnCooperativePool` / C++ bridge | Performs the actual `.bin.gz` → `.mlmodelc` conversion | Unchanged |
| `CoreMLCacheFooterView` | Picker footer with stats + Clear button | Drop the `scheduler` dependency; subscribe to `CoreMLModelCache.shared.indexEvents` directly; on Clear, wipe cache and refresh — do **not** rewarm |

### Components removed entirely

- `PrecompileScheduler` — the precompile worker queue and `cachedReady` projection.
- `PrecompileProjection` — the projection helper used only by `PrecompileScheduler.hydrate(...)`.
- `runCacheEmptySweep` and `runPrecompileWorker` in `KataGo_iOSApp.swift`.
- The `@State` scheduler, its `.environment(...)` injection, and the scenePhase hooks that invoke `runCacheEmptySweep`.
- The post-download `scheduleForModel` hook in `ModelPickerView`.
- The `scheduleBuiltIn()` re-warm in `ModelRunnerView` triggered on bundle version change.
- The two `scheduleForModel` calls in `BackendConfigSheet`.
- The per-row `badge(for:)` function in `ModelPickerView` and all icon variants (`.ready`, `.compiling`, `.queued`).

## Data Flow After the Change

```
User taps a model in picker
  → ContentView / engine init
    → CoreMLComputeHandleLoader.loadCoreMLHandle()
      → CoreMLModelCache.urlForKey(digest, fileName, missCallback)
        → on hit:  return cached .mlmodelc URL          (fast)
        → on miss: missCallback runs convertOnCooperativePool()
                   → C++ bridge → .mlmodelc written under <root>/models/<digest>/<epoch>.mlmodelc/
                   → index.json updated → indexEvents.yield()
      → MLModel(contentsOf: ...)

CoreMLCacheFooterView (mounted in picker)
  task { for await _ in CoreMLModelCache.shared.indexEvents { refresh() } }
  → refresh() calls statsByCategory(), updates "Main: N of 4 · size" labels
  → Clear button: CoreMLModelCache.shared.clear() → refresh() (no rewarm)
```

There is no scheduler in this diagram, and no badge state on picker rows.

## File-Level Changes

### Deleted

- `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift`
- `ios/KataGo iOS/KataGo iOS/PrecompileProjection.swift`
- `ios/KataGo iOS/KataGo iOSTests/AppLaunchPrecompileSweepTests.swift`
- `ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift`
- `ios/KataGo iOS/KataGo iOSTests/PrecompileProjectionTests.swift`
- `ios/KataGo iOS/KataGo iOSUITests/CacheEmptySweepFooterUITests.swift`

### Modified

- **`ios/KataGo iOS/KataGo iOS/KataGo_iOSApp.swift`**
  - Remove `runCacheEmptySweep(scheduler:)`.
  - Remove `runPrecompileWorker(fileName:)`.
  - Remove the `@State precompileScheduler` declaration.
  - Remove `.environment(precompileScheduler)` from the scene body.
  - Remove the two scenePhase hooks that call `runCacheEmptySweep`.
  - Net: no remaining references to `PrecompileScheduler`.

- **`ios/KataGo iOS/KataGo iOS/ModelPickerView.swift`**
  - Remove `@Environment(PrecompileScheduler.self) private var scheduler` from all views in the file.
  - Remove `badge(for fileName:)` function and its callsites on each row.
  - Remove the `onDownloadComplete` seam that captures the scheduler and calls `scheduleForModel`.
  - **Keep** the `CoreMLCacheFooterView` mount in the picker; pass no scheduler (see footer change).
  - Update SwiftUI previews: drop `@State private var scheduler` and `.environment(scheduler)`.

- **`ios/KataGo iOS/KataGo iOS/ModelRunnerView.swift`**
  - Remove `@Environment(PrecompileScheduler.self)`.
  - Remove the bundle-version-aware `Task { await scheduler.scheduleBuiltIn() }` re-warm.

- **`ios/KataGo iOS/KataGo iOS/BackendConfigSheet.swift`**
  - Remove `@Environment(PrecompileScheduler.self)`.
  - Remove both `scheduleForModel` calls in change handlers.
  - Remove `.environment(PrecompileScheduler { _ in })` from previews.

- **`ios/KataGo iOS/KataGo iOS/CoreMLCacheFooterView.swift`**
  - Remove the `let scheduler: PrecompileScheduler` property.
  - In `clear()`: call `CoreMLModelCache.shared.clear()` then `refresh()`. Do **not** call `scheduleBuiltIn()`.
  - Replace the existing refresh trigger with a `.task` that subscribes to `CoreMLModelCache.shared.indexEvents` and calls `refresh()` on each yield. Also call `refresh()` once on appear (initial population) before entering the subscription loop.

- **`ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`**
  - Remove `warm()` and any helpers used only by the scheduler (e.g., the in-memory readiness projection feeding `cachedReady`).
  - **Keep** `urlForKey`, `statsByCategory()`, `indexEvents`, the persistence layer, and eviction.
  - Update docstrings that reference `PrecompileScheduler` / `cachedReady` to remove those mentions.

- **`ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`**
  - Remove tests that exercise `warm()` or scheduler-projection helpers.
  - **Keep** tests covering put/get, eviction per partition, persistence round-trip, `statsByCategory`, and `indexEvents` emission.

- **`ios/KataGo iOS/KataGo iOSUITests/CoreMLCacheFooterUITests.swift`**
  - Update post-Clear expectation from `Main: 1 of 4 · ...` (which relied on `scheduleBuiltIn` rewarm) to `Main: 0 of 4 · 0 B` (or analogous zero-size string the footer actually renders).
  - Keep the pre-Clear assertion that the footer displays expected counts after the user has loaded a model at least once. If a test only validated the rewarm pathway, delete that test.

### Unchanged (verified during implementation)

- `CoreMLCacheKeyTests.swift`
- `CoreMLComputeHandleLoader.swift`
- C++ bridge and `convertOnCooperativePool` infrastructure
- Other backends (Metal, Eigen) and their selection paths

## UI Specification

### Picker rows
Each row renders only the model's name, source, and any selection state already present. No trailing icon for cache readiness.

### Footer
Two lines, vertically stacked, with a trailing **Clear** button (existing layout preserved):

```
Main:     N of 4 · <human-readable size>
Human SL: N of 4 · <human-readable size>            [Clear]
```

- `N` reflects current on-disk entry count in each partition.
- Size is the sum of bytes for entries in that partition, rendered with the existing formatter.
- The footer updates whenever `CoreMLModelCache.shared.indexEvents` yields (which the cache emits on insert, evict, and clear).
- Tapping **Clear** wipes both partitions on disk and immediately refreshes the footer (showing 0 / 0 B). The cache will repopulate naturally as the user loads models.

## Error Handling

- If the lazy compile fails during model load (existing `CoreMLComputeHandleLoader` retry path), the user sees the existing error surfacing in `ContentView`. No new error paths.
- If `statsByCategory()` throws (it currently does not), the footer leaves the prior values visible and logs to console. (Behavior carried forward from the current implementation; no new contract.)

## Performance / Tradeoffs

- **First selection of an uncompiled model:** visible compile delay during model load (typically a few seconds on modern Apple Silicon). On subsequent loads, the cache hits and load is sub-second.
- **App launch / scene foregrounding:** zero precompile work. Faster cold start; nothing CPU-bound running while the user is on the menu.
- **Cache stays bounded.** LRU eviction at 4 entries per partition still applies, so size cannot grow unbounded.

## Testing Strategy

- **Unit (`CoreMLModelCacheTests`)** — verify put/get, eviction per partition, `statsByCategory`, `indexEvents` fires on insert and clear.
- **UI (`CoreMLCacheFooterUITests`)** — verify footer renders, reflects counts after a lazy compile, and resets to 0 / 0 B after Clear with no rewarm.
- **Build** — must succeed for iOS Simulator, macOS, and visionOS Simulator (per CLAUDE.md build matrix).
- **No new tests required for absence of badges**; visual inspection during build verification suffices.

## Rollout

Single PR. No feature flag (app is unreleased; no users to gate against).

## Open Items

None.
