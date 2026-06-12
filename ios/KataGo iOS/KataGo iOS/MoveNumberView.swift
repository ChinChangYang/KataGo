//
//  MoveNumberView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/6/15.
//

import SwiftUI

struct MoveNumberView: View {
    @Environment(Stones.self) var stones
    let dimensions: Dimensions
    let verticalFlip: Bool
    let style: MoveNumberStyle
    let moveNumbers: MoveNumbers

    var body: some View {
        switch style {
        case .lastThreeMoves:
            lastThreeMoveOrder
        case .lastMove:
            lastMoveNumber
        case .allMoves:
            allMoveNumbers
        case .lastMoveMarker:
            lastMoveMarker
        }
    }

    /// Relative 1-2-3 markers parsed from the engine's showboard output.
    private var lastThreeMoveOrder: some View {
        let blackPoints = blackPointSet
        return Group {
            ForEach(stones.moveOrder.keys.sorted(), id: \.self) { point in
                if let order = stones.moveOrder[point] {
                    label(String(order), at: point, color: contrastColor(at: point, black: blackPoints))
                }
            }
        }
    }

    @ViewBuilder
    private var lastMoveNumber: some View {
        let blackPoints = blackPointSet
        let whitePoints = whitePointSet
        if let point = moveNumbers.lastPoint,
           let number = moveNumbers.lastNumber,
           hasStone(at: point, black: blackPoints, white: whitePoints) {
            label(String(number), at: point, color: contrastColor(at: point, black: blackPoints))
        }
    }

    private var allMoveNumbers: some View {
        let blackPoints = blackPointSet
        let whitePoints = whitePointSet
        return Group {
            ForEach(moveNumbers.numbers.keys.sorted(), id: \.self) { point in
                // Skip points whose stone was captured; on replayed points the
                // derivation already kept the latest number.
                if let number = moveNumbers.numbers[point],
                   hasStone(at: point, black: blackPoints, white: whitePoints) {
                    label(String(number), at: point, color: contrastColor(at: point, black: blackPoints))
                }
            }
        }
    }

    @ViewBuilder
    private var lastMoveMarker: some View {
        let blackPoints = blackPointSet
        let whitePoints = whitePointSet
        if let point = moveNumbers.lastPoint, hasStone(at: point, black: blackPoints, white: whitePoints) {
            TriangleShape()
                .stroke(contrastColor(at: point, black: blackPoints), lineWidth: max(1, dimensions.squareLength / 24))
                .frame(width: dimensions.squareLength * 0.4, height: dimensions.squareLength * 0.35)
                .position(position(of: point))
        }
    }

    private var blackPointSet: Set<BoardPoint> {
        Set(stones.blackPoints)
    }

    private var whitePointSet: Set<BoardPoint> {
        Set(stones.whitePoints)
    }

    private func hasStone(at point: BoardPoint, black: Set<BoardPoint>, white: Set<BoardPoint>) -> Bool {
        black.contains(point) || white.contains(point)
    }

    private func contrastColor(at point: BoardPoint, black: Set<BoardPoint>) -> Color {
        black.contains(point) ? .white : .black
    }

    private func position(of point: BoardPoint) -> CGPoint {
        CGPoint(x: dimensions.boardLineStartX + CGFloat(point.x) * dimensions.squareLength,
                y: dimensions.boardLineStartY + point.getPositionY(height: dimensions.height, verticalFlip: verticalFlip) * dimensions.squareLength)
    }

    private func label(_ text: String, at point: BoardPoint, color: Color) -> some View {
        Text(text)
            .contentTransition(.numericText())
            .foregroundStyle(color)
            .font(.system(size: 500, design: .monospaced))
            .minimumScaleFactor(0.01)
            .bold()
            .frame(width: dimensions.squareLength, height: dimensions.squareLength)
            .position(position(of: point))
    }
}

/// Upward-pointing triangle outline — the classic kifu last-move markup.
struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    let stones = Stones()

    return ZStack {
        Rectangle()
            .foregroundStyle(.brown)

        GeometryReader { geometry in
            let dimensions = Dimensions(size: geometry.size,
                                        width: 2,
                                        height: 2)
            MoveNumberView(dimensions: dimensions,
                           verticalFlip: false,
                           style: .lastThreeMoves,
                           moveNumbers: .empty)
        }
        .environment(stones)
        .onAppear() {
            stones.blackPoints = [BoardPoint(x: 0, y: 0), BoardPoint(x: 1, y: 1)]
            stones.whitePoints = [BoardPoint(x: 0, y: 1), BoardPoint(x: 1, y: 0)]
            stones.moveOrder = [BoardPoint(x: 0, y: 0): "1",
                                BoardPoint(x: 0, y: 1): "2",
                                BoardPoint(x: 1, y: 1): "3",
                                BoardPoint(x: 1, y: 0): "4"]
        }
    }
}
