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
    @Environment(AudioModel.self) private var audioModel
    @Environment(BookLookup.self) private var bookLookup

    let gameRecord: GameRecord

    /// The vertex waiting on the overwrite confirmation, resolved by
    /// `attemptPlay` at click time from whichever location the caller passed
    /// (the tap's, or the context menu's hovered one). The dialog used to
    /// re-resolve the tap location instead, so confirming from "Play here"
    /// played the last LEFT-clicked vertex, or nothing.
    @State private var pendingOverwriteMove: String?
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
                    // Minimal VoiceOver support (P6-T8): announce the board as a
                    // single element with a play hint. Deliberately NOT per-
                    // intersection — the goal is "VoiceOver announces the board",
                    // not full board navigation.
                    .accessibilityElement()
                    .accessibilityLabel("Go board")
                    .accessibilityHint("Click an intersection to play")
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
                            if let move = pendingOverwriteMove {
                                play(move)
                            }
                            pendingOverwriteMove = nil
                        }

                        Button("Cancel", role: .cancel) {
                            pendingOverwriteMove = nil
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
        /// The analysis readout for `point` — non-nil only when a candidate move
        /// sits there AND the board's analysis overlay is showing its numbers
        /// (`isAnalysisReadoutVisible`). Nil draws the ghost stone alone.
        let info: AnalysisInfo?
    }

    /// True when `AnalysisView` is currently drawing its per-move win%/score text
    /// on the board below. The ghost disc COVERS that text, and the readout capsule
    /// exists only to restore what the disc occludes — so it must never surface
    /// analysis the board itself is hiding (eye closed or in book view, auto-play,
    /// "Analysis for" excluding the side to move, or Analysis information = None).
    ///
    /// Note this is display visibility, NOT the engine state: on macOS closing the
    /// eye leaves `analysisStatus == .run`, so the ghost stone's own guard below
    /// stays satisfied while the numbers correctly disappear.
    private var isAnalysisReadoutVisible: Bool {
        gobanState.isAnalysisOverlayVisible(config: config,
                                            nextColorForPlayCommand: player.nextColorForPlayCommand)
            && !gobanState.isAnalysisInformationNone
    }

    /// Resolves whether — and what — to preview under the cursor. Returns `nil`
    /// (draw nothing) unless ALL suppression rules hold: a human move may be
    /// played right now (`canPlayHumanMove` — record position shown, no move
    /// waiting on Play Anyway, not auto-playing, a live engine in sync, and the
    /// record's side to move is not an AI side); analysis is running; the vertex
    /// is empty; and it is not the pass area. The ghost wears the RECORD's side
    /// to move, which is defined with no engine. This is a purely visual
    /// "what-if": it sends NO GTP and mutates NO engine state.
    ///
    /// The win%/score readout carries the EXTRA condition
    /// `isAnalysisReadoutVisible`; when that fails the ghost stone still draws
    /// (it is a play affordance, independent of analysis) but with no numbers.
    private func ghostState(dimensions: Dimensions) -> GhostState? {
        guard let location = hoveredLocation,
              let coordinate = coordinate(at: location, dimensions: dimensions),
              let point = coordinate.point else {
            return nil
        }

        guard gobanState.canPlayHumanMove(config: config, stones: stones, messageList: messageList),
              gobanState.analysisStatus == .run,
              !stones.blackPoints.contains(point),
              !stones.whitePoints.contains(point),
              !point.isPass(width: Int(board.width), height: Int(board.height)) else {
            return nil
        }

        let color: Color = (gobanState.recordSideToMove == .black) ? .black : .white
        let info = isAnalysisReadoutVisible ? analysis.info[point] : nil
        return GhostState(point: point, color: color, info: info)
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

    // MARK: - Play path (the same guards as BoardView's tap)

    /// Runs the SAME play path as `BoardView`'s tap: the shared
    /// `canPlayHumanMove` gate plus the occupancy check, then the overwrite
    /// confirmation (edit/branch mid-line) or the move itself. The move is
    /// resolved from `location` HERE and carried into the dialog as
    /// `pendingOverwriteMove`, so the tap and the context menu's "Play here"
    /// confirm the vertex they were invoked on.
    private func attemptPlay(at location: CGPoint, dimensions: Dimensions) {
        guard gobanState.canPlayHumanMove(config: config, stones: stones, messageList: messageList),
              let coordinate = coordinate(at: location, dimensions: dimensions),
              let point = coordinate.point,
              let move = coordinate.move,
              !stones.blackPoints.contains(point),
              !stones.whitePoints.contains(point) else { return }

        if gobanState.isOverwriting(gameRecord: gameRecord) {
            pendingOverwriteMove = move
            confirmingOverwrite = true
        } else {
            play(move)
        }
    }

    /// The one exit for a board move (ADR 0018): `GobanState.playHumanMove`
    /// decides legality in Swift against the record position and writes the
    /// record, so the stone lands with no engine loaded; a live engine is told
    /// afterwards. A ko, superko or multi-stone suicide comes back as
    /// `.confirming`, parked behind `gobanState.confirmingIllegalMove`, which
    /// `MainWindowController`'s observer presents as the "Play Anyway" sheet.
    ///
    /// The audio model clicks a pass (a stone's click rides its landing in the
    /// motion layer) and the book follows the record; `MacBoardHostView`
    /// injects both, as it does for the BoardView underneath.
    private func play(_ move: String) {
        gobanState.playHumanMove(vertex: move,
                                 gameRecord: gameRecord,
                                 config: config,
                                 analysis: analysis,
                                 board: board,
                                 stones: stones,
                                 messageList: messageList,
                                 player: player,
                                 audioModel: audioModel,
                                 bookLookup: bookLookup)
    }

    // MARK: - Coordinate mapping (shared helper — identical to BoardView)

    private func coordinate(at location: CGPoint, dimensions: Dimensions) -> Coordinate? {
        let boardWidth = Int(board.width)
        let boardHeight = Int(board.height)

        // macOS relocates the pass tile to the RIGHT of the board's bottom row
        // (see `Dimensions.macPassTileCenter` / `BoardLineView.drawPassArea`).
        // Route a click within the tile to a pass — but ONLY when Show Pass is on,
        // because that is the exact condition under which the tile is drawn
        // (`BoardLineView.drawPassArea`) and its room is reserved
        // (`Dimensions.passWidthEntity`). With Show Pass off no tile is visible and
        // no space is reserved, yet `macPassTileCenter()` still resolves to an
        // on-canvas point on a wide/height-constrained pane, so an unguarded
        // hit-test would silently play a pass on a stray right-margin click.
        // The shared `Coordinate.from` still maps the now-empty region BELOW the
        // board to a pass, so reject that phantom afterward — pass must be
        // reachable ONLY through the visible tile.
        if gobanState.showPass {
            let tileCenter = dimensions.macPassTileCenter()
            let half = dimensions.squareLength / 2
            if abs(location.x - tileCenter.x) <= half, abs(location.y - tileCenter.y) <= half {
                return Coordinate(x: boardWidth - 1,
                                  y: BoardPoint.passY(height: boardHeight) + 1,
                                  width: boardWidth,
                                  height: boardHeight)
            }
        }

        let coordinate = Coordinate.from(location: location,
                                         dimensions: dimensions,
                                         boardWidth: boardWidth,
                                         boardHeight: boardHeight,
                                         verticalFlip: gobanState.verticalFlip)
        if let point = coordinate?.point, point.isPass(width: boardWidth, height: boardHeight) {
            return nil
        }
        return coordinate
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
