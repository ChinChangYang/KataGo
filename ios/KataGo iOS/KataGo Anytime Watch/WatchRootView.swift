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
        .onAppear(perform: routeOnLaunch)
        .onChange(of: path) { _, newPath in
            // Leaving the auto-pushed board consumes the latch.
            if newPath.isEmpty { latchConsumed = true }
        }
    }

    private var liveMirror: some View {
        TabView {
            WatchBoardPage()
            WatchMovesPage()
        }
        .tabViewStyle(.verticalPage)
        .navigationTitle("Live")
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

    private func routeOnLaunch() {
        guard path.isEmpty else { return }
        let route = WatchNavigationPolicy.launchRoute(hasSnapshot: model.latest != nil,
                                                      latchConsumed: latchConsumed)
        if route == .liveGame { path = [.live] }
    }
}
