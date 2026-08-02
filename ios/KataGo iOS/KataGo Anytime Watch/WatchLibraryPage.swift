import SwiftUI
import CloudKit
import KataGoGameStore

/// The watch's root: every saved game, with the phone's current game pinned
/// on top when there is one.
struct WatchLibraryPage: View {
    @Environment(WatchLiveModel.self) private var live
    @Environment(WatchLibraryStore.self) private var library
    @Binding var path: [WatchRoute]

    @State private var now = Date()

    var body: some View {
        List {
            if live.latest != nil {
                Section {
                    Button {
                        path.append(.live)
                    } label: {
                        liveRow
                    }
                }
            }

            if library.rows.isEmpty {
                emptyState
            } else {
                Section("Games") {
                    ForEach(library.rows) { row in
                        Button {
                            open(row)
                        } label: {
                            gameRow(row)
                        }
                    }
                }
            }
        }
        .navigationTitle("KataGo")
        .task {
            library.refresh()
            library.startObservingRemoteChanges()
            library.accountState = await Self.accountState()
            // Re-evaluate the empty state as the launch grace expires.
            try? await Task.sleep(for: .seconds(WatchLibraryStore.launchGrace))
            now = Date()
        }
    }

    private var liveRow: some View {
        HStack {
            Image(systemName: live.isStale ? "wifi.slash" : "dot.radiowaves.left.and.right")
                .foregroundStyle(live.isStale ? .red : .green)
            VStack(alignment: .leading) {
                Text(liveTitle).lineLimit(1)
                Text(liveSubtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var liveTitle: String {
        if let id = live.latest?.hostGameID, let row = library.row(id: id) {
            return row.name
        }
        return "Live on iPhone"
    }

    private var liveSubtitle: String {
        guard let snapshot = live.latest else { return "" }
        if let index = snapshot.hostMoveIndex, let count = snapshot.hostMoveCount {
            return "Move \(index) of \(count)"
        }
        return "\(snapshot.boardWidth)x\(snapshot.boardHeight)"
    }

    private func gameRow(_ row: WatchLibraryRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.name).lineLimit(1)
            Text("\(row.sizeText) - \(library.moveCount(for: row)) moves")
                .font(.caption2).foregroundStyle(.secondary)
            if let date = row.lastModified {
                Text(date, style: .relative)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch library.emptyState(now: now) {
        case .syncing:
            HStack {
                ProgressView()
                Text("Syncing from iCloud").font(.caption)
            }
        case .signedOut:
            Label("Sign in to iCloud on iPhone to see your games",
                  systemImage: "icloud.slash")
                .font(.caption)
        case .unavailable:
            Label("iCloud is unavailable. Games will appear once it reconnects.",
                  systemImage: "exclamationmark.icloud")
                .font(.caption)
        case .empty:
            Label("No games yet. Games sync from your iPhone.",
                  systemImage: "circle.grid.cross")
                .font(.caption)
        }
    }

    private func open(_ row: WatchLibraryRow) {
        if WatchNavigationPolicy.opensLiveMirror(rowID: row.id,
                                                 hostGameID: live.latest?.hostGameID,
                                                 hasSnapshot: live.latest != nil) {
            path.append(.live)
        } else {
            path.append(.stored(row.id))
        }
    }

    /// The account signal the empty-state policy needs. Kept in the view so
    /// KataGoGameStore never has to import CloudKit.
    private static func accountState() async -> ICloudAccountState {
        do {
            switch try await CKContainer(identifier: SharedModelContainer.cloudKitContainerID)
                .accountStatus() {
            case .available: return .available
            case .noAccount, .restricted: return .unavailable
            default: return .unknown
            }
        } catch {
            return .unknown
        }
    }
}
