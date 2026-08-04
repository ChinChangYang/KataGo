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
    let container: ModelContainer

    @State private var path: [WatchRoute] = []
    /// Set once the user has left the auto-pushed board, so the library stays
    /// reachable for the rest of this session.
    @State private var latchConsumed = false

    var body: some View {
        NavigationStack(path: $path) {
            WatchLibraryPage(path: $path)
                .navigationDestination(for: WatchRoute.self) { route in
                    switch route {
                    case .live:
                        liveMirror
                    case .stored(let id):
                        if let row = library.row(id: id) {
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
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: Self.launchSnapshotGrace)
            while model.latest == nil, clock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            routeOnLaunch()
        }
        .onChange(of: path) { _, newPath in
            // Leaving the auto-pushed board consumes the latch.
            if newPath.isEmpty { latchConsumed = true }
        }
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

    private func routeOnLaunch() {
        guard path.isEmpty else { return }
        let route = WatchNavigationPolicy.launchRoute(hasSnapshot: model.latest != nil,
                                                      latchConsumed: latchConsumed)
        if route == .liveGame { path = [.live] }
    }
}
