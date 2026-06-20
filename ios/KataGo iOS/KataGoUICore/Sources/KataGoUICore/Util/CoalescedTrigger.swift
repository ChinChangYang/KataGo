import Foundation

/// A main-actor, trailing-edge debouncer that collapses bursty work into a single
/// run. Each `schedule(_:)` cancels any still-pending run and re-arms a fresh
/// trailing window, so a burst of N rapid calls runs the work exactly once —
/// after the burst goes quiet for `delay`.
///
/// Extracted into `KataGoUICore` (dependency-light, platform-agnostic) so the
/// coalescing/cancellation logic is unit-testable from the iOS test host: its
/// only consumer, the macOS `LibraryStore`, is a Mac-target-only type the test
/// target can't reach. `LibraryStore` uses it to absorb the burst of
/// `.NSPersistentStoreRemoteChange` notifications CloudKit posts during initial
/// sync, where a full refetch + table reload per event would thrash the sidebar.
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
