//
//  ReportBoardView.swift
//  KataGoUICore
//
//  Static mini-board for the Deep Analysis Report. Composes the same
//  BoardLineView/StoneView/MoveNumberView the live board uses (real wood
//  texture, stone styles, coordinates) against a local, non-observed
//  BoardSize/Stones/GobanState — not bound to live engine state; everything
//  is passed in.
//

import SwiftUI

public enum ReportBoardOverlay: Equatable, Sendable {
    case none
    /// White-positive ownership deltas, direction-rendered: positive → white
    /// square, negative → black square (no perspective conversion).
    case ownershipDelta([BoardPoint: Float])
    /// Principal variation as GTP vertices; ghost stones alternate colors
    /// starting with `startingWith`. "pass" entries advance numbering unseen.
    case pv([String], startingWith: PlayerColor)
}

/// A hypothetical move drawn on the board as a stone plus the app's red
/// current-move dot — shows WHICH move a Δ-ownership comparison is about
/// (the candidate on its Δ board; the best move on the pass board).
public struct ReportMarkedMove {
    let vertex: String
    let color: PlayerColor

    public init(vertex: String, color: PlayerColor) {
        self.vertex = vertex
        self.color = color
    }
}

/// A quick-pick annotation on the move picker's board: how a marked vertex
/// relates to the report (engine rank, the game's move, the current
/// alternative, or the unselectable best move). One mark per vertex.
public struct ReportPickMark: Identifiable {
    public enum Kind: Equatable {
        case engineRank(Int)
        case gameMove
        case currentAlternative
        case bestDisallowed
    }

    public let vertex: String
    public let kind: Kind
    public var id: String { vertex }

    public init(vertex: String, kind: Kind) {
        self.vertex = vertex
        self.kind = kind
    }
}

public struct ReportBoardView: View {
    let width: Int
    let height: Int
    let blackVertices: [String]
    let whiteVertices: [String]
    let overlay: ReportBoardOverlay
    let markedMove: ReportMarkedMove?
    /// Quick-pick annotations drawn on top of everything (the move picker's
    /// marks layer). Empty (the default) keeps every existing call site
    /// unchanged.
    let pickMarks: [ReportPickMark]
    /// A GTP vertex to mark with the app's red last-move dot (drawn on top,
    /// independent of `overlay`). The stone itself is expected to already be in
    /// `blackVertices`/`whiteVertices`, so this only adds the marker — unlike
    /// `markedMove`, which also places a stone. Used by the GIF export so its
    /// frames match the live board. "pass"/unparseable vertices draw nothing.
    let lastMoveVertex: String?
    let isClassicStoneStyle: Bool
    let showCoordinate: Bool
    let verticalFlip: Bool
    /// Optional tap hook: called with the tapped intersection (never "pass").
    /// The conversion uses this view's own `Dimensions`, so callers get the
    /// same point→vertex mapping the board was drawn with. nil (the default)
    /// keeps the view display-only.
    let onTapCoordinate: ((Coordinate) -> Void)?

    /// Minimum |Δ| worth painting — smaller swings are visual noise.
    private static let deltaFloor: Float = 0.05

    public init(width: Int, height: Int,
                blackVertices: [String], whiteVertices: [String],
                overlay: ReportBoardOverlay,
                markedMove: ReportMarkedMove? = nil,
                lastMoveVertex: String? = nil,
                pickMarks: [ReportPickMark] = [],
                isClassicStoneStyle: Bool, showCoordinate: Bool, verticalFlip: Bool,
                onTapCoordinate: ((Coordinate) -> Void)? = nil) {
        self.width = width
        self.height = height
        self.blackVertices = blackVertices
        self.whiteVertices = whiteVertices
        self.overlay = overlay
        self.markedMove = markedMove
        self.lastMoveVertex = lastMoveVertex
        self.pickMarks = pickMarks
        self.isClassicStoneStyle = isClassicStoneStyle
        self.showCoordinate = showCoordinate
        self.verticalFlip = verticalFlip
        self.onTapCoordinate = onTapCoordinate
    }

