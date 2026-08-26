//
//  TVLibraryView.swift
//  KataGo Anytime TV
//
//  The lean-back library: a focusable grid of the iCloud-synced saved games.
//  Each card is a crisp vector board thumbnail (WidgetBoardView) drawn from the
//  record's own SGF replayed to its own cursor — no engine, no stored bitmap.
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
    case playKataGo
    case selfPlay
    case sample
    case game(PersistentIdentifier)
}

struct TVLibraryView: View {
    @Query(sort: \GameRecord.lastModificationDate, order: .reverse) private var gameRecords: [GameRecord]
    @Environment(CloudKitSyncMonitor.self) private var syncMonitor
    // NOT optional. Idle attract mode has no other signal source, so a nil
    // read silently disables the whole feature and nothing reports it. There
    // is one host (TVRootView, which injects it), and the sibling
    // `syncMonitor` above is already non-optional — previews inject both.
    @Environment(TVAttractModeController.self) private var attractMode: TVAttractModeController
    @FocusState private var focus: LibraryFocus?

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 48)]

    var body: some View {
        Group {
            if gameRecords.isEmpty {
                emptyState
            } else {
                populatedGrid
            }
        }
        .navigationTitle("KataGo Anytime")
        // Idle-attract activity signals: D-pad movement lands as focus changes
        // (do NOT use a library-level onMoveCommand — it would swallow grid
        // navigation); play/pause is otherwise unused here.
        .onChange(of: focus) { _, _ in
            attractMode.noteUserActivity()
        }
        .onPlayPauseCommand {
            attractMode.noteUserActivity()
        }
    }

    // MARK: - Grid

    private var populatedGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 48) {
                // Permanent lead cards: Play KataGo (never gated — it needs no
                // sample store) and the self-play demo stay reachable after
                // real games sync.
                NavigationLink(value: NewGameRoute()) {
                    TVPlayKataGoCard()
                }
                .buttonStyle(.card)
                .focused($focus, equals: .playKataGo)

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

    // MARK: - Empty states

    private var emptyState: some View {
        TVLibraryEmptyState(state: syncMonitor.emptyLibraryState(), focus: $focus)
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

// MARK: - Empty-state layout

/// The empty state's geometry, in one place, because the bug it exists to
/// prevent was arithmetic drift: the two-column layout shipped sized for TWO
/// 440 pt cards (2×440 + 44 = 924, leaving the status column 624 of its 640 pt
/// ceiling), and a third card was added later without revisiting the sum.
/// 3×440 + 2×44 = 1408 pt of RIGID width against a `.frame(maxWidth: 640)`
/// that is a ceiling with a floor of ZERO, so the text column collapsed to
/// ~140 pt — narrower than the single word "Checking" at Title 1 — and its
/// prose grew off the bottom of the screen.
enum TVLibraryLayoutMetrics {
    /// tvOS is always exactly 1920×1080 pt.
    static let screenWidth: CGFloat = 1920
    static let horizontalPadding: CGFloat = 90
    /// Overscan safe-area inset per side.
    static let safeAreaInset: CGFloat = 60
    /// Card gap, sized to clear `.buttonStyle(.card)`'s focus scale-up.
    static let cardSpacing: CGFloat = 44
    static let cardWidth: CGFloat = 440

    /// 1920 − 2 × (90 + 60) = 1620 pt.
    static var contentWidth: CGFloat {
        screenWidth - 2 * (horizontalPadding + safeAreaInset)
    }

    /// How many full-size cards fit on one row — 3 at the shipped numbers.
    /// This is the check that was missing when a third card was added to a row
    /// sized for two; consult it before adding a fourth, which does NOT fit
    /// (4×440 + 3×44 = 1892 > 1620) and would need a different arrangement
    /// rather than a narrower card.
    static var cardsPerRow: Int {
        Int((contentWidth + cardSpacing) / (cardWidth + cardSpacing))
    }
}

/// The four empty-library states' copy, at file scope so the prototypes and
/// production share one source.
enum TVLibraryEmptyCopy {
    static func iconName(for state: EmptyLibraryState) -> String {
        switch state {
        case .syncing: "icloud.and.arrow.down"
        case .signedOut: "icloud.slash"
        case .unavailable: "exclamationmark.icloud"
        case .empty: "square.grid.3x3"
        }
    }

    static func title(for state: EmptyLibraryState) -> String {
        switch state {
        case .syncing: "Checking iCloud for your games…"
        case .signedOut: "Sign in to iCloud"
        case .unavailable: "iCloud is unavailable"
        case .empty: "No games yet"
        }
    }

    /// Trimmed to fit the stacked band's full-width line. Every sentence here
    /// is shorter than the original it replaces and says the same thing — the
    /// tvOS rule is to CUT prose that does not fit, not to shrink it.
    static func message(for state: EmptyLibraryState) -> String {
        switch state {
        case .syncing:
            "Games from your other devices sync here. First launch can take a minute."
        case .signedOut:
            // Textual guidance — tvOS has no usable Settings deep link.
            "Sign in under Settings → Users and Accounts → iCloud to see your games."
        case .unavailable:
            "Couldn't reach iCloud. Your games are safe — quit and reopen to try again."
        case .empty:
            "Games you create on other devices appear here once they sync from iCloud."
        }
    }
}

/// The spinner-or-icon that heads the empty state.
private struct TVLibraryEmptyIcon: View {
    let state: EmptyLibraryState
    var size: CGFloat = 72

    var body: some View {
        if state == .syncing {
            ProgressView()
                .controlSize(.large)
        } else {
            Image(systemName: TVLibraryEmptyCopy.iconName(for: state))
                .font(.system(size: size))
                .foregroundStyle(.secondary)
        }
    }
}

/// Icon inline with a two-line text block, across the full content width.
/// Single-line by construction: at 1620 pt every title and every trimmed
/// message fits, which is what lets this variant keep 440 pt cards.
private struct TVLibraryStatusBand: View {
    let state: EmptyLibraryState

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            TVLibraryEmptyIcon(state: state, size: 64)
            VStack(alignment: .leading, spacing: 12) {
                Text(TVLibraryEmptyCopy.title(for: state))
                    .font(.title.bold())
                    .lineLimit(1)
                Text(TVLibraryEmptyCopy.message(for: state))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Safety valve for a longer localization only: at the
                    // shipped copy nothing scales.
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The empty state's focusable offerings: Play KataGo, the bundled sample
/// game, and the live self-play demo — the focus engine has somewhere to land,
/// and a brand-new user has something to do or watch immediately. No header:
/// the Sample badge and the cards' own titles say what they are, and dropping
/// it reclaims vertical room.
private struct TVLibraryEmptyCards: View {
    @FocusState.Binding var focus: LibraryFocus?

    private let cardWidth = TVLibraryLayoutMetrics.cardWidth

    /// The LIVE count — never assume three. Only the Play KataGo card is
    /// unconditional; the sample game and the self-play demo both depend on
    /// the bundled store opening.
    static var cardCount: Int {
        1 + (TVSampleGameStore.sampleGame != nil ? 1 : 0)
            + (TVSampleGameStore.isAvailable ? 1 : 0)
    }

    var body: some View {
        // The regression this row shipped was arithmetic: a third card added
        // to a row budgeted for two. A fourth does not fit either.
        assert(Self.cardCount <= TVLibraryLayoutMetrics.cardsPerRow,
               "\(Self.cardCount) empty-state cards exceed the \(TVLibraryLayoutMetrics.cardsPerRow) that fit one row")
        return HStack(spacing: TVLibraryLayoutMetrics.cardSpacing) {
            NavigationLink(value: NewGameRoute()) {
                TVPlayKataGoCard()
                    .frame(width: cardWidth)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.card)
            .focused($focus, equals: .playKataGo)

            if let sample = TVSampleGameStore.sampleGame {
                NavigationLink(value: sample) {
                    // Size the LABEL, not the button (an outer frame never
                    // reaches the board inside), and pin the ideal height: the
                    // surrounding stack proposes a squeezed height, which would
                    // otherwise shrink the aspect-fit board to a thumbnail.
                    //
                    // The one card that is cover art rather than a row. The
                    // sample record parks its cursor at move 0 so review opens
                    // at the start of the 1846 game, so drawing the cursor
                    // would offer a brand-new user an EMPTY board as the
                    // invitation to watch it. The finished position is what
                    // this card is advertising.
                    TVGameCard(game: sample, depicting: .finishedGame)
                        .frame(width: cardWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .overlay(alignment: .topTrailing) { TVLibrarySampleBadge() }
                }
                .buttonStyle(.card)
                .focused($focus, equals: .sample)
            }
            if TVSampleGameStore.isAvailable {
                NavigationLink(value: SelfPlayRoute(entry: .manual)) {
                    TVSelfPlayCard()
                        .frame(width: cardWidth)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.card)
                .focused($focus, equals: .selfPlay)
            }
        }
    }
}

private struct TVLibrarySampleBadge: View {
    var body: some View {
        Text("Sample")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tvWoodAccent, in: Capsule())
            .padding(10)
    }
}

/// The empty library: a full-width status band above one row of full-size
/// cards.
///
/// The original put the status BESIDE the cards, and that is what made it
/// fragile — a text column sharing a row with rigid 440 pt cards gets only the
/// leftover width, and "leftover" became ~140 pt the moment a third card was
/// added. Stacking gives the prose the full 1620 pt, the only arrangement in
/// which every title and every message fits on one line (CLAUDE.md's standing
/// tvOS constraint) while the cards keep the width their own labels need.
/// Two side-by-side alternatives were built and rendered; both were rejected
/// from the screenshots — shrinking the cards truncated their titles, and a
/// scrolling shelf pushed the third card off the screen edge.
private struct TVLibraryEmptyState: View {
    let state: EmptyLibraryState
    @FocusState.Binding var focus: LibraryFocus?

    var body: some View {
        VStack(spacing: 56) {
            TVLibraryStatusBand(state: state)
                .frame(maxWidth: .infinity, alignment: .leading)
            TVLibraryEmptyCards(focus: $focus)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, TVLibraryLayoutMetrics.horizontalPadding)
        .padding(.vertical, 60)
    }
}

#if DEBUG
/// The empty state under the REAL chrome — tab bar, navigation stack,
/// navigation title.
///
/// The chrome is the point, and this preview is kept for that reason: the
/// plain `TVLibraryView()` previews below mount no `TabView`, so they cannot
/// show the vertical budget the tab bar actually leaves, nor whether the
/// status band crowds the "KataGo Anytime" navigation title — the two hazards
/// that decided this layout.
private struct TVLibraryEmptyStatePreview: View {
    let state: EmptyLibraryState
    @FocusState private var focus: LibraryFocus?

    var body: some View {
        TabView {
            NavigationStack {
                TVLibraryEmptyState(state: state, focus: $focus)
                    .navigationTitle("KataGo Anytime")
            }
            .tabItem { Text("Library") }
            Text("Search").tabItem { Text("Search") }
            Text("Settings").tabItem { Text("Settings") }
        }
    }
}
#endif

/// The "Play KataGo" entry card: routes to `TVNewGameScreen`. Not a specific
/// game (there is no board to thumbnail yet), so an icon fills the same
/// square slot a board thumbnail would — matching `TVGameCard`/`TVSelfPlayCard`
/// framing/padding keeps the grid's card heights uniform.
struct TVPlayKataGoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.tvWoodAccent.opacity(0.18))
                Image(systemName: "person.2.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.tvWoodAccent)
            }
            .aspectRatio(1, contentMode: .fit)
            .padding([.top, .horizontal], 20)

            VStack(alignment: .leading, spacing: 6) {
                Text("Play KataGo")
                    .font(.headline)
                    .lineLimit(1)
                // Was "Human vs KataGo — rank, rules, handicap": at Subhead 38
                // that wants ~780 pt inside a 404 pt card, so it truncated at
                // the shipped 440 pt width and would truncate harder in any
                // layout that shrinks the cards. Cut to fit, per CLAUDE.md.
                Text("Human vs KataGo")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TVGameCard: View {
    /// Which position a card draws. Rows take `.cursor`; only the bundled
    /// sample card takes `.finishedGame`, and it says why at that call site.
    enum Depiction {
        /// The move the game is parked on — what a library row means.
        case cursor
        /// The position after every recorded move, whatever the cursor says.
        case finishedGame
    }

    let game: GameRecord
    var depicting: Depiction = .cursor

    /// Cached, not a plain computed property: `TVPlayability.isPlayable`
    /// transitively parses the game's SGF through the C++ bridge
    /// (`SelfPlayGame.recordedGameIsFinished`) — materially heavier than the
    /// card's other per-render computed properties, and a LazyVGrid re-renders
    /// cards often (tvOS focus-driven scroll). Hoisted once, mirroring
    /// TVReviewScreen's `recordedIsFinished` precedent (also a one-shot SGF
    /// parse cached into @State rather than repeated per access). Computed
    /// here — not by the caller — so both call sites (library grid and
    /// search results) inherit the badge without repeating the
    /// classification; refreshed on `.onChange` of the game's identity in
    /// case a LazyVGrid ever reuses a card instance for a different record.
    @State private var isPlayable = false

    /// The board this card draws: the record's own SGF replayed to the record's
    /// own cursor — the same projection the iOS and macOS library rows make
    /// (ADR 0014), so every library surface depicts one game one way.
    ///
    /// This used to read the per-index `blackStones`/`whiteStones` cache, with
    /// the highest visited move as a fallback when `currentIndex` had no entry.
    /// Only a host running the position projector fills that cache, so an index
    /// no host ever visited fell through to the fallback and the card drew a
    /// DIFFERENT move of the game than the phone was showing.
    /// `GobanState.cloneCurrentPosition` makes exactly such a record: saving a
    /// branch as a new game parks `currentIndex` on the branch tip while
    /// trimming the dictionaries back to the divergence point, so the card drew
    /// the divergence and the phone drew the tip. A replay of the record cannot
    /// disagree with the record.
    ///
    /// Geometry comes from the replay too, never from the cached
    /// `width`/`height` fields, so the grid can never contradict the stones
    /// standing on it.
    ///
    /// Not hoisted into `@State` like `isPlayable` above: the parse behind this
    /// is memoized process-wide by `RecordBoardPreviewSource`'s LRU, keyed on a
    /// `RecordPositionKey` that carries the SGF by value — so a card
    /// self-invalidates when its game gets a move, which a one-shot `@State`
    /// capture would not.
    private var preview: RecordBoardPreview? {
        switch depicting {
        case .cursor: RecordBoardPreviewSource.preview(for: game)
        case .finishedGame: RecordBoardPreviewSource.finishedGamePreview(for: game)
        }
    }

    var body: some View {
        // The board sits inset within the card so the .card style's rounded
        // clip never cuts its corners — a Go board must read as a complete
        // rectangle, framed by the card surface. Name/date keep their own
        // inset block below.
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let preview {
                    WidgetBoardView(width: preview.width,
                                    height: preview.height,
                                    blackVertices: preview.blackVertices,
                                    whiteVertices: preview.whiteVertices,
                                    lastMoveVertex: preview.lastMoveVertex,
                                    style: .appGoban(drawsOwnWood: true))
                } else {
                    // An SGF the parser rejects draws no board rather than a
                    // confidently wrong one — the iOS row's placeholder and the
                    // watch's `isReadable` gate make the same call. Same frame
                    // as the board so an unreadable card keeps its height and
                    // the grid row stays aligned.
                    Image(systemName: "square.grid.3x3")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(40)
                        .accessibilityLabel("Unreadable game record")
                }
            }
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
        .overlay(alignment: .topTrailing) {
            // Purely decorative: no gesture, no focus — the card itself
            // (via the enclosing NavigationLink) carries the tap target.
            if isPlayable {
                continueBadge
            }
        }
        .onAppear { refreshIsPlayable() }
        .onChange(of: game.persistentModelID) { _, _ in refreshIsPlayable() }
    }

    private func refreshIsPlayable() {
        isPlayable = TVPlayability.isPlayable(game)
    }

    private var continueBadge: some View {
        Text("Continue")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tvWoodAccent, in: Capsule())
            .padding(10)
    }
}

// MARK: - Search

/// The dedicated Search tab: a name filter over the synced library. tvOS
/// presents a view's `.searchable` as a full-screen keyboard, so it lives in
/// its own tab (keeping the Library grid uncluttered rather than pinning the
/// keyboard above it). Filtering is name-only (`localizedStandardContains`),
/// matching iOS/macOS — player names live only inside the SGF and are not
/// searchable without a per-game parse. Selecting a result pushes the review
/// screen inside the Search tab's own stack.
struct TVSearchView: View {
    @Query(sort: \GameRecord.lastModificationDate, order: .reverse) private var gameRecords: [GameRecord]
    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 48)]

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    private var results: [GameRecord] {
        guard isSearching else { return [] }
        return gameRecords.filter { $0.name.localizedStandardContains(trimmedQuery) }
    }

    var body: some View {
        Group {
            if !isSearching {
                message(title: "Search your games",
                        subtitle: "Type a game's name to find it.")
            } else if results.isEmpty {
                message(title: "No games match \u{201C}\(trimmedQuery)\u{201D}",
                        subtitle: "Try a different name.")
            } else {
                resultsGrid
            }
        }
        .navigationTitle("Search")
        .searchable(text: $searchText, placement: .automatic, prompt: "Search games by name")
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 48) {
                ForEach(results) { game in
                    NavigationLink(value: game) {
                        TVGameCard(game: game)
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 60)
            .focusSection()
        }
    }

    private func message(title: String, subtitle: String) -> some View {
        VStack(spacing: 22) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 90)
        .padding(.vertical, 60)
    }
}

