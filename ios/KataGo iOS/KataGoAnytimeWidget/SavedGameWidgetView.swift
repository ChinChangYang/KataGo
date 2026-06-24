import WidgetKit
import SwiftUI
import KataGoGameStore

struct SavedGameWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SavedGameEntry

    // Always render the crisp VECTOR board, never a stored bitmap. The persisted
    // `GameRecord.thumbnail` is a small, lossy HEIC snapshot rendered at the in-app
    // detail size (≤128pt); upscaling it to a large widget produced a blurry board.
    // `WidgetBoardView` redraws the SAME position (the snapshot already carries
    // `lastBlackStones`/`lastWhiteStones` + board size) as sharp vectors at any
    // family size, and keeps a heavy Data blob out of the memory-constrained appex.
    private var board: some View {
        WidgetBoardView(width: entry.snapshot.boardWidth,
                        height: entry.snapshot.boardHeight,
                        blackVertices: entry.snapshot.lastBlackStones,
                        whiteVertices: entry.snapshot.lastWhiteStones)
            // Keep the goban square. WidgetBoardView is a greedy GeometryReader with
            // no intrinsic size, so in the non-square medium/large layouts it would
            // otherwise paint the wooden background across the whole rectangle with a
            // small centred grid floating in wide tan margins. The old bitmap path
            // got this for free via `.aspectRatio(contentMode: .fit)`.
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    var body: some View {
        let snap = entry.snapshot
        Group {
            switch family {
            case .systemSmall:
                VStack(spacing: 4) {
                    board
                    Text(snap.name).font(.caption).bold().lineLimit(1)
                }
            case .systemLarge:
                VStack(alignment: .leading, spacing: 6) {
                    Text(snap.name).font(.headline).lineLimit(1)
                    board.frame(maxHeight: .infinity)
                    Text(snap.firstComment).font(.callout).lineLimit(6)
                }
            default: // .systemMedium
                HStack(spacing: 10) {
                    board
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snap.name).font(.headline).lineLimit(1)
                        Text(snap.firstComment).font(.caption).lineLimit(3)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .widgetURL(snap.gameID.map(GameDeepLink.url(for:)))
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
