//
//  MacBoardInteractionLayer.swift
//  KataGo Anytime Mac
//
//  Phase 3 Task 8: native macOS board input overlay.
//
//  The board pane hosts the package's pure-renderer `BoardView` via
//  `NSHostingController` (see `MacBoardHostView` / `BoardViewController`). On
//  macOS, `BoardView`'s body is
//
//      VStack { Spacer(minLength: 20); GeometryReader { ZStack { …board… } } }
//
//  Because of that macOS-only `Spacer(minLength: 20)`, an external overlay only
//  shares `BoardView`'s internal coordinate space if it REPLICATES that outer
//  layout. So this view's body is the SAME shape, and it is Z-stacked ON TOP of
//  `BoardView` inside `MacBoardHostView`. The ZStack sizes both
//  `VStack { Spacer(minLength: 20); GeometryReader }` structures identically, so
//  this overlay's `geometry.size` / `Dimensions` equal `BoardView`'s — a point in
//  this overlay's `GeometryReader` space maps to a vertex via the shared
//  `Coordinate.from` helper EXACTLY as `BoardView`'s tap does.
//
//  Sitting on top, this overlay is the SINGLE input handler: it (not `BoardView`)
//  receives clicks. That removes any "does the click reach BoardView vs the
//  overlay" ambiguity; `BoardView` stays the pure renderer below.
//
//  T8 ships left-click-to-play (a faithful copy of `BoardView`'s tap, including
//  the overwrite confirmation) and a right-click context menu (Play here · Copy
//  coordinate). The `.onContinuousHover` cursor tracking it adds is the
//  foundation the later hover-preview task (T9) reuses.
//

import SwiftUI
import AppKit
import KataGoUICore

struct MacBoardInteractionLayer: View {
    @Environment(BoardSize.self) private var board
    @Environment(Turn.self) private var player
    @Environment(GobanState.self) private var gobanState
    @Environment(Stones.self) private var stones
    @Environment(MessageList.self) private var messageList
    @Environment(Analysis.self) private var analysis

    let gameRecord: GameRecord

    /// Location of the last left-click, kept so the overwrite-confirmation dialog
    /// can re-resolve the move after the user confirms (mirrors `BoardView`).
    @State private var gestureLocation: CGPoint?
    /// Drives the overwrite confirmation dialog (mirrors `BoardView`).
    @State private var confirmingOverwrite: Bool = false
    /// Cursor position inside the `GeometryReader`, tracked via
    /// `.onContinuousHover`. The `.contextMenu` reads this to know which vertex
    /// the user right-clicked (SwiftUI's `.contextMenu` does not expose the click
    /// location). T9's hover preview reuses this same value.
    @State private var hoveredLocation: CGPoint?

    init(gameRecord: GameRecord) {
        self.gameRecord = gameRecord
    }

    private var config: Config {
        gameRecord.concreteConfig
    }

