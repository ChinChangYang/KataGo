//
//  TVLibraryView.swift
//  KataGo Anytime TV
//
//  The lean-back library: a focusable grid of the iCloud-synced saved games.
//  Each card is a crisp vector board thumbnail (WidgetBoardView) — no engine.
//  Selecting a card pushes the read-only review screen.
//
//  An empty query is NOT one state: CloudKitSyncMonitor + LibrarySyncPolicy
//  split it into syncing / signed-out / iCloud-unavailable / truly-empty, and
//  every variant offers the bundled sample game so a brand-new user has
//  something to watch immediately. While the initial import burst is landing,
//  the populated grid shows a live "Syncing — N games so far…" pill.
//

import SwiftUI
import SwiftData
import KataGoUICore

/// Where library focus sits — one tag per focusable card, so D-pad movement
/// is observable as a single onChange (the idle-attract activity signal).
private enum LibraryFocus: Hashable {
    case selfPlay
    case sample
    case settings
    case game(PersistentIdentifier)
}

struct TVLibraryView: View {
    @Query(sort: \GameRecord.lastModificationDate, order: .reverse) private var gameRecords: [GameRecord]
    @Environment(CloudKitSyncMonitor.self) private var syncMonitor
    // Optional: previews and hosts without attract mode simply get no idle
    // tracking (the signal degrades to nothing, never crashes).
    @Environment(TVAttractModeController.self) private var attractMode: TVAttractModeController?
    @FocusState private var focus: LibraryFocus?

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 48)]

    var body: some View {
        Group {
            if gameRecords.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 48) {
                        // Permanent lead card: the self-play demo stays
                        // reachable after real games sync.
                        if TVSampleGameStore.isAvailable {
                            NavigationLink(value: SelfPlayRoute(entry: .manual)) {
                                TVSelfPlayCard()
                            }
                            .buttonStyle(.card)
                            .focused($focus, equals: .selfPlay)
                        }
                        ForEach(gameRecords) { game in
                            NavigationLink(value: game) {
                                TVGameCard(game: game)
                            }
                            .buttonStyle(.card)
                            .focused($focus, equals: .game(game.persistentModelID))
                        }
                        // Trailing settings card: backend/benchmark, recovery
                        // resets, and the sound toggle.
                        NavigationLink(value: SettingsRoute()) {
                            TVSettingsCard()
                        }
                        .buttonStyle(.card)
                        .focused($focus, equals: .settings)
                    }
                    .padding(.horizontal, 90)
                    .padding(.vertical, 60)
                    .focusSection()
                }
                .overlay(alignment: .bottom) {
                    // Live progress while the initial import burst lands; the
                    // count ticks up via the @Query and the pill auto-hides
                    // ~10 s after the burst quiets. Plain material capsule —
                    // deliberately NOT focusable, so it can't trap D-pad
                    // navigation below the grid.
                    if syncMonitor.isSyncBannerVisible {
                        syncPill
                    }
                }
            }
        }
        .navigationTitle("KataGo Anytime")
        // Idle-attract activity signals: D-pad movement lands as focus changes
        // (do NOT use a library-level onMoveCommand — it would swallow grid
        // navigation); play/pause is otherwise unused here.
        .onChange(of: focus) { _, _ in
            attractMode?.noteUserActivity()
        }
        .onPlayPauseCommand {
            attractMode?.noteUserActivity()
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        let state = syncMonitor.emptyLibraryState()
        return VStack(spacing: 16) {
            // Reserve clearance below the "KataGo Anytime" navigation title:
            // the stack is vertically centered, so once it grew tall enough
            // (sample cards + Settings button) its top icon rose into the
            // title. This minimum keeps that gap; overflow spills off the
            // bottom, never up into the title. The trailing Spacer keeps a
            // short (syncing) stack visually centered.
            Spacer(minLength: 80)
            if state == .syncing {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: iconName(for: state))
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
            }
            Text(title(for: state))
                .font(.title2.bold())
            Text(message(for: state))
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 800)
                // Wrap instead of truncating to one line (the tvOS Text trap).
                .fixedSize(horizontal: false, vertical: true)
            sampleSection
                .padding(.top, 12)
            // Settings must stay reachable with an empty library too — the
            // recovery actions (engine restart, iCloud re-download) matter
            // most exactly when the library looks wrong.
            NavigationLink(value: SettingsRoute()) {
                Label("Settings", systemImage: "gearshape")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .focused($focus, equals: .settings)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func iconName(for state: EmptyLibraryState) -> String {
        switch state {
        case .syncing: "icloud.and.arrow.down"
        case .signedOut: "icloud.slash"
        case .unavailable: "exclamationmark.icloud"
        case .empty: "square.grid.3x3"
        }
    }

    private func title(for state: EmptyLibraryState) -> String {
        switch state {
        case .syncing: "Checking iCloud for your games…"
        case .signedOut: "Sign in to iCloud"
        case .unavailable: "iCloud is unavailable"
        case .empty: "No games yet"
        }
    }

    private func message(for state: EmptyLibraryState) -> String {
        switch state {
        case .syncing:
            "Games you review on iPhone, iPad, or Mac sync here automatically. This can take a minute on first launch."
        case .signedOut:
            // Textual guidance — tvOS has no usable Settings deep link.
            "This Apple TV isn't signed into iCloud. Sign in under Settings → Users and Accounts → iCloud, and your games will appear here automatically."
        case .unavailable:
            "The library couldn't connect to iCloud this launch. Your games are safe — quit and reopen the app to try again."
        case .empty:
            "Games you create on iPhone, iPad, or Mac appear here automatically once they sync from iCloud."
        }
    }

    /// The empty state's focusable offerings: the bundled sample game and the
    /// live self-play demo, side by side — the focus engine finally has
    /// somewhere to land, and a brand-new user has something to watch.
    @ViewBuilder
    private var sampleSection: some View {
        if TVSampleGameStore.sampleGame != nil || TVSampleGameStore.isAvailable {
            // 44 (was 14): the .card focus lift scales a focused card upward;
            // without this clearance it slides over the header text.
            VStack(spacing: 44) {
                Text("Watch a game")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 40) {
                    if let sample = TVSampleGameStore.sampleGame {
                        NavigationLink(value: sample) {
                            // Size the LABEL, not the button (an outer frame
                            // never reaches the board inside), and pin the
                            // ideal height: the surrounding VStack proposes a
                            // squeezed height, which would otherwise shrink
                            // the aspect-fit board to a thumbnail instead of
                            // the 360 pt the width allows.
                            TVGameCard(game: sample)
                                .frame(width: 400)
                                .fixedSize(horizontal: false, vertical: true)
                                .overlay(alignment: .topTrailing) { sampleBadge }
                        }
                        .buttonStyle(.card)
                        .focused($focus, equals: .sample)
                    }
                    if TVSampleGameStore.isAvailable {
                        NavigationLink(value: SelfPlayRoute(entry: .manual)) {
                            TVSelfPlayCard()
                                .frame(width: 400)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.card)
                        .focused($focus, equals: .selfPlay)
                    }
                }
            }
        }
    }

    private var sampleBadge: some View {
        Text("Sample")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tvWoodAccent, in: Capsule())
            .padding(10)
    }

    private var syncPill: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Syncing — ^[\(gameRecords.count) game](inflect: true) so far…")
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: Capsule())
        .padding(.bottom, 24)
    }
}

