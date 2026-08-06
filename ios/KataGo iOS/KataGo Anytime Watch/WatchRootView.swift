import SwiftUI
import SwiftData
import KataGoGameStore

/// Where the watch can navigate. The library is the root; a saved game is the
/// only push from it.
enum WatchRoute: Hashable {
    case game(String)
}

struct WatchRootView: View {
    @Environment(WatchLibraryStore.self) private var library
    let container: ModelContainer
    let widgetMirror: WatchWidgetMirror

    @State private var path: [WatchRoute] = []
    /// The game a complication tap named, held until it can be resolved.
    @State private var pendingDeepLinkID: String?
    /// Set once the launch grace has expired, so an unresolvable link can stop
    /// waiting rather than latch forever.
    @State private var graceExpired = false

    var body: some View {
        NavigationStack(path: $path) {
            WatchLibraryPage(path: $path)
                .navigationDestination(for: WatchRoute.self) { route in
                    switch route {
                    case .game(let id):
                        if let row = library.row(byID: id) {
                            WatchStoredGameView(row: row, container: container)
                        } else {
                            ContentUnavailableView("Game not found",
                                                   systemImage: "questionmark.folder",
                                                   description: Text("It may have been deleted."))
                        }
                    }
                }
        }
        .task {
            // Fires at the end of every refresh(), including the coalesced
            // remote-change path, so a CloudKit import updates the tile
            // without the user opening the library page. This is now the ONLY
            // writer the complication has: nothing wakes this app in the
            // background any more, so the tile shows whatever was true the
            // last time the app ran.
            library.onRefresh = { [weak library] in
                guard let library else { return }
                widgetMirror.mirrorLibrary(
                    rows: library.rows,
                    moveCount: { library.moveCount(for: $0) },
                    // Never evict on a partial view of the library: a degraded
                    // store, or a fetch that hit its row cap, has not proved a
                    // game is gone. Task 4 removes this argument along with the
                    // eviction pass itself — leave it here for now so the watch
                    // target keeps compiling, which the iOS scheme requires
                    // (the watch app is an iOS target dependency).
                    libraryIsAuthoritative:
                        SharedModelContainer.watchStoreMode == .cloudKit
                        && library.rows.count < WatchLibraryStore.fetchLimit,
                    container: container)
            }
            library.refresh()
            library.startObservingRemoteChanges()

            try? await Task.sleep(for: Self.deepLinkResolutionGrace)
            graceExpired = true
            applyPendingDeepLink()
        }
        .onOpenURL { url in
            // The scheme also carries import-sgf; anything this cannot parse
            // must be ignored rather than clobber a pending link.
            guard let id = GameDeepLink.gameID(from: url)?.uuidString else { return }
            pendingDeepLinkID = id
            // Called directly, not left to .onChange: this tile points at one
            // game at a time, so tapping the SAME id twice is the normal
            // interaction and writing an equal value fires no change.
            applyPendingDeepLink()
        }
        .onChange(of: pendingDeepLinkID, initial: true) { _, _ in applyPendingDeepLink() }
    }

    /// How long a tap that names a game the store cannot yet resolve keeps
    /// waiting before giving up. `WatchLibraryStore.row(byID:)` runs its own
    /// direct descriptor fetch, independent of `refresh()` and of the 100-row
    /// cap, so a game already in the local store resolves on the first
    /// evaluation and never touches this at all — the grace only covers a
    /// CloudKit import still in flight. Kept short on purpose: while it runs
    /// the user is on a fully interactive library, and a long window mostly
    /// buys opportunities to yank them out of a list mid-browse.
    private static let deepLinkResolutionGrace: Duration = .seconds(2)

    /// The one place a pending deep link becomes navigation. Always clears the
    /// latch on a terminal disposition — a stranded latch would keep
    /// re-evaluating for the rest of the session.
    private func applyPendingDeepLink() {
        guard let pending = pendingDeepLinkID else { return }
        switch WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: pending,
            libraryHasRow: library.row(byID: pending) != nil,
            graceExpired: graceExpired) {
        case .wait:
            return
        case .game(let id):
            // ASSIGN, never append: a second tap must replace the destination
            // rather than leave a two-deep stack whose back-swipe lands on the
            // previously-tapped game instead of the library.
            path = [.game(id)]
        case .giveUp:
            break
        }
        pendingDeepLinkID = nil
    }
}
