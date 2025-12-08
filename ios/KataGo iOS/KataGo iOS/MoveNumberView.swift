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

    var body: some View {
        drawMoveOrder(dimensions: dimensions)
    }

    private func drawMoveOrder(dimensions: Dimensions) -> some View {
        Group {
            ForEach(stones.moveOrder.keys.sorted(), id: \.self) { point in
                if let order = stones.moveOrder[point] {
                    let color: Color = stones.blackPoints.contains { blackPoint in
                        point == blackPoint
                    } ? .white : .black
                    Text(String(order))
                        .contentTransition(.numericText())
                        .foregroundStyle(color)
                        .font(.system(size: 500, design: .monospaced))
                        .minimumScaleFactor(0.01)
                        .bold()
                        .frame(width: dimensions.squareLength, height: dimensions.squareLength)
                        .position(x: dimensions.boardLineStartX + CGFloat(point.x) * dimensions.squareLength,
                                  y: dimensions.boardLineStartY + point.getPositionY(height: dimensions.height, verticalFlip: verticalFlip) * dimensions.squareLength)
                }
            }
        }
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
            MoveNumberView(dimensions: dimensions, verticalFlip: false)
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
