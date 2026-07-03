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

public enum ReportBoardOverlay {
    case none
    /// White-positive ownership deltas, direction-rendered: positive → white
    /// square, negative → black square (no perspective conversion).
    case ownershipDelta([BoardPoint: Float])
    /// Principal variation as GTP vertices; ghost stones alternate colors
    /// starting with `startingWith`. "pass" entries advance numbering unseen.
    case pv([String], startingWith: PlayerColor)
}

public struct ReportBoardView: View {
    let width: Int
    let height: Int
    let blackVertices: [String]
    let whiteVertices: [String]
    let overlay: ReportBoardOverlay
    let isClassicStoneStyle: Bool
    let showCoordinate: Bool
    let verticalFlip: Bool

    /// Minimum |Δ| worth painting — smaller swings are visual noise.
    private static let deltaFloor: Float = 0.05

    public init(width: Int, height: Int,
                blackVertices: [String], whiteVertices: [String],
                overlay: ReportBoardOverlay,
                isClassicStoneStyle: Bool, showCoordinate: Bool, verticalFlip: Bool) {
        self.width = width
        self.height = height
        self.blackVertices = blackVertices
        self.whiteVertices = whiteVertices
        self.overlay = overlay
        self.isClassicStoneStyle = isClassicStoneStyle
        self.showCoordinate = showCoordinate
        self.verticalFlip = verticalFlip
    }

    public var body: some View {
        GeometryReader { geo in
            let dims = Dimensions(size: geo.size, width: CGFloat(width), height: CGFloat(height),
                                  showCoordinate: showCoordinate, showPass: false,
                                  isDrawingCapturedStones: false)
            let localBoardSize = boardSize
            let localStones = stones

            ZStack {
                BoardLineView(dimensions: dims, showPass: false, verticalFlip: verticalFlip)
                StoneView(dimensions: dims, isClassicStoneStyle: isClassicStoneStyle,
                         verticalFlip: verticalFlip, isDrawingCapturedStones: false)
                overlayLayer(dimensions: dims)
            }
            .environment(localBoardSize)
            .environment(localStones)
            .environment(GobanState())
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var boardSize: BoardSize {
        let board = BoardSize()
        board.width = CGFloat(width)
        board.height = CGFloat(height)
        return board
    }

    private var stones: Stones {
        let stones = Stones()
        stones.blackPoints = blackVertices.compactMap { BoardPoint(move: $0, width: width, height: height) }
        stones.whitePoints = whiteVertices.compactMap { BoardPoint(move: $0, width: width, height: height) }
        if case .pv(let vertices, let startingWith) = overlay {
            let pv = pvStones(vertices, startingWith: startingWith)
            stones.blackPoints += pv.filter { $0.color == .black }.map(\.point)
            stones.whitePoints += pv.filter { $0.color == .white }.map(\.point)
        }
        return stones
    }

    @ViewBuilder
    private func overlayLayer(dimensions: Dimensions) -> some View {
        switch overlay {
        case .none:
            EmptyView()

        case .ownershipDelta(let grid):
            deltaSquares(grid: grid, dimensions: dimensions)

        case .pv(let vertices, let startingWith):
            let pv = pvStones(vertices, startingWith: startingWith)
            // A PV can revisit a point (ko recapture); the latest move number
            // wins, matching MoveNumbers.derive's overwrite semantics.
            let numbers = Dictionary(pv.map { ($0.point, $0.number) },
                                     uniquingKeysWith: { _, latest in latest })
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

    private struct PVStone {
        let point: BoardPoint
        let number: Int
        let color: PlayerColor
    }

    /// Naive about captures inside the PV: a PV move capturing base stones
    /// isn't simulated, so a captured base stone still renders underneath the
    /// later ghost stone (pre-existing behavior).
    private func pvStones(_ vertices: [String], startingWith: PlayerColor) -> [PVStone] {
        var stones: [PVStone] = []
        var color = startingWith
        for (index, vertex) in vertices.enumerated() {
            defer { color = color == .black ? .white : .black }
            guard vertex != "pass",
                  let point = BoardPoint(move: vertex, width: width, height: height) else { continue }
            stones.append(PVStone(point: point, number: index + 1, color: color))
        }
        return stones
    }
}

#Preview("Ownership delta") {
    ReportBoardView(width: 9, height: 9,
                    blackVertices: ["C3", "G7"], whiteVertices: ["G3", "C7"],
                    overlay: .ownershipDelta([BoardPoint(x: 2, y: 6): -0.6,
                                              BoardPoint(x: 6, y: 2): 0.4,
                                              BoardPoint(x: 4, y: 4): 0.08]),
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
