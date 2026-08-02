import Foundation

/// A main-actor, trailing-edge debouncer that collapses bursty work into a single
/// run. Each `schedule(_:)` cancels any still-pending run and re-arms a fresh
/// trailing window, so a burst of N rapid calls runs the work exactly once —
/// after the burst goes quiet for `delay`.
///
/// Lives in `KataGoGameStore` (Foundation-only, bridge-free) rather than
/// `KataGoUICore` so the watch — which links `KataGoGameStore` but never
/// `KataGoUICore` — can reach it too. `KataGoUICore` re-exports the type
/// (`GameStoreReexport.swift`), so its own consumers (the macOS
/// `LibraryStore`, the tvOS `CloudKitSyncMonitor`/`TVAttractMode`) and the
/// iOS test host (`CoalescedTriggerTests`, `@testable import KataGoUICore`)
/// keep seeing it unqualified. Two consumers use it to absorb a burst of
/// `.NSPersistentStoreRemoteChange` notifications CloudKit posts during
/// initial sync, where a full refetch + reload per event would thrash the
/// list: the Mac's `LibraryStore` (sidebar table) and the watch's
/// `WatchLibraryStore` (game list) — the coalescing window also lets
/// SwiftData's main-context auto-merge settle before the refetch reads.
///
/// Lifecycle: the pending run captures whatever `work` captures — pass
/// `[weak self]` if `work` references an owner that may deallocate first. The
/// trigger does NOT auto-cancel on dealloc (a main-actor type can't touch its
/// task from a nonisolated `deinit`); a dangling run is harmless when `work`
/// holds only a weak reference, or call `cancel()` explicitly.
@MainActor
public final class CoalescedTrigger {
    private let delay: Duration
    private var pending: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(150)) {
        self.delay = delay
    }

    /// Cancels any pending run and schedules `work` to run after `delay`. Only
    /// the last call in a burst survives.
    public func schedule(_ work: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task { @MainActor in
            // `try?` swallows the CancellationError a superseded run throws out of
            // `sleep`, so the `isCancelled` guard below is what actually suppresses
            // the work — it is load-bearing, not redundant.
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            work()
        }
    }

    /// Cancels any pending run without executing it.
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Awaits the in-flight run (if any) to completion. Deterministic regardless
    /// of `delay`, so callers — chiefly tests, but also teardown flushes — need
    /// not sleep on wall-clock time.
    public func settle() async {
        await pending?.value
    }
}