// MARK: - Previews

// #Preview bodies still compile in Release, and the TVPreviewData fixtures are
// DEBUG-only — guard the whole section or archiving fails.
#if DEBUG
// Grid path: three cards exercising a named+dated 19×19, an untitled/undated
// game whose cursor sits past the end of its SGF, and a 9×9 board.
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
    .environment(TVAttractModeController())
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
    .environment(TVAttractModeController())
}

// The four empty states. Each also shows the bundled sample-game card.
#Preview("Library — syncing") {
    NavigationStack { TVLibraryView() }
        .modelContainer(TVPreviewData.container(games: []))
        .environment(CloudKitSyncMonitor.fixture(importInFlight: true))
        .environment(TVAttractModeController())
}

#Preview("Library — signed out") {
    NavigationStack { TVLibraryView() }
        .modelContainer(TVPreviewData.container(games: []))
        .environment(CloudKitSyncMonitor.fixture(accountState: .unavailable))
        .environment(TVAttractModeController())
}

#Preview("Library — iCloud unavailable") {
    NavigationStack { TVLibraryView() }
        .modelContainer(TVPreviewData.container(games: []))
        .environment(CloudKitSyncMonitor.fixture(storeMode: .localOnly))
        .environment(TVAttractModeController())
}

#Preview("Library — truly empty") {
    NavigationStack { TVLibraryView() }
        .modelContainer(TVPreviewData.container(games: []))
        .environment(CloudKitSyncMonitor.fixture(graceExpired: true))
        .environment(TVAttractModeController())
}

// Under the real tab bar and navigation title, on the two longest strings of
// the four states — the title that reported the bug, and the longest message.
// Judge: does any text wrap or truncate, and does the band crowd the title?
#Preview("Empty — full chrome, syncing") {
    TVLibraryEmptyStatePreview(state: .syncing)
        .modelContainer(TVPreviewData.container(games: []))
}

#Preview("Empty — full chrome, iCloud unavailable") {
    TVLibraryEmptyStatePreview(state: .unavailable)
        .modelContainer(TVPreviewData.container(games: []))
}

// Card branches side by side: a cursor inside the game + name + date (left) vs
// a cursor past its end + "Untitled" + hidden date (right). Both must draw the
// five-move opening — the right one by clamping — and mark the last move.
#Preview("Game cards") {
    HStack(spacing: 60) {
        TVGameCard(game: TVPreviewData.openingGame())
        TVGameCard(game: TVPreviewData.untitledFallbackGame())
    }
    .frame(maxWidth: 900)
    .padding(80)
}

#Preview("Play KataGo card") {
    TVPlayKataGoCard()
        .frame(width: 400)
        .padding(80)
}
#endif
