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

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                header
                board
                    .aspectRatio(CGFloat(game.board.width) / CGFloat(game.board.height), contentMode: .fit)
                    .frame(maxWidth: .infinity, minHeight: Self.minimumBoardHeight)
                footer
            }
            .padding()
        }
        // Nothing to scroll at ordinary text sizes: the content fits and this
        // reads exactly as the plain VStack did.
        .scrollBounceBehavior(.basedOnSize)
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
                overlays(geometry: geometry)
            }
            .contentShape(Rectangle())
            .gesture(boardGesture(geometry: geometry))
        }
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

    @ViewBuilder
    private var footer: some View {
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
            controlRow([analyzeAction])
        }
    }

    // MARK: - Control rows
    //
    // "Propose score" + "Accept" + "Resume play" + the Analyze button needs
    // ~450 pt on one line; the widest iPhone is 440, so that row wrapped on
    // EVERY device, and both rows wrapped one Dynamic Type step above default.
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
            analyzeAction,
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
            analyzeAction,
        ]
    }

    /// The sparkle is the app's analysis glyph (custom.sparkle on the iOS
    /// board, sparkles on tvOS).
    private var analyzeAction: BoardAction {
        BoardAction(id: "analyze", long: "Analyze", short: "Analyze",
                    systemImage: "sparkle") {
            actions.openInApp(effectiveMessage)
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
        .accessibilityLabel(item.id == "analyze" ? "Analyze in KataGo Anytime" : item.long)

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
