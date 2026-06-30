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
            case .systemExtraLarge:
                // The extra-large family is wide (~2:1), so spend the room on WIDTH:
                // a big square board on the leading side (height-bounded, then sized to
                // a square by the 1:1 aspect) and a roomy info column trailing.
                HStack(spacing: 16) {
                    board.frame(maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snap.name).font(.title2).bold().lineLimit(2)
                        if snap.moveCount > 0 {
                            Text("Move \(snap.moveCount)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(snap.firstComment).font(.body)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        // Route the tap to the user's EXPLICIT configured game, falling back to the
        // displayed game's id only when the widget is unconfigured. `snap.gameID` is
        // the resolved DISPLAY id, which can fall back to most-recent when the
        // configured game momentarily can't be resolved; using it for the tap would
        // open a game the user didn't pick. See `SavedGameSnapshot.configuredGameID`.
        .widgetURL((snap.configuredGameID ?? snap.gameID).map(GameDeepLink.url(for:)))
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
