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

    /// The `ModelContext.didSave` observer token. `nonisolated(unsafe)` so the
    /// nonisolated `deinit` can read it to unregister: the token is only written
    /// once in `init` (on the main actor) and read once in `deinit` (when no
    /// other reference exists), so there's no actual concurrent access.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

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

    deinit {
        // Block-based observers are NOT auto-removed on dealloc — the token must
        // be explicitly unregistered, or the center keeps invoking a closure over
        // a freed `self` capture (here it's `[weak self]`, but unregistering is
        // still the correct contract).
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

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
