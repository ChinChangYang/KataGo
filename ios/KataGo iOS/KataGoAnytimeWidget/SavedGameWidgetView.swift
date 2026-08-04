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

    /// visionOS's system glass texture (`.widgetTexture(.glass)`) composites
    /// widget content over DARK glass. Only the accented plan still renders
    /// over that glass, so only it consumes the flag — injected into the
    /// resolver so the mapping is testable.
    private var glassPrefersDarkScheme: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }

    /// iOS/macOS widgets render the app-parity board (the bundled wood.png,
    /// black grid, the app's bold coordinate labels); visionOS keeps the
    /// goban-palette look that matches its 3D goban. Injected into the
    /// resolver so the mapping is testable, like `glassPrefersDarkScheme`.
    private var usesAppBoardStyle: Bool {
        #if os(visionOS)
        false
        #else
        true
        #endif
    }

    /// One authority for backplate, scheme pin, board style, and whether the
    /// board draws its own wood card — tint (accented mode) wins over the
    /// user's background choice.
    private var backgroundPlan: WidgetBackgroundPlan.Plan {
        WidgetBackgroundPlan.resolve(background: entry.background,
                                     isAccented: renderingMode == .accented,
                                     glassPrefersDarkScheme: glassPrefersDarkScheme,
                                     usesAppBoardStyle: usesAppBoardStyle)
    }

    // Always render the crisp VECTOR board, never a stored bitmap. The persisted
    // `GameRecord.thumbnail` is a small, lossy HEIC snapshot rendered at the in-app
    // detail size (≤128pt); upscaling it to a large widget produced a blurry board.
    // `WidgetBoardView` redraws the SAME position (the snapshot already carries
    // `lastBlackStones`/`lastWhiteStones` + board size) as sharp vectors at any
    // family size, and keeps a heavy Data blob out of the memory-constrained appex.
    private func board(showsCoordinates: Bool) -> some View {
        let plan = backgroundPlan
        // Only the procedural-wood style (visionOS goban) needs the generated
        // CGImage; the appGoban board draws the bundled asset, so the
        // iOS/macOS appex never pays for the texture cache.
        return WidgetBoardView(width: entry.snapshot.boardWidth,
                        height: entry.snapshot.boardHeight,
                        blackVertices: entry.snapshot.lastBlackStones,
                        whiteVertices: entry.snapshot.lastWhiteStones,
                        // Layout says whether coordinates are WANTED here (the
                        // visionOS distance view doesn't); WidgetBoardView still
                        // gates on cell pitch, so a board too small to draw them
                        // without truncating drops them regardless.
                        showCoordinates: showsCoordinates,
                        style: plan.boardStyle,
                        woodImage: plan.boardStyle.usesWoodImage
                            ? WidgetWoodTexture.sharedSquareImage() : nil)
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

    /// Comment switched off, on the two WIDE families (~2:1): the board takes
    /// the container's FULL height — the biggest square the family can hold —
    /// and the name sits beside it, centred in the width the square leaves over.
    ///
    /// `layoutPriority(1)` is what makes "full height" a GUARANTEE rather than a
    /// coincidence. An HStack sizes its children least-flexible-first and offers
    /// each only `remaining / childrenLeft` — half the row, for this pair. A 1:1
    /// `.fit` board answers `min(width, height)`, so the moment half the row is
    /// narrower than the container is tall (a family closer to 2:1 than iOS's, a
    /// future device, a name column with a large minimum width) the square
    /// silently shrinks to that half. Sizing the board FIRST against the whole
    /// remaining width lands `min(width, height)` on the height every time.
    private func boardBesideName(plan: SavedGameWidgetLayout.Plan,
                                 spacing: CGFloat,
                                 name: Text,
                                 nameLines: Int) -> some View {
        HStack(spacing: spacing) {
            board(showsCoordinates: plan.showsCoordinates)
                // Holds the ROW at full height even if the square ever came out
                // smaller than the container: the square then centres in its
                // slot instead of collapsing the stack.
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            name
                .lineLimit(nameLines)
                .minimumScaleFactor(0.6)
                .widgetAccentable()
                // maxWidth holds the row at full width — without it a short name
                // shrinks the HStack and the widget CENTRES the pair, pulling the
                // board off the leading edge. maxHeight + `.leading` is the
                // vertical centring: `.leading` is leading horizontally and
                // CENTER vertically.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// The user-chosen backplate (or the neutral system material while the
    /// widget is tinted). The wood image is the SAME shared bitmap the board
    /// card draws, scaled to fill the container.
    @ViewBuilder private var backplate: some View {
        switch backgroundPlan.backplate {
        case .wood:
            if usesAppBoardStyle {
                // The same bundled wood.png the appGoban board (and the in-app
                // board) draws — one wood everywhere, no grain mismatch.
                Image(decorative: "Wood", bundle: .kataGoGameStore)
                    .resizable()
                    .scaledToFill()
            } else if let wood = WidgetWoodTexture.sharedSquareImage() {
                Image(decorative: wood, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(red: WidgetBoardStyle.gobanWood.red,
                      green: WidgetBoardStyle.gobanWood.green,
                      blue: WidgetBoardStyle.gobanWood.blue)
            }
        case .material(let material):
            // Same rendering as the wood, from the per-material memoized
            // texture — the board draws its own wood card on top.
            if let texture = WidgetBackplateTexture.sharedSquareImage(material) {
                Image(decorative: texture, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(red: material.baseColor.red,
                      green: material.baseColor.green,
                      blue: material.baseColor.blue)
            }
        case .neutralAccent:
            // The translucent system material the accent tint recolors.
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
                                              commentIsEnabled: entry.showsComment,
                                              hasComment: !snap.comment.isEmpty,
                                              moveCount: snap.moveCount)
        Group {
            if plan.isSimplified {
                // One shared distance layout for every family: the board (the
                // continuity element across the LOD transition) plus the game
                // name in large type — glanceable from across the room.
                VStack(spacing: 6) {
                    board(showsCoordinates: plan.showsCoordinates)
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
                        board(showsCoordinates: plan.showsCoordinates)
                        Text(snap.name).font(.caption).bold().lineLimit(1)
                            .widgetAccentable()
                    }
                case .large:
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snap.name).font(.headline).lineLimit(1)
                            .widgetAccentable()
                        board(showsCoordinates: plan.showsCoordinates)
                            .frame(maxHeight: .infinity)
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
                    //
                    // With the comment switched off that column holds only the
                    // name, so the board claims the row and the name centres
                    // beside it. Branching at the family level (rather than
                    // threading conditional modifiers through one stack) keeps
                    // the else-branch BYTE-IDENTICAL to what ships today, so
                    // "unchanged when the comment is on" is structural.
                    if plan.boardFillsHeight {
                        boardBesideName(plan: plan, spacing: 16,
                                        name: Text(snap.name).font(.title2).bold(),
                                        nameLines: 3)
                    } else {
                        HStack(spacing: 16) {
                            board(showsCoordinates: plan.showsCoordinates)
                                .frame(maxHeight: .infinity)
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
                    }
                case .medium:
                    if plan.boardFillsHeight {
                        boardBesideName(plan: plan, spacing: 10,
                                        name: Text(snap.name).font(.headline),
                                        nameLines: 2)
                    } else {
                        HStack(spacing: 10) {
                            board(showsCoordinates: plan.showsCoordinates)
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
        // black-on-black fix (340df0cd): the pale backplates (Wood/Light/
        // Tatami/Sky) pin the LIGHT scheme so .primary reads as dark ink even
        // in system dark mode; the dark ones (Dark/Grass/Slate, and accented
        // over visionOS's dark glass) pin DARK so labels stay bright; the
        // accented widget elsewhere inherits (nil pin).
        .transformEnvironment(\.colorScheme) { scheme in
            switch backgroundPlan.colorSchemePin {
            case .light: scheme = .light
            case .dark: scheme = .dark
            case nil: break
            }
        }
    }
}
