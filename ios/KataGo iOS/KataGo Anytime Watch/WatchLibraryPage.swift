import SwiftUI
import CloudKit
import KataGoGameStore

/// The watch's root: every saved game, newest first.
struct WatchLibraryPage: View {
    @Environment(WatchLibraryStore.self) private var library
    @Binding var path: [WatchRoute]

    @State private var now = Date()

    var body: some View {
        List {
            if library.rows.isEmpty {
                emptyState
            } else {
                // Unsectioned on purpose. There is exactly one kind of game on
                // the watch now, so a "Games" header would label nothing — the
                // navigation title already describes the whole screen.
                ForEach(library.rows) { row in
                    Button {
                        path.append(.game(row.id))
                    } label: {
                        gameRow(row)
                    }
                }
            }
        }
        .navigationTitle("Games")
        .task {
            // Concurrent, not serialized: CKContainer.accountStatus() has no
            // timeout, so the write to `now` must not be sequenced behind
            // awaiting it — that would pin the empty state on "Syncing from
            // iCloud" for as long as that call hangs. `library.accountState` is
            // an observed property of an @Observable store, so its later
            // arrival still re-renders the empty state on its own, and
            // `LibrarySyncPolicy` checks `accountState != .unavailable` before
            // it ever looks at the grace flag, so a late `.signedOut` still
            // wins.
            async let accountState = Self.accountState()
            async let graceExpired: Void = Self.waitForLaunchGrace()
            await graceExpired
            // Re-evaluate the empty state now that the launch grace expired.
            now = Date()
            library.accountState = await accountState
        }
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
            // Still "from your iPhone": the phone is where games are created
            // and iCloud is still the pipe. It is just no longer a live one.
            Label("No games yet. Games sync from your iPhone.",
                  systemImage: "circle.grid.cross")
                .font(.caption)
        }
    }

    /// The launch-grace timer, split out so it can run concurrently with
    /// `accountState()` in one `.task` (see there for why).
    private static func waitForLaunchGrace() async {
        try? await Task.sleep(for: .seconds(WatchLibraryStore.launchGrace))
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
