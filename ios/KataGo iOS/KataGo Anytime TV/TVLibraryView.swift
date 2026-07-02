//
//  TVLibraryView.swift
//  KataGo Anytime TV
//
//  The lean-back library: a focusable grid of the iCloud-synced saved games.
//  Each card is a crisp vector board thumbnail (WidgetBoardView) — no engine.
//  Selecting a card pushes the read-only review screen.
//

import SwiftUI
import SwiftData
import KataGoUICore

struct TVLibraryView: View {
    @Query(sort: \GameRecord.lastModificationDate, order: .reverse) private var gameRecords: [GameRecord]

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 48)]

    var body: some View {
        Group {
            if gameRecords.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 48) {
                        ForEach(gameRecords) { game in
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
        }
        .navigationTitle("KataGo")
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            Text("No games yet")
                .font(.title2.bold())
            Text("Games you create on iPhone, iPad, or Mac appear here automatically once they sync from iCloud.")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 800)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(120)
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
        // Board thumbnail runs edge-to-edge; the name/date sit in an inset block
        // so they don't crowd the card boundary.
        VStack(alignment: .leading, spacing: 0) {
            WidgetBoardView(width: game.width ?? 19,
                            height: game.height ?? 19,
                            blackVertices: vertices.black,
                            whiteVertices: vertices.white)
                .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 6) {
                Text(game.name.isEmpty ? "Untitled" : game.name)
                    .font(.headline)
                    .lineLimit(1)
                if let date = game.lastModificationDate {
                    Text(date, format: .dateTime.year().month().day())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
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
}

// Empty-library path ("No games yet" guidance).
#Preview("Library — empty") {
    TVLibraryView()
        .modelContainer(TVPreviewData.container(games: []))
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
