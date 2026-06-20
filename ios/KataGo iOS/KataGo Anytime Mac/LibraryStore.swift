import CoreData
import Foundation
import SwiftData
import KataGoUICore

@MainActor final class LibraryStore {
    private let container: ModelContainer
    private(set) var games: [GameRecord] = []
    var searchText: String = "" { didSet { applyFilter() } }
    /// Called whenever `games` changes (the sidebar reloads its table here).
    var onChange: (() -> Void)?

    /// The full, unfiltered fetch (`games` is this list narrowed by `searchText`).
    /// Exposed so callers that must reason about every game — e.g. choosing a
    /// replacement after deleting the loaded game — aren't misled by an active
    /// search filter.
    private(set) var allGames: [GameRecord] = []

    /// Store-change observer tokens. `nonisolated(unsafe)` so the nonisolated
    /// `deinit` can read them to unregister: written once in `init` (on the main
    /// actor) and read once in `deinit` (when no other reference exists), so
    /// there's no actual concurrent access.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// Debounces remote-change-driven refetches (see `scheduleCoalescedRefetch`).
    /// Lives in `KataGoUICore` so its coalescing/cancellation logic is unit-tested
    /// (`CoalescedTriggerTests`) — this Mac-only type isn't reachable by the test
    /// target. Not torn down in `deinit`: the `[weak self]` work closure no-ops
    /// once `self` is gone.
    private let remoteRefetchTrigger = CoalescedTrigger()

    init(container: ModelContainer) {
        self.container = container
        refetch()
        // Re-fetch on two distinct store-change signals, deliberately handled
        // differently:
        //   • `ModelContext.didSave` — LOCAL saves. Covers in-app edits that do
        //     not go through the library CRUD actions (e.g. an autosave after a
        //     played move bumps `lastModificationDate`, re-sorting the list).
        //     These are discrete, per-edit events that never burst, so we refetch
        //     IMMEDIATELY — no coalescing — to keep the local re-sort instant.
        //   • `.NSPersistentStoreRemoteChange` — CloudKit merging remote
        //     inserts/deletes/edits from OTHER devices into the store. `didSave`
        //     does NOT fire for these (the merge lands below the main context's
        //     save path), so without this the sidebar never reflects games
        //     created/removed on another device until relaunch. CloudKit can post
        //     a BURST of these during initial sync, so they go through a coalesced
        //     refetch to avoid thrashing the table.
        // Library CRUD ops still call `refetch()` directly for immediate,
        // deterministic local updates.
        observers = [
            NotificationCenter.default.addObserver(
                forName: ModelContext.didSave, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refetch() }
            },
            NotificationCenter.default.addObserver(
                forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleCoalescedRefetch() }
            },
        ]
    }

    deinit {
        // Block-based observers are NOT auto-removed on dealloc — each token must
        // be explicitly unregistered, or the center keeps invoking a closure over
        // a freed `self` capture (here it's `[weak self]`, but unregistering is
        // still the correct contract).
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func refetch() {
        allGames = (try? GameRecord.fetchGameRecords(container: container)) ?? []
        applyFilter()
    }

    /// Coalesces remote-change-driven refetches. CloudKit can post a burst of
    /// `.NSPersistentStoreRemoteChange` notifications during initial sync, and a
    /// full refetch + table reload per event would thrash the sidebar. The
    /// `CoalescedTrigger` collapses a burst to a single trailing refetch; its
    /// 150 ms window also lets SwiftData's default main-context auto-merge settle
    /// before we read, and any later notification re-arms it. Local saves and
    /// user-initiated CRUD don't pass through here — they refetch immediately.
    private func scheduleCoalescedRefetch() {
        remoteRefetchTrigger.schedule { [weak self] in self?.refetch() }
    }

    private func applyFilter() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        games = q.isEmpty ? allGames : allGames.filter { $0.name.localizedStandardContains(q) }
        onChange?()
    }
}