    var body: some View {
        VStack {
            // Replicates BoardView's macOS-only outer spacer so this overlay's
            // GeometryReader is sized identically to BoardView's.
            Spacer(minLength: 20)
            GeometryReader { geometry in
                let dimensions = Dimensions(size: geometry.size,
                                            width: board.width,
                                            height: board.height,
                                            showCoordinate: gobanState.showCoordinate,
                                            showPass: gobanState.showPass)

                // A transparent, hit-testable surface filling the GeometryReader.
                // It owns every gesture so the overlay is the single input handler.
                Color.clear
                    .contentShape(Rectangle())
                    // Display-only hover preview (ghost stone + optional win%/score).
                    // Layered ON TOP of the hit-testable Color.clear but with hit
                    // testing disabled, so it never intercepts the clicks/hover the
                    // Color.clear owns (the overlay stays the single input handler).
                    .overlay {
                        ghostPreview(dimensions: dimensions)
                            .allowsHitTesting(false)
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredLocation = location
                        case .ended:
                            hoveredLocation = nil
                        }
                    }
                    .onTapGesture { location in
                        gestureLocation = location
                        attemptPlay(at: location, dimensions: dimensions)
                    }
                    .contextMenu {
                        contextMenuItems(dimensions: dimensions)
                    }
                    .confirmationDialog(
                        "Are you sure you want to overwrite this move?",
                        isPresented: $confirmingOverwrite,
                        titleVisibility: .visible
                    ) {
                        Button("Overwrite", role: .destructive) {
                            if let gestureLocation,
                               let coordinate = coordinate(at: gestureLocation, dimensions: dimensions),
                               let move = coordinate.move,
                               let turn = player.nextColorSymbolForPlayCommand {
                                gobanState.sendCheckMoveCommand(
                                    turn: turn,
                                    move: move,
                                    messageList: messageList
                                )
                            }
                        }

                        Button("Cancel", role: .cancel) {
                            confirmingOverwrite = false
                        }
                    }
#if DEBUG
                    .onAppear {
                        coordinateSelfCheck(dimensions: dimensions)
                    }
#endif
            }
        }
    }

    // MARK: - Right-click context menu

    /// Pre-resolved state for the context menu, computed OUTSIDE the `@ViewBuilder`
    /// body. Keeping the conditional/optional logic in plain Swift (not in the
    /// result-builder) avoids the type-checker complexity blowup that crashed the
    /// frontend when the guards were inlined into the menu builder.
    private struct ContextMenuState {
        /// The move label under the cursor ("Q16" / "pass"), if any vertex resolves.
        let copyMove: String?
        /// True when the cursor is over a valid, EMPTY vertex that can be played.
        let canPlay: Bool
    }

    private func contextMenuState(dimensions: Dimensions) -> ContextMenuState {
        guard let location = hoveredLocation,
              let coordinate = coordinate(at: location, dimensions: dimensions) else {
            return ContextMenuState(copyMove: nil, canPlay: false)
        }

        let copyMove = coordinate.move

        var canPlay = false
        if let point = coordinate.point,
           coordinate.move != nil,
           player.nextColorSymbolForPlayCommand != nil,
           !stones.blackPoints.contains(point),
           !stones.whitePoints.contains(point) {
            canPlay = true
        }

        return ContextMenuState(copyMove: copyMove, canPlay: canPlay)
    }

    @ViewBuilder
    private func contextMenuItems(dimensions: Dimensions) -> some View {
        let state = contextMenuState(dimensions: dimensions)

        // "Play here": only offered when the cursor is over a valid, EMPTY vertex.
        if state.canPlay {
            Button("Play here") {
                if let location = hoveredLocation {
                    attemptPlay(at: location, dimensions: dimensions)
                }
            }
        }

        // "Copy coordinate": available whenever the cursor resolves to any move
        // (a real vertex label like "Q16", or "pass" over the pass area).
        if let move = state.copyMove {
            Button("Copy coordinate") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(move, forType: .string)
            }
        }
    }

    // MARK: - Hover preview (display-only "what-if")

    /// Pre-resolved state for the hover preview, computed OUTSIDE the `@ViewBuilder`
    /// body. Like `ContextMenuState`, keeping the suppression guards in plain Swift
    /// (not the result-builder) avoids the type-checker complexity blowup that
    /// crashed the frontend when guards were inlined into a `@ViewBuilder`.
    private struct GhostState {
        /// The empty, playable vertex under the cursor that should be previewed.
        let point: BoardPoint
        /// The side-to-move's stone color for the ghost (`.black` / `.white`).
        let color: Color
        /// The analysis readout for `point`, if a candidate move sits there.
        let info: AnalysisInfo?
    }

    /// Resolves whether — and what — to preview under the cursor. Returns `nil`
    /// (draw nothing) unless ALL suppression rules hold:
    /// stones are ready; analysis is running; no live pending move; the vertex is
    /// empty; it is not the pass area; and the side to move is known. This is a
    /// purely visual "what-if": it sends NO GTP and mutates NO engine state.
    private func ghostState(dimensions: Dimensions) -> GhostState? {
        guard let location = hoveredLocation,
              let coordinate = coordinate(at: location, dimensions: dimensions),
              let point = coordinate.point else {
            return nil
        }

        guard stones.isReady,
              gobanState.analysisStatus == .run,
              gobanState.pendingMoveTurn == nil || gobanState.isPendingMoveStale,
              !stones.blackPoints.contains(point),
              !stones.whitePoints.contains(point),
              !point.isPass(width: Int(board.width), height: Int(board.height)),
              player.nextColorForPlayCommand != .unknown else {
            return nil
        }

        let color: Color = (player.nextColorForPlayCommand == .black) ? .black : .white
        return GhostState(point: point, color: color, info: analysis.info[point])
    }

    /// The translucent ghost stone + optional win%/score readout drawn at the
    /// hovered vertex. Display-only; everything is `.allowsHitTesting(false)` at
    /// the call site so it never steals input from the underlying `Color.clear`.
    @ViewBuilder
    private func ghostPreview(dimensions: Dimensions) -> some View {
        if let state = ghostState(dimensions: dimensions) {
            let positionX = dimensions.boardLineStartX + CGFloat(state.point.x) * dimensions.squareLength
            let positionY = dimensions.boardLineStartY + state.point.getPositionY(height: dimensions.height, verticalFlip: gobanState.verticalFlip) * dimensions.squareLength

            ZStack {
                // Translucent ghost stone in the side-to-move's color. A subtle
                // stroke keeps a white ghost visible against the wood.
                Circle()
                    .fill(state.color.opacity(0.4))
                    .overlay {
                        Circle()
                            .stroke(Color.black.opacity(0.4), lineWidth: dimensions.squareLength / 24)
                    }
                    .frame(width: dimensions.squareLength * 0.95,
                           height: dimensions.squareLength * 0.95)

                // Win% / score readout for the candidate move at this vertex, if any.
                if let info = state.info {
                    ghostReadout(info: info, dimensions: dimensions)
                        .offset(y: -dimensions.squareLength * 0.8)
                }
            }
            .frame(width: dimensions.squareLength, height: dimensions.squareLength)
            .position(x: positionX, y: positionY)
        }
    }

    /// Compact win%/score label shown above the ghost stone. Win rate and score
    /// match `AnalysisView`'s on-board overlay perspective (`info.winrate` /
    /// `info.scoreLead`).
    private func ghostReadout(info: AnalysisInfo, dimensions: Dimensions) -> some View {
        VStack(spacing: 0) {
            Text(String(format: "%.0f%%", info.winrate * 100))
                .bold()
            Text(String(format: "%+.1f", info.scoreLead))
        }
        .font(.system(size: max(8, dimensions.squareLength * 0.28), design: .monospaced))
        .foregroundStyle(.primary)
        .padding(2)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
        .fixedSize()
    }

    // MARK: - Play path (faithful copy of BoardView's tap guards)

    /// Runs the SAME play path as `BoardView.onTapGesture`: identical readiness /
    /// pending / occupancy / gen-move guards, identical pending-stale clearing,
    /// and identical overwrite-vs-send branch.
    private func attemptPlay(at location: CGPoint, dimensions: Dimensions) {
        if stones.isReady
            && !gobanState.isAutoPlaying
            && (gobanState.pendingMoveTurn == nil || gobanState.isPendingMoveStale),
           let coordinate = coordinate(at: location, dimensions: dimensions),
           let point = coordinate.point,
           let move = coordinate.move,
           let turn = player.nextColorSymbolForPlayCommand,
           !stones.blackPoints.contains(point) && !stones.whitePoints.contains(point),
           !gobanState.shouldGenMove(config: config, player: player) {

            if gobanState.isPendingMoveStale {
                gobanState.clearPendingMove()
            }

            if gobanState.isOverwriting(gameRecord: gameRecord) {
                confirmingOverwrite = true
            } else {
                gobanState.sendCheckMoveCommand(
                    turn: turn,
                    move: move,
                    messageList: messageList
                )
            }
        }
    }

    // MARK: - Coordinate mapping (shared helper — identical to BoardView)

    private func coordinate(at location: CGPoint, dimensions: Dimensions) -> Coordinate? {
        Coordinate.from(location: location,
                        dimensions: dimensions,
                        boardWidth: Int(board.width),
                        boardHeight: Int(board.height),
                        verticalFlip: gobanState.verticalFlip)
    }

#if DEBUG
    /// Headless coordinate-accuracy self-check. When `KATAGO_MAC_COORD_CHECK` is
    /// set in the environment, prints the vertices that the board's geometric
    /// CENTER and a near-corner map to, letting a headless run confirm this
    /// overlay's `Dimensions` match the board geometry. On 19x19 the center pixel
    /// should map to the tengen "K10".
    private func coordinateSelfCheck(dimensions: Dimensions) {
        guard ProcessInfo.processInfo.environment["KATAGO_MAC_COORD_CHECK"] != nil else { return }

        let center = CGPoint(
            x: dimensions.boardLineStartX + CGFloat(board.width - 1) / 2 * dimensions.squareLength,
            y: dimensions.boardLineStartY + CGFloat(board.height - 1) / 2 * dimensions.squareLength
        )
        let corner = CGPoint(
            x: dimensions.boardLineStartX,
            y: dimensions.boardLineStartY
        )

        print("KATAGO_COORD center -> \(coordinate(at: center, dimensions: dimensions)?.move ?? "nil")")
        print("KATAGO_COORD corner -> \(coordinate(at: corner, dimensions: dimensions)?.move ?? "nil")")
    }
#endif
}
