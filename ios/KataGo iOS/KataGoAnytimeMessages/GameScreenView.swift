//
//  GameScreenView.swift
//  KataGoAnytimeMessages
//
//  The board screen for every phase. Playing: tap places a ghost stone
//  (drag to adjust), Confirm stages the move bubble — Messages' send arrow
//  is the final confirm. Scoring: tap toggles dead groups locally, with a
//  live score readout; propose / accept / dispute all travel as bubbles.
//  The board is view-only when it is not the local player's turn.
//

import SwiftUI
import GoRulesKit
import KataGoGameStore

/// Taps and overlays, hit-tested against the SAME `WidgetBoardGeometry` the
/// board renders from — including the coordinate margin, which shifts both the
/// cell pitch and the origin. This used to recompute the layout with the
/// margin hardcoded to 0, which was right only while coordinates were off.
struct BoardTapGeometry {
    let grid: WidgetBoardGeometry

    init(width: Int, height: Int, size: CGSize, showCoordinates: Bool) {
        grid = WidgetBoardGeometry(width: width, height: height,
                                   size: size, showCoordinates: showCoordinates)
    }

    var cell: CGFloat { grid.cell }

    func gridPoint(at location: CGPoint) -> GoPoint? {
        guard let p = grid.gridPoint(at: location) else { return nil }
        return GoPoint(x: p.x, y: p.y)
    }

    func position(of p: GoPoint) -> CGPoint {
        grid.position(x: p.x, y: p.y)
    }
}

struct GameScreenView: View {
    /// The state decoded from the selected bubble.
    let message: MessageGame
    let isLocalTurn: Bool
    let staged: Bool
    let actions: ExtensionActions

    @State private var ghost: GoPoint?
    @State private var confirmingResign = false
    @State private var confirmingOpenInApp = false
    /// Local scoring edits before proposing (nil = incoming state as-is).
    @State private var workingGame: MessageGame?

    private var effectiveMessage: MessageGame { workingGame ?? message }
    private var game: GoGame { effectiveMessage.game }
    private var interactive: Bool { isLocalTurn && !staged }

