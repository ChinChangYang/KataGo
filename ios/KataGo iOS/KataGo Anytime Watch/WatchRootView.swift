import SwiftUI
import SwiftData
import KataGoGameStore

/// Where the watch can navigate. The library is the root; the live mirror and
/// any saved game are pushes from it.
enum WatchRoute: Hashable {
    case live
    case stored(String)
}

struct WatchRootView: View {
    @Environment(WatchLiveModel.self) private var model
    @Environment(WatchLibraryStore.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    let container: ModelContainer

    @State private var path: [WatchRoute] = []
    /// Set once the user has left the auto-pushed board, so the library stays
    /// reachable for the rest of this session.
    @State private var latchConsumed = false
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
                    case .live:
                        liveMirror
                    case .stored(let id):
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
            // The mirror itself is `KataGoAnytimeWatchApp.init()`'s, already
            // wired into `model.widgetMirror` before `activateForLaunch()`
            // ran — this view only supplies the library half it could not
            // have at app-init time (the container, and the name backfill).
            let mirror = model.widgetMirror
            // Resolves a game id to its library name for a frame from a phone
            // that predates the v1.3 wire fields. Only reachable once the
            // library exists, so a cold background wake — which never mounts
            // this view — leaves `libraryName` nil and falls back to whatever
            // name (if any) the frame itself carries; a nameless frame with
            // no library to consult is simply not mirrored (see
            // `WatchWidgetRecords.acceptingLive`/`acceptingLibrary`). That is
            // an accepted degradation, not an oversight: a current phone
            // sends the name on the wire.
            model.libraryName = { [weak library] id in library?.row(id: id)?.name }
            // Fires at the end of every refresh(), including the coalesced
            // remote-change path, so a CloudKit import updates the tile
            // without the user opening the library page.
            library.onRefresh = { [weak library] in
                guard let library else { return }
                mirror?.mirrorLibrary(
                    rows: library.rows,
                    moveCount: { library.moveCount(for: $0) },
                    // Never evict on a partial view of the library: a
                    // degraded store, or a fetch that hit its row cap, has
                    // not proved a game is gone.
                    libraryIsAuthoritative:
                        SharedModelContainer.watchStoreMode == .cloudKit
                        && library.rows.count < WatchLibraryStore.fetchLimit,
                    container: container)
            }
            library.refresh()
            library.startObservingRemoteChanges()

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: Self.launchSnapshotGrace)
            while model.latest == nil, clock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            graceExpired = true
            applyPendingDeepLink()
            routeOnLaunch()
        }
        .onChange(of: path) { _, newPath in
            // Leaving the auto-pushed board consumes the latch.
            if newPath.isEmpty { latchConsumed = true }
        }
        .onChange(of: scenePhase) { _, phase in
            // A scene created during a background wake has already burned its
            // one-shot launch route with no user present. Re-arm on the first
            // activation, guarded by `latchConsumed` so this can never bounce
            // the user off the library mid-session.
            guard phase == .active else { return }
            routeOnLaunch()
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
        .onChange(of: model.latest?.hostGameID) { _, _ in applyPendingDeepLink() }
    }

    /// How long to wait for WCSession to replay its persisted application
    /// context before deciding where to land. `receivedApplicationContext` is
    /// documented empty until activation completes, so the snapshot that should
    /// send us straight to the board arrives a beat AFTER the view appears —
    /// sampling it at .onAppear would make the live route unreachable on every
    /// cold launch.
    private static let launchSnapshotGrace: Duration = .seconds(2)

    private var liveMirror: some View {
        TabView {
            WatchBoardPage()
            WatchMovesPage()
        }
        .tabViewStyle(.verticalPage)
        // Plain, not tinted. Rendering `Offline` in red was tried and measured on
        // a 46 mm simulator: watchOS ignores `foregroundStyle` on a navigation
        // title and drew it in the same gray as `Live`. The word carries the
        // meaning, and a modifier that does nothing is worse than none.
        .navigationTitle(liveTitle)
        .overlay(alignment: .bottom) {
            if let message = model.rejectionMessage {
                Label { Text(message) } icon: { Image(systemName: "xmark.circle.fill") }
                    .font(.caption2).padding(4)
                    .background(.red.opacity(0.9), in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.rejectionMessage)
    }

    /// The board page's only status readout. `hostMoveIndex` rather than the
    /// Crown's position deliberately: this reports what the PHONE has
    /// confirmed, exactly as the deleted pill did, while `pendingTarget`
    /// covers the in-flight value.
    private var liveTitle: String {
        WatchBoardTitle.live(stale: model.isStale,
                             pendingTarget: model.cursorPendingTarget,
                             hostMoveIndex: model.latest?.hostMoveIndex,
                             hostMoveCount: model.latest?.hostMoveCount,
                             sharedCursorAvailable: model.sharedCursorAvailable,
                             movesBehindLive: model.peek.movesBehindLive)
    }

    /// The one place a pending deep link becomes navigation. Always clears the
    /// latch on a terminal disposition — a stranded latch would suppress
    /// `routeOnLaunch` for the rest of the session.
    private func applyPendingDeepLink() {
        guard let pending = pendingDeepLinkID else { return }
        switch WatchNavigationPolicy.deepLinkDisposition(
            pendingGameID: pending,
            hostGameID: model.latest?.hostGameID,
            hasSnapshot: model.latest != nil,
            libraryHasRow: library.row(byID: pending) != nil,
            graceExpired: graceExpired) {
        case .wait:
            return
        case .live:
            // ASSIGN, never append: the app is often already at [.live], and
            // appending would leave a two-deep stack whose back-swipe lands on
            // the mirror instead of the library.
            path = [.live]
        case .stored(let id):
            path = [.stored(id)]
        case .giveUp:
            break
        }
        pendingDeepLinkID = nil
    }

    private func routeOnLaunch() {
        // A tap names a specific game; the launch heuristic must never
        // overwrite it.
        guard pendingDeepLinkID == nil, path.isEmpty else { return }
        let route = WatchNavigationPolicy.launchRoute(hasSnapshot: model.latest != nil,
                                                      latchConsumed: latchConsumed)
        if route == .liveGame { path = [.live] }
    }
}