    public var body: some View {
        GeometryReader { geo in
            let dims = Dimensions(size: geo.size, width: CGFloat(width), height: CGFloat(height),
                                  showCoordinate: showCoordinate, showPass: false,
                                  isDrawingCapturedStones: false)
            let localBoardSize = boardSize
            let resolved = resolvedVariation
            let localStones = stones(resolved)

            ZStack {
                BoardLineView(dimensions: dims, showPass: false, verticalFlip: verticalFlip)
                StoneView(dimensions: dims, isClassicStoneStyle: isClassicStoneStyle,
                         verticalFlip: verticalFlip, isDrawingCapturedStones: false)
                overlayLayer(dimensions: dims, resolved: resolved)
                // The app's red last-move dot, drawn on top regardless of the
                // overlay. lastMoveMarker no-ops unless a stone sits at the point.
                if let point = lastMovePoint {
                    MoveNumberView(dimensions: dims, verticalFlip: verticalFlip,
                                   style: .lastMoveMarker,
                                   moveNumbers: MoveNumbers(numbers: [:], lastPoint: point, lastNumber: nil))
                }
                pickMarksLayer(dimensions: dims)
            }
            .environment(localBoardSize)
            .environment(localStones)
            .environment(GobanState())
#if !os(tvOS)
            // The location-providing onTapGesture variant is unavailable on
            // tvOS (no pointer); tvOS report boards stay display-only. The
            // guard also keeps every existing nil-callback call site inert.
            .onTapGesture { location in
                guard let onTapCoordinate,
                      let coordinate = Coordinate.from(location: location,
                                                       dimensions: dims,
                                                       boardWidth: width,
                                                       boardHeight: height,
                                                       verticalFlip: verticalFlip),
                      coordinate.move != "pass" else { return }
                onTapCoordinate(coordinate)
            }
#endif
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var boardSize: BoardSize {
        let board = BoardSize()
        board.width = CGFloat(width)
        board.height = CGFloat(height)
        return board
    }

    /// The drawn position. A board carrying a variation takes its stones from
    /// the force-played resolution, which can REMOVE base stones — so this
    /// replaces the base lists rather than appending to them. Without a
    /// variation there is nothing to resolve: the base is already a position.
    private func stones(_ resolved: VariationPosition?) -> Stones {
        let stones = Stones()
        if let resolved {
            stones.blackPoints = resolved.blackPoints
            stones.whitePoints = resolved.whitePoints
        } else {
            stones.blackPoints = blackVertices.compactMap { BoardPoint(move: $0, width: width, height: height) }
            stones.whitePoints = whiteVertices.compactMap { BoardPoint(move: $0, width: width, height: height) }
        }
        return stones
    }

    /// The marked move as a variation move, or nil when there is none to play.
    private var markedVariationMove: VariationMove? {
        guard let markedMove, markedMove.vertex != "pass" else { return nil }
        return VariationMove(vertex: markedMove.vertex, color: markedMove.color)
    }

    /// The variation this board draws, in the order it is played: the move UNDER
    /// STUDY first, then its continuation. Both are hypothetical stones on the
    /// same board, so they resolve as ONE chain — a PV played into a shape the
    /// marked move just captured has to find that shape empty, and a PV whose
    /// first move IS the marked move must find its own stone already there.
    private var variationMoves: [VariationMove] {
        var moves: [VariationMove] = []
        if let markedVariationMove { moves.append(markedVariationMove) }
        if case .pv(let vertices, let startingWith) = overlay {
            moves += VariationResolver.alternating(vertices, startingWith: startingWith)
        }
        return moves
    }

    /// Where the PV starts in the resolved chain — after the marked move, if
    /// there is one. Numbers are read by POSITION, never by inspecting a number:
    /// the marked move can legitimately share a point with a PV move, and a
    /// value-based filter would strip that PV move's number along with it.
    private var pvIndexOffset: Int { markedVariationMove == nil ? 0 : 1 }

    /// The PV's move numbers: its own 1-based indices, for the moves whose
    /// stones are still standing. A point replayed after a capture (ko) keeps
    /// the LATEST number, matching `MoveNumbers.derive`'s overwrite semantics.
    private func pvNumbers(_ vertices: [String],
                           resolved: VariationPosition?) -> [BoardPoint: Int] {
        guard let surviving = resolved?.survivingPoints else { return [:] }
        var numbers: [BoardPoint: Int] = [:]
        for index in vertices.indices {
            let slot = index + pvIndexOffset
            guard slot < surviving.count, let point = surviving[slot] else { continue }
            numbers[point] = index + 1
        }
        return numbers
    }

    private var resolvedVariation: VariationPosition? {
        let moves = variationMoves
        guard !moves.isEmpty else { return nil }
        return VariationResolver.resolve(width: width, height: height,
                                         blackVertices: blackVertices,
                                         whiteVertices: whiteVertices,
                                         moves: moves)
    }

    /// Nil when there is no marked move or its vertex is "pass"/unparseable.
    private var markedPoint: BoardPoint? {
        guard let markedMove, markedMove.vertex != "pass" else { return nil }
        return BoardPoint(move: markedMove.vertex, width: width, height: height)
    }

    /// The board point for `lastMoveVertex`, or nil for "pass"/unparseable.
    private var lastMovePoint: BoardPoint? {
        guard let lastMoveVertex, lastMoveVertex != "pass" else { return nil }
        return BoardPoint(move: lastMoveVertex, width: width, height: height)
    }

    @ViewBuilder
    private func overlayLayer(dimensions: Dimensions, resolved: VariationPosition?) -> some View {
        switch overlay {
        case .none:
            EmptyView()

        case .ownershipDelta(let grid):
            deltaSquares(grid: grid, dimensions: dimensions)
            // The red dot sits ON TOP of the delta squares so the marked
            // stone stays identifiable under the grayscale overlay — the
            // live board's current-move idiom (MoveNumberView.lastMoveMarker).
            // A marked move that self-captures leaves no stone to identify, and
            // lastMoveMarker draws nothing without one.
            if let point = markedPoint {
                MoveNumberView(dimensions: dimensions, verticalFlip: verticalFlip,
                               style: .lastMoveMarker,
                               moveNumbers: MoveNumbers(numbers: [:], lastPoint: point, lastNumber: nil))
            }

        case .pv(let vertices, _):
            // A stone the variation captures takes its number with it: the
            // resolver reports no surviving point for it.
            let numbers = pvNumbers(vertices, resolved: resolved)
            MoveNumberView(dimensions: dimensions, verticalFlip: verticalFlip, style: .allMoves,
                          moveNumbers: MoveNumbers(numbers: numbers, lastPoint: nil, lastNumber: nil))
        }
    }

    /// Grayscale squares mirroring AnalysisView.ownerships' idiom: brightness
    /// carries direction (1.0 = White, 0.0 = Black), size carries magnitude,
    /// opacity uses the same sigmoid as AnalysisLineParser.computeOpacity.
    private func deltaSquares(grid: [BoardPoint: Float], dimensions: Dimensions) -> some View {
        let entries = grid.filter { $0.value.magnitude >= Self.deltaFloor }
            .map { (point: $0.key, delta: $0.value) }
        return ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            let scale = min(entry.delta.magnitude, 1.0) * 0.65
            let opacity = 0.8 / (1.0 + exp(-100.0 * (Double(scale) - 0.25)))
            Rectangle()
                .foregroundStyle(Color(hue: 0, saturation: 0, brightness: entry.delta > 0 ? 1.0 : 0.0)
                    .opacity(opacity))
                .frame(width: dimensions.squareLength * CGFloat(scale), height: dimensions.squareLength * CGFloat(scale))
                .position(x: dimensions.boardLineStartX + CGFloat(entry.point.x) * dimensions.squareLength,
                          y: dimensions.boardLineStartY + entry.point.getPositionY(height: dimensions.height, verticalFlip: verticalFlip) * dimensions.squareLength)
        }
    }

    /// The picker's quick-pick annotations, drawn at intersections with the
    /// same positioning math as `deltaSquares`. One symbol per mark kind:
    /// numbered blue circle (engine rank), green diamond (game move), orange
    /// ring (current alternative), gray X (best move — not selectable).
    private func pickMarksLayer(dimensions: Dimensions) -> some View {
        ForEach(pickMarks) { mark in
            if let point = BoardPoint(move: mark.vertex, width: width, height: height) {
                pickMarkSymbol(mark.kind, side: dimensions.squareLength * 0.55)
                    .position(x: dimensions.boardLineStartX + CGFloat(point.x) * dimensions.squareLength,
                              y: dimensions.boardLineStartY + point.getPositionY(height: dimensions.height, verticalFlip: verticalFlip) * dimensions.squareLength)
            }
        }
    }

    @ViewBuilder
    private func pickMarkSymbol(_ kind: ReportPickMark.Kind, side: CGFloat) -> some View {
        switch kind {
        case .engineRank(let rank):
            ZStack {
                Circle().fill(.blue.opacity(0.75))
                Text("\(rank)")
                    .font(.system(size: side * 0.6, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: side, height: side)

        case .gameMove:
            Image(systemName: "diamond.fill")
                .font(.system(size: side * 0.8, weight: .bold))
                .foregroundStyle(.green)

        case .currentAlternative:
            Circle()
                .stroke(.orange, lineWidth: side * 0.16)
                .frame(width: side, height: side)

        case .bestDisallowed:
            Image(systemName: "xmark")
                .font(.system(size: side * 0.7, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

}

#Preview("Ownership delta") {
    ReportBoardView(width: 9, height: 9,
                    blackVertices: ["C3", "G7"], whiteVertices: ["G3", "C7"],
                    overlay: .ownershipDelta([BoardPoint(x: 2, y: 6): -0.6,
                                              BoardPoint(x: 6, y: 2): 0.4,
                                              BoardPoint(x: 4, y: 4): 0.08]),
                    markedMove: ReportMarkedMove(vertex: "E5", color: .black),
                    isClassicStoneStyle: false, showCoordinate: true, verticalFlip: false)
    .padding()
}

#Preview("PV") {
    ReportBoardView(width: 9, height: 9,
                    blackVertices: ["C3"], whiteVertices: ["G7"],
                    overlay: .pv(["E5", "G5", "pass", "C7"], startingWith: .black),
                    isClassicStoneStyle: false, showCoordinate: true, verticalFlip: false)
    .padding()
}