struct TVGameCard: View {
    let game: GameRecord

    private var vertices: (black: [String], white: [String]) {
        let idx = displayIndex
        let b = (game.blackStones?[idx] ?? "").split(separator: " ").map(String.init)
        let w = (game.whiteStones?[idx] ?? "").split(separator: " ").map(String.init)
        return (b, w)
    }

    /// The move whose position we show: the current move if it has stones,
    /// otherwise the highest visited move (mirrors the widget's resolution).
    private var displayIndex: Int {
        if game.blackStones?[game.currentIndex] != nil || game.whiteStones?[game.currentIndex] != nil {
            return game.currentIndex
        }
        return max(game.blackStones?.keys.max() ?? 0, game.whiteStones?.keys.max() ?? 0)
    }

    var body: some View {
        // The board sits inset within the card so the .card style's rounded
        // clip never cuts its corners — a Go board must read as a complete
        // rectangle, framed by the card surface. Name/date keep their own
        // inset block below.
        VStack(alignment: .leading, spacing: 0) {
            WidgetBoardView(width: game.width ?? 19,
                            height: game.height ?? 19,
                            blackVertices: vertices.black,
                            whiteVertices: vertices.white)
                .aspectRatio(1, contentMode: .fit)
                .padding([.top, .horizontal], 20)

            VStack(alignment: .leading, spacing: 6) {
                Text(game.name.isEmpty ? "Untitled" : game.name)
                    .font(.headline)
                    .lineLimit(1)
                Group {
                    if let date = game.lastModificationDate {
                        Text(date, format: .dateTime.year().month().day())
                    } else {
                        // Reserve the line: an undated card must keep the same
                        // height as its neighbors, or the vertically-centered
                        // grid row leaves it floating misaligned.
                        Text(verbatim: " ")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Previews

// #Preview bodies still compile in Release, and the TVPreviewData fixtures are
// DEBUG-only — guard the whole section or archiving fails.
#if DEBUG
// Grid path: three cards exercising a named+dated 19×19 (primary displayIndex
// branch), an untitled/undated fallback, and a 9×9 board.
#Preview("Library — populated") {
    NavigationStack {
        TVLibraryView()
            .navigationDestination(for: GameRecord.self) { game in
                Text(game.name)
            }
    }
    .modelContainer(TVPreviewData.container(games: [
        TVPreviewData.openingGame(),
        TVPreviewData.untitledFallbackGame(),
        TVPreviewData.smallBoardGame(),
    ]))
    .environment(CloudKitSyncMonitor.fixture())
}

// Populated grid during the initial import burst: the sync pill counts along.
#Preview("Library — populated, sync burst") {
    NavigationStack {
        TVLibraryView()
            .navigationDestination(for: GameRecord.self) { game in
                Text(game.name)
            }
    }
    .modelContainer(TVPreviewData.container(games: [
        TVPreviewData.openingGame(),
        TVPreviewData.untitledFallbackGame(),
        TVPreviewData.smallBoardGame(),
    ]))
    .environment(CloudKitSyncMonitor.fixture(recentRemoteActivity: true))
}

// The four empty states. Each also shows the bundled sample-game card.
#Preview("Library — syncing") {
    NavigationStack { TVLibraryView() }
        .modelContainer(TVPreviewData.container(games: []))
        .environment(CloudKitSyncMonitor.fixture(importInFlight: true))
}

#Preview("Library — signed out") {
    NavigationStack { TVLibraryView() }
        .modelContainer(TVPreviewData.container(games: []))
        .environment(CloudKitSyncMonitor.fixture(accountState: .unavailable))
}

#Preview("Library — iCloud unavailable") {
    NavigationStack { TVLibraryView() }
        .modelContainer(TVPreviewData.container(games: []))
        .environment(CloudKitSyncMonitor.fixture(storeMode: .localOnly))
}

#Preview("Library — truly empty") {
    NavigationStack { TVLibraryView() }
        .modelContainer(TVPreviewData.container(games: []))
        .environment(CloudKitSyncMonitor.fixture(graceExpired: true))
}

// Card branches side by side: primary displayIndex + name + date (left) vs
// fallback displayIndex + "Untitled" + hidden date (right).
#Preview("Game cards") {
    HStack(spacing: 60) {
        TVGameCard(game: TVPreviewData.openingGame())
        TVGameCard(game: TVPreviewData.untitledFallbackGame())
    }
    .frame(maxWidth: 900)
    .padding(80)
}
#endif
