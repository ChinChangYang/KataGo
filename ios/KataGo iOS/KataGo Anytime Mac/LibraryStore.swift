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
    private var observer: NSObjectProtocol?

    init(container: ModelContainer) {
        self.container = container
        refetch()
        // Re-fetch when SwiftData persists changes (covers CloudKit-synced
        // inserts that arrive after launch). CRUD ops also call refetch()
        // directly for immediate, deterministic updates.
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refetch() }
        }
    }

    // No explicit removeObserver in deinit: under Swift 6 strict concurrency a
    // nonisolated deinit can't touch the non-Sendable `observer` property. The
    // block-based token is automatically unregistered when it (and thus this
    // store) is deallocated, so the observation is torn down anyway.

    func refetch() {
        allGames = (try? GameRecord.fetchGameRecords(container: container)) ?? []
        applyFilter()
    }

    private func applyFilter() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        games = q.isEmpty ? allGames : allGames.filter { $0.name.localizedStandardContains(q) }
        onChange?()
    }
}