    /// Board is the point of this screen, so it gets a floor: the board is the
    /// only truly flexible child, and at accessibility text sizes the grown
    /// header and stacked buttons ate ALL of it — a 19x19 collapsed to a few
    /// points. Below the floor the sheet scrolls instead of squeezing.
    private static let minimumBoardHeight: CGFloat = 160
    private static let contentPadding: CGFloat = 16
    private static let rowSpacing: CGFloat = 8

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                BoardScreenLayout(
                    availableHeight: outer.size.height - Self.contentPadding * 2,
                    boardWidth: game.board.width,
                    boardHeight: game.board.height,
                    spacing: Self.rowSpacing,
                    minimumBoardHeight: Self.minimumBoardHeight
                ) {
                    header
                    board
                    footer
                }
                .padding(Self.contentPadding)
            }
            // Only reachable at accessibility text sizes now: the board is
            // fitted to the sheet, so ordinary sizes have nothing to scroll.
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: - Header

    /// The board below is flexible (`aspectRatio(contentMode: .fit)`), so in
    /// the short expanded sheet the VStack squeezes the header instead — and a
    /// `Text` given too little height TRUNCATES rather than wrapping. At
    /// accessibility sizes that turned the scoring prompt into "Mark dead
    /// sto…". `fixedSize` makes it claim its wrapped height; `lineLimit(3)`
    /// stops the claim from running away and starving the board.
    @ViewBuilder
    private var header: some View {
        headerContent
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var headerContent: some View {
        switch game.phase {
        case .playing:
            HStack {
                Circle()
                    .fill(game.toMove == .black ? Color.black : .white)
                    .stroke(.secondary, lineWidth: 1)
                    .frame(width: 14, height: 14)
                Text(statusText).font(.headline)
                Spacer()
                Text("Move \(game.moves.count + 1)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .scoring:
            VStack(alignment: .leading, spacing: 2) {
                Text(interactive ? "Mark dead stones, then propose the score" : statusText)
                    .font(.headline)
                Text("Current count: \(game.scoreNow().result.shortText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .finished(let result):
            Text(BubbleRenderer.resultText(result))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusText: String {
        if staged { return "Tap send to deliver" }
        if isLocalTurn {
            return game.phase == .scoring ? "Review the score" : "Your move"
        }
        return "Waiting for opponent"
    }

    // MARK: - Board

    private var board: some View {
        GeometryReader { geo in
            let geometry = BoardTapGeometry(
                width: game.board.width, height: game.board.height, size: geo.size,
                showCoordinates: MessagesBoardStyle.showsCoordinates)
            ZStack {
                WidgetBoardView(
                    width: game.board.width,
                    height: game.board.height,
                    blackVertices: game.board.gtpVertices(of: .black),
                    whiteVertices: game.board.gtpVertices(of: .white),
                    lastMoveVertex: lastMoveVertex,
                    showCoordinates: MessagesBoardStyle.showsCoordinates,
                    style: MessagesBoardStyle.board)
                    // The board floats on the sheet here, so it casts the app
                    // board's shadow. `.background` keeps the caster exactly
                    // the board's own rect and — crucially — leaves `geo.size`
                    // alone, so `BoardTapGeometry` above still hit-tests
                    // against the grid that is actually drawn.
                    .background {
                        MessagesBoardStyle.shadowCaster(cell: shadowCell(geometry.cell))
                    }
                overlays(geometry: geometry)
            }
            .contentShape(Rectangle())
            // A view-only board must not swallow the scroll pan: this gesture
            // has `minimumDistance: 0`, so while it is attached a drag that
            // starts on the board never reaches the ScrollView. That is what
            // made the sheet feel unscrollable when a board overflowed it.
            .gesture(boardGesture(geometry: geometry),
                     including: interactive ? .all : .none)
        }
    }

    /// The shadow scales with the cell pitch, but the sheet only reserves
    /// `contentPadding` around the board and the ScrollView clips at its
    /// bounds — so on a very small board the shadow would be sheared off
    /// square. A 2x2 fills the width with a ~159 pt pitch, whose shadow reaches
    /// ~50 pt past the slab into 16 pt of room. Capping the pitch the shadow is
    /// derived from keeps it whole; every board from 9x9 up is already under
    /// the cap and is unaffected.
    private func shadowCell(_ cell: CGFloat) -> CGFloat {
        let widest = Self.contentPadding / WidgetBoardStyle.boardShadowExtent(cellSize: 1)
        return min(cell, widest)
    }

    private var lastMoveVertex: String? {
        guard case .play(let p) = game.moves.last else { return nil }
        return p.gtpVertex(boardHeight: game.board.height)
    }

    @ViewBuilder
    private func overlays(geometry: BoardTapGeometry) -> some View {
        // Ghost stone while aiming — the app board's play cursor idiom
        // (`BoardView`): a 0.55-opacity stone of the side to move inside a
        // white ring at 1.15x, with a dark shadow, so it stays legible over
        // wood, over stones, and over the scoring marks.
        if let ghost, game.phase == .playing {
            let stone = geometry.cell * MessagesBoardStyle.board.stoneDiameterRatio
            let center = geometry.position(of: ghost)
            Circle()
                .fill(game.toMove == .black ? Color.black : Color(white: 1.0))
                .opacity(0.55)
                .frame(width: stone, height: stone)
                .position(center)
            Circle()
                .stroke(Color.white, lineWidth: max(3, geometry.cell / 8))
                .frame(width: stone * 1.15, height: stone * 1.15)
                .position(center)
                .shadow(color: .black.opacity(0.6), radius: geometry.cell / 16)
        }
        // Dead marks and counted territory during scoring / after the game.
        if game.phase != .playing {
            territoryAndDeadCanvas(geometry: geometry)
        }
    }

    private func territoryAndDeadCanvas(geometry: BoardTapGeometry) -> some View {
        let board = game.board
        let markedDead = game.markedDead
        let ownership = game.scoreNow().ownership
        return Canvas { context, _ in
            let dot = max(geometry.cell * 0.25, 3)
            for index in 0..<ownership.count where ownership[index] != .empty && board.grid[index] == .empty {
                let center = geometry.position(of: board.point(at: index))
                let rect = CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)
                context.fill(Path(rect), with: .color(ownership[index] == .black ? .black : .white))
            }
            for index in markedDead {
                let center = geometry.position(of: board.point(at: index))
                let arm = max(geometry.cell * 0.3, 3)
                var path = Path()
                path.move(to: CGPoint(x: center.x - arm, y: center.y - arm))
                path.addLine(to: CGPoint(x: center.x + arm, y: center.y + arm))
                path.move(to: CGPoint(x: center.x + arm, y: center.y - arm))
                path.addLine(to: CGPoint(x: center.x - arm, y: center.y + arm))
                context.stroke(path, with: .color(.red), lineWidth: max(geometry.cell * 0.08, 1.5))
            }
        }
        .allowsHitTesting(false)
    }

    private func boardGesture(geometry: BoardTapGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard interactive, game.phase == .playing,
                      let p = geometry.gridPoint(at: value.location) else { return }
                ghost = p
            }
            .onEnded { value in
                guard interactive, let p = geometry.gridPoint(at: value.location) else { return }
                switch game.phase {
                case .playing:
                    ghost = p
                case .scoring:
                    var updated = effectiveMessage
                    updated.game.toggleDead(at: p)
                    workingGame = updated
                case .finished:
                    break
                }
            }
    }

    // MARK: - Footer

    /// The open-in-app dialog hangs off the whole footer rather than one
    /// phase's row, because the action is offered in all three.
    private var footer: some View {
        footerContent
            .confirmationDialog("Open this game in KataGo Anytime?",
                                isPresented: $confirmingOpenInApp,
                                titleVisibility: .visible) {
                Button("Open") { actions.openInApp(effectiveMessage) }
            } message: {
                Text("The game is added to your library.")
            }
    }

    @ViewBuilder
    private var footerContent: some View {
        switch game.phase {
        case .playing:
            controlRow(playingActions)
                .confirmationDialog("Resign this game?", isPresented: $confirmingResign,
                                    titleVisibility: .visible) {
                    Button("Resign", role: .destructive) { sendResign() }
                }
        case .scoring:
            controlRow(scoringActions)
        case .finished:
            controlRow([openInAppAction])
        }
    }

    // MARK: - Control rows
    //
    // "Propose score" + "Accept" + "Resume play" + the open-in-app button
    // needs ~450 pt on one line; the widest iPhone is 440, so that row wrapped
    // on EVERY device, and both rows wrapped one Dynamic Type step above
    // default.
    // `ViewThatFits` walks three tiers instead: full labels, short labels,
    // then a vertical stack that keeps the full words — deliberately not an
    // icon-only tier, since the widths that reach it are large accessibility
    // text sizes, exactly where words matter most.
    //
    // ⚠️ The horizontal tiers must keep their NATURAL width — no `Spacer()`
    // inside a candidate, and no `.frame(maxWidth: .infinity)` — or the
    // candidate reports that it fits at any width and the first tier always
    // wins. Alignment is applied outside the `ViewThatFits`.

    private struct BoardAction: Identifiable {
        let id: String
        let long: String
        let short: String
        /// When set, the horizontal tiers draw this SF Symbol instead of the
        /// text. The vertical tier always spells the action out.
        var systemImage: String?
        var isProminent = false
        var isDestructive = false
        var isEnabled = true
        let run: () -> Void
    }

    private var playingActions: [BoardAction] {
        let canConfirm = ghost.map { game.isLegal(.play($0)) } == true && interactive
        return [
            BoardAction(id: "confirm", long: "Confirm", short: "Confirm",
                        isProminent: true, isEnabled: canConfirm) { confirmGhost() },
            BoardAction(id: "pass", long: "Pass", short: "Pass",
                        isEnabled: interactive) { sendPass() },
            BoardAction(id: "resign", long: "Resign", short: "Resign",
                        isDestructive: true, isEnabled: interactive) { confirmingResign = true },
            openInAppAction,
        ]
    }

    private var scoringActions: [BoardAction] {
        [
            BoardAction(id: "propose", long: "Propose score", short: "Propose",
                        isProminent: true, isEnabled: interactive) {
                actions.stage(effectiveMessage)
            },
            BoardAction(id: "accept", long: "Accept", short: "Accept",
                        isEnabled: interactive) { sendAccept() },
            BoardAction(id: "resume", long: "Resume play", short: "Resume",
                        isEnabled: interactive) { sendDispute() },
            openInAppAction,
        ]
    }

    /// Hands the game to the app. This used to be labelled "Analyze" behind
    /// the app's sparkle, which promised something this screen cannot deliver
    /// — the extension is engine-free and shows no analysis at all. What the
    /// button actually does is add the game to the app's library, and it can
    /// only do that by opening the app: an extension may not write the shared
    /// store (see `AppHandoff`). So it says so, and confirms first, because
    /// tapping it leaves the conversation.
    private var openInAppAction: BoardAction {
        BoardAction(id: "openInApp", long: "Open in App", short: "Open",
                    systemImage: "arrow.up.forward.app") {
            confirmingOpenInApp = true
        }
    }

    private func controlRow(_ items: [BoardAction]) -> some View {
        ViewThatFits(in: .horizontal) {
            actionRow(items, useShortLabels: false)
            actionRow(items, useShortLabels: true)
            actionColumn(items)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(_ items: [BoardAction], useShortLabels: Bool) -> some View {
        HStack {
            ForEach(items) { item in
                actionButton(item, title: useShortLabels ? item.short : item.long,
                             preferIcon: true)
            }
        }
    }

    private func actionColumn(_ items: [BoardAction]) -> some View {
        VStack(spacing: 8) {
            ForEach(items) { item in
                actionButton(item, title: item.long, preferIcon: false, fillsWidth: true)
            }
        }
    }

    /// `fillsWidth` widens the LABEL, not the button: a `.frame(maxWidth:)` on
    /// an already-styled button grows its hit area but leaves the capsule
    /// hugging the text, so the stacked tier came out ragged.
    @ViewBuilder
    private func actionButton(_ item: BoardAction, title: String,
                              preferIcon: Bool, fillsWidth: Bool = false) -> some View {
        let button = Button(role: item.isDestructive ? .destructive : nil) {
            item.run()
        } label: {
            Group {
                if preferIcon, let systemImage = item.systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(title)
                }
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .disabled(!item.isEnabled)
        // The icon tier has no visible words, and even the text tiers may show
        // the SHORT label — so pin a stable speakable name either way.
        .accessibilityLabel(item.id == "openInApp" ? "Open in KataGo Anytime" : item.long)

        if item.isProminent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    // MARK: - Staging

    private func confirmGhost() {
        guard let ghost else { return }
        var updated = message
        guard (try? updated.game.play(.play(ghost))) != nil else { return }
        self.ghost = nil
        actions.stage(updated)
    }

    private func sendPass() {
        var updated = message
        guard (try? updated.game.play(.pass)) != nil else { return }
        ghost = nil
        actions.stage(updated)
    }

    private func sendResign() {
        var updated = message
        updated.game.resign(by: game.toMove)
        actions.stage(updated)
    }

    private func sendAccept() {
        // Accepting locks in the marks exactly as received.
        var updated = message
        updated.game.confirmScore()
        actions.stage(updated)
    }

    private func sendDispute() {
        var updated = message
        updated.game.resumePlay()
        actions.stage(updated)
    }
}

/// Lays out the screen's three rows — header, board, action row — sizing the
/// board to what is left of the sheet and centering the three as one block.
///
/// This is the only custom `Layout` in the app, and it earns that. The board's
/// size depends on how much height the header and action row claim, which is
/// not knowable without measuring them; and inside a `ScrollView` SwiftUI
/// proposes an unspecified height, so the old
/// `.aspectRatio(_:contentMode: .fit)` had nothing but the width to resolve
/// against and sized a 9x19 to ~781 pt in a ~636 pt sheet. A `Layout` measures
/// the chrome and places the board in the SAME pass, so there is no two-frame
/// settle to flicker through and nothing rests on nil-proposal semantics. The
/// arithmetic itself is `BoardSheetFit`, which is unit-tested; this type only
/// measures and places.
private struct BoardScreenLayout: Layout {
    /// The sheet's height net of the screen's padding. Comes from a
    /// `GeometryReader` OUTSIDE the ScrollView, because inside one the
    /// proposal carries no height at all.
    let availableHeight: CGFloat
    let boardWidth: Int
    let boardHeight: Int
    let spacing: CGFloat
    let minimumBoardHeight: CGFloat

    private struct Metrics {
        let fit: BoardSheetFit
        let headerHeight: CGFloat
        let footerHeight: CGFloat
    }

    /// Header and action-row heights depend only on the WIDTH and the text
    /// size, never on the board, so measuring them here cannot feed back into
    /// the board's size and oscillate.
    private func metrics(_ subviews: Subviews, width: CGFloat) -> Metrics {
        let proposal = ProposedViewSize(width: width, height: nil)
        let headerHeight = subviews[0].sizeThatFits(proposal).height
        let footerHeight = subviews[2].sizeThatFits(proposal).height
        return Metrics(
            fit: BoardSheetFit(
                available: CGSize(width: width, height: availableHeight),
                chromeHeight: headerHeight + footerHeight + spacing * 2,
                boardWidth: boardWidth,
                boardHeight: boardHeight,
                minimumBoardHeight: minimumBoardHeight),
            headerHeight: headerHeight,
            footerHeight: footerHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        // Claiming the full sheet height when the block is shorter is what
        // lets the block center; claiming more is what lets the sheet scroll.
        return CGSize(width: width, height: metrics(subviews, width: width).fit.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let metrics = metrics(subviews, width: bounds.width)
        var y = bounds.minY + metrics.fit.topInset

        subviews[0].place(
            at: CGPoint(x: bounds.midX, y: y), anchor: .top,
            proposal: ProposedViewSize(width: bounds.width, height: metrics.headerHeight))
        y += metrics.headerHeight + spacing

        // The board is placed at an EXACT size, which is also the size its
        // GeometryReader reports to `BoardTapGeometry` — renderer and
        // hit-testing cannot disagree.
        subviews[1].place(
            at: CGPoint(x: bounds.midX, y: y), anchor: .top,
            proposal: ProposedViewSize(metrics.fit.boardSize))
        y += metrics.fit.boardSize.height + spacing

        subviews[2].place(
            at: CGPoint(x: bounds.midX, y: y), anchor: .top,
            proposal: ProposedViewSize(width: bounds.width, height: metrics.footerHeight))
    }
}
