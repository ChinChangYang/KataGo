import WidgetKit
import SwiftUI
import KataGoGameStore

struct SavedGameWidgetView: View {
    @Environment(\.widgetFamily) private var family
    // Accented = the user tinted the widget (visionOS palette, iOS tinted
    // Home Screen, macOS). The board's two-tone adaptation lives behind
    // WidgetBoardStyle so it is testable and tvOS-safe in the package.
    @Environment(\.widgetRenderingMode) private var renderingMode
    #if os(visionOS)
    // Distance threshold: board + big name only. The environment exists only
    // on the xros slice; elsewhere the widget always renders the full layout.
    @Environment(\.levelOfDetail) private var levelOfDetail
    private var isSimplified: Bool { levelOfDetail == .simplified }
    #else
    private var isSimplified: Bool { false }
    #endif
    let entry: SavedGameEntry

    private var layoutFamily: SavedGameWidgetLayout.Family {
        switch family {
        case .systemSmall: .small
        case .systemLarge: .large
        case .systemExtraLarge: .extraLarge
        default: .medium
        }
    }

    private var boardStyle: WidgetBoardStyle {
        renderingMode == .accented ? .accented : .standard
    }

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
                        whiteVertices: entry.snapshot.lastWhiteStones,
                        style: boardStyle)
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
        let plan = SavedGameWidgetLayout.plan(family: layoutFamily,
                                              isSimplified: isSimplified,
                                              hasComment: !snap.comment.isEmpty,
                                              moveCount: snap.moveCount)
        Group {
            if plan.isSimplified {
                // One shared distance layout for every family: the board (the
                // continuity element across the LOD transition) plus the game
                // name in large type — glanceable from across the room.
                VStack(spacing: 6) {
                    board
                    Text(snap.name)
                        .font(.title2).bold()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .widgetAccentable()
                }
            } else {
                switch layoutFamily {
                case .small:
                    VStack(spacing: 4) {
                        board
                        Text(snap.name).font(.caption).bold().lineLimit(1)
                            .widgetAccentable()
                    }
                case .large:
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snap.name).font(.headline).lineLimit(1)
                            .widgetAccentable()
                        board.frame(maxHeight: .infinity)
                        // The displayed move often has no comment; drop the Text entirely
                        // rather than let an empty line eat the VStack spacing.
                        if plan.showsComment {
                            Text(snap.comment).font(.callout).lineLimit(6)
                        }
                    }
                case .extraLarge:
                    // The extra-large family is wide (~2:1), so spend the room on WIDTH:
                    // a big square board on the leading side (height-bounded, then sized to
                    // a square by the 1:1 aspect) and a roomy info column trailing.
                    HStack(spacing: 16) {
                        board.frame(maxHeight: .infinity)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(snap.name).font(.title2).bold().lineLimit(2)
                                .widgetAccentable()
                            if plan.showsMoveCount {
                                Text("Move \(snap.moveCount)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if plan.showsComment {
                                Text(snap.comment).font(.body)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .medium:
                    HStack(spacing: 10) {
                        board
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snap.name).font(.headline).lineLimit(1)
                                .widgetAccentable()
                            if plan.showsComment {
                                Text(snap.comment).font(.caption).lineLimit(3)
                            }
                            Spacer(minLength: 0)
                        }
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
        // With the visionOS glass texture this renders as the glass backdrop
        // layer while the content above stays bright; unchanged elsewhere.
        .containerBackground(.fill.tertiary, for: .widget)
        #if os(visionOS)
        // The glass texture composites content over DARK glass, but the
        // widget's inherited color scheme stays light, so default label
        // colors resolved to black-on-black (verified in the simulator:
        // the game name was laid out yet invisible). Pin the content to
        // the dark scheme so .primary/.secondary stay bright over glass —
        // the HIG's "foreground elements always stay bright" for glass.
        .environment(\.colorScheme, .dark)
        #endif
    }
}
