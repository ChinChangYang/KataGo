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

    /// visionOS's glass texture composites widget content over DARK glass, so
    /// glass-backed plans pin the dark scheme there; elsewhere glass stays
    /// adaptive. Injected into the resolver so the mapping is testable.
    private var glassPrefersDarkScheme: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }

    /// One authority for backplate, scheme pin, board style, and whether the
    /// board draws its own wood card — tint (accented mode) wins over the
    /// user's background choice.
    private var backgroundPlan: WidgetBackgroundPlan.Plan {
        WidgetBackgroundPlan.resolve(background: entry.background,
                                     isAccented: renderingMode == .accented,
                                     glassPrefersDarkScheme: glassPrefersDarkScheme)
    }

    // Always render the crisp VECTOR board, never a stored bitmap. The persisted
    // `GameRecord.thumbnail` is a small, lossy HEIC snapshot rendered at the in-app
    // detail size (≤128pt); upscaling it to a large widget produced a blurry board.
    // `WidgetBoardView` redraws the SAME position (the snapshot already carries
    // `lastBlackStones`/`lastWhiteStones` + board size) as sharp vectors at any
    // family size, and keeps a heavy Data blob out of the memory-constrained appex.
    private var board: some View {
        let plan = backgroundPlan
        return WidgetBoardView(width: entry.snapshot.boardWidth,
                        height: entry.snapshot.boardHeight,
                        blackVertices: entry.snapshot.lastBlackStones,
                        whiteVertices: entry.snapshot.lastWhiteStones,
                        style: plan.boardStyle,
                        woodImage: WidgetWoodTexture.sharedSquareImage())
            // Keep the goban square. WidgetBoardView is a greedy GeometryReader with
            // no intrinsic size, so in the non-square medium/large layouts it would
            // otherwise paint the wooden background across the whole rectangle with a
            // small centred grid floating in wide tan margins. The old bitmap path
            // got this for free via `.aspectRatio(contentMode: .fit)`.
            .aspectRatio(1, contentMode: .fit)
            // The wood CARD gets the rounded edge; on the full-bleed Wood
            // backplate the board draws no card, and rounding a cornerless
            // grid would just shave the outer coordinates' hit area.
            .clipShape(RoundedRectangle(cornerRadius: plan.boardDrawsOwnWood ? 6 : 0))
    }

    /// The user-chosen backplate (or the neutral system material while the
    /// widget is tinted). The wood image is the SAME shared bitmap the board
    /// card draws, scaled to fill the container.
    @ViewBuilder private var backplate: some View {
        switch backgroundPlan.backplate {
        case .wood:
            if let wood = WidgetWoodTexture.sharedSquareImage() {
                Image(decorative: wood, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(red: WidgetBoardStyle.gobanWood.red,
                      green: WidgetBoardStyle.gobanWood.green,
                      blue: WidgetBoardStyle.gobanWood.blue)
            }
        case .glass, .neutralAccent:
            // Today's translucent system material (the glass backdrop layer
            // on visionOS); also what the accent tint recolors.
            Color.clear.background(.fill.tertiary)
        case .light:
            Color(white: 0.96)
        case .dark:
            Color(white: 0.12)
        }
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
        .containerBackground(for: .widget) {
            backplate
        }
        // Per-backplate contrast, the generalization of the visionOS glass
        // black-on-black fix (340df0cd): Wood/Light pin the LIGHT scheme so
        // .primary reads as dark ink even in system dark mode; Dark (and
        // glass over visionOS's dark glass) pin DARK so labels stay bright;
        // adaptive glass elsewhere inherits (nil pin).
        .transformEnvironment(\.colorScheme) { scheme in
            switch backgroundPlan.colorSchemePin {
            case .light: scheme = .light
            case .dark: scheme = .dark
            case nil: break
            }
        }
    }
}
