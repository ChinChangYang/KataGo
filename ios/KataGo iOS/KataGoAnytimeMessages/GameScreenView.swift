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

/// Grid geometry identical to WidgetBoardView's layout math (margin 0), so
/// taps land exactly on the rendered intersections.
struct BoardTapGeometry {
    let width: Int
    let height: Int
    let size: CGSize

    var cell: CGFloat {
        min(size.width / CGFloat(width), size.height / CGFloat(height))
    }
    var originX: CGFloat { (size.width - cell * CGFloat(width - 1)) / 2 }
    var originY: CGFloat { (size.height - cell * CGFloat(height - 1)) / 2 }

    func gridPoint(at location: CGPoint) -> GoPoint? {
        guard cell > 0 else { return nil }
        let x = Int(((location.x - originX) / cell).rounded())
        let y = Int(((location.y - originY) / cell).rounded())
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return GoPoint(x: x, y: y)
    }

    func position(of p: GoPoint) -> CGPoint {
        CGPoint(x: originX + CGFloat(p.x) * cell, y: originY + CGFloat(p.y) * cell)
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

    var body: some View {
        VStack(spacing: 8) {
            header
            board
                .aspectRatio(CGFloat(game.board.width) / CGFloat(game.board.height), contentMode: .fit)
                .frame(maxWidth: .infinity)
            footer
        }
        .padding()
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
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
                width: game.board.width, height: game.board.height, size: geo.size)
            ZStack {
                WidgetBoardView(
                    width: game.board.width,
                    height: game.board.height,
                    blackVertices: game.board.gtpVertices(of: .black),
                    whiteVertices: game.board.gtpVertices(of: .white),
                    lastMoveVertex: lastMoveVertex)
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
        // Ghost stone while aiming.
        if let ghost, game.phase == .playing {
            Circle()
                .fill((game.toMove == .black ? Color.black : .white).opacity(0.5))
                .stroke(Color.accentColor, lineWidth: 2)
                .frame(width: geometry.cell * 0.92, height: geometry.cell * 0.92)
                .position(geometry.position(of: ghost))
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
            playingControls
        case .scoring:
            scoringControls
        case .finished:
            HStack {
                analyzeButton
                Spacer()
            }
        }
    }

    private var playingControls: some View {
        HStack {
            Button("Confirm") { confirmGhost() }
                .buttonStyle(.borderedProminent)
                .disabled(ghost.map { game.isLegal(.play($0)) } != true || !interactive)
            Button("Pass") { sendPass() }
                .buttonStyle(.bordered)
                .disabled(!interactive)
            Button("Resign", role: .destructive) { confirmingResign = true }
                .buttonStyle(.bordered)
                .disabled(!interactive)
            Spacer()
            analyzeButton
        }
        .confirmationDialog("Resign this game?", isPresented: $confirmingResign, titleVisibility: .visible) {
            Button("Resign", role: .destructive) { sendResign() }
        }
    }

    private var scoringControls: some View {
        HStack {
            Button("Propose score") { actions.stage(effectiveMessage) }
                .buttonStyle(.borderedProminent)
                .disabled(!interactive)
            Button("Accept") { sendAccept() }
                .buttonStyle(.bordered)
                .disabled(!interactive)
            Button("Resume play") { sendDispute() }
                .buttonStyle(.bordered)
                .disabled(!interactive)
            Spacer()
            analyzeButton
        }
    }

    private var analyzeButton: some View {
        Button {
            actions.openInApp(effectiveMessage)
        } label: {
            Label("Analyze", systemImage: "brain")
        }
        .buttonStyle(.bordered)
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
