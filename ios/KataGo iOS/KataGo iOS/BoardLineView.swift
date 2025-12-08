//
//  BoardLineView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/9.
//

import SwiftUI

struct BoardLineView: View {
    let dimensions: Dimensions
    let showPass: Bool
    let verticalFlip: Bool
    @Environment(BoardSize.self) var board

    var body: some View {
        ZStack {
            drawBoardBackground(dimensions: dimensions)
            drawLines(dimensions: dimensions)
            drawStarPoints(dimensions: dimensions)

            if showPass {
                drawPassArea(dimensions: dimensions)
            }

            if dimensions.coordinate {
                drawCoordinate(dimensions: dimensions)
            }
        }
    }

    private func drawCoordinate(dimensions: Dimensions) -> some View {
        Group {
            ForEach(0..<Int(dimensions.width), id: \.self) { i in
                horizontalCoordinate(i: i, dimensions: dimensions)
            }

            ForEach(0..<Int(dimensions.height), id: \.self) { i in
                verticalCoordinate(i: i, dimensions: dimensions)
            }
        }
    }

    private func horizontalCoordinate(i: Int, dimensions: Dimensions) -> some View {
        Text(Coordinate.xLabelMap[i] ?? "")
            .foregroundStyle(.black)
            .font(.system(size: 500))
            .minimumScaleFactor(0.01)
            .bold()
            .frame(width: dimensions.squareLength, height: dimensions.squareLength)
            .position(x: dimensions.boardLineStartX + (CGFloat(i) * dimensions.squareLength),
                      y: dimensions.boardLineStartY - dimensions.squareLength)
    }

    private func verticalCoordinate(i: Int, dimensions: Dimensions) -> some View {
        Text(String(i + 1))
            .foregroundStyle(.black)
            .font(.system(size: 500))
            .minimumScaleFactor(0.01)
            .bold()
            .frame(width: dimensions.squareLength, height: dimensions.squareLength)
            .position(x: dimensions.boardLineStartX - dimensions.squareLength,
                      y: dimensions.boardLineStartY + (BoardPoint.getPositionY(y: i, height: dimensions.height, verticalFlip: verticalFlip) * dimensions.squareLength))
    }

    private func drawBoardBackground(dimensions: Dimensions) -> some View {
        Group {
            Image("Wood")
                .resizable()
                .frame(width: dimensions.gobanWidth,
                       height: dimensions.gobanHeight)
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv8, y: dimensions.squareLengthDiv8)
                .position(x: dimensions.gobanStartX + (dimensions.gobanWidth / 2),
                          y: dimensions.gobanStartY + (dimensions.gobanHeight / 2))
        }
    }

    private func drawPassArea(dimensions: Dimensions) -> some View {
        Group {
            let passPoint = BoardPoint.pass(width: Int(board.width), height: Int(board.height))

            Image("Wood")
                .resizable()
                .frame(width: dimensions.squareLength,
                       height: dimensions.squareLength)
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv8, y: dimensions.squareLengthDiv8)
                .position(x: dimensions.boardLineStartX + CGFloat(passPoint.x) * dimensions.squareLength,
                          y: dimensions.boardLineStartY + CGFloat(passPoint.y) * dimensions.squareLength)

            Text("Pass")
                .font(.system(size: 500))
                .minimumScaleFactor(0.01)
                .frame(width: dimensions.squareLength, height: dimensions.squareLength)
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv8, y: dimensions.squareLengthDiv8)
                .position(x: dimensions.boardLineStartX + CGFloat(passPoint.x - 1) * dimensions.squareLength,
                          y: dimensions.boardLineStartY + CGFloat(passPoint.y) * dimensions.squareLength)
        }
    }

    private func drawLines(dimensions: Dimensions) -> some View {
        Path { path in
            // Draw horizontal lines
            for i in 0..<Int(dimensions.height) {
                let y = dimensions.boardLineStartY + CGFloat(i) * dimensions.squareLength
                path.move(to: CGPoint(x: dimensions.boardLineStartX, y: y))
                path.addLine(to: CGPoint(x: dimensions.boardLineStartX + dimensions.boardLineBoundWidth, y: y))
            }

            // Draw vertical lines
            for i in 0..<Int(dimensions.width) {
                let x = dimensions.boardLineStartX + CGFloat(i) * dimensions.squareLength
                path.move(to: CGPoint(x: x, y: dimensions.boardLineStartY))
                path.addLine(to: CGPoint(x: x, y: dimensions.boardLineStartY + dimensions.boardLineBoundHeight))
            }
        }
        .stroke(Color.black)
    }

    private func drawStarPoint(x: Int, y: Int, dimensions: Dimensions) -> some View {
        // Big black dot
        Circle()
            .frame(width: dimensions.squareLengthDiv4, height: dimensions.squareLengthDiv4)
            .foregroundStyle(Color.black)
            .position(x: dimensions.boardLineStartX + CGFloat(x) * dimensions.squareLength,
                      y: dimensions.boardLineStartY + CGFloat(y) * dimensions.squareLength)
    }

    private func drawStarPointsForSize(points: [BoardPoint], dimensions: Dimensions) -> some View {
        ForEach(points, id: \.self) { point in
            drawStarPoint(x: point.x, y: point.y, dimensions: dimensions)
        }
    }

    private func drawStarPoints(dimensions: Dimensions) -> some View {
        Group {
            if dimensions.width == 19 && dimensions.height == 19 {
                // Draw star points for 19x19 board
                drawStarPointsForSize(points: [BoardPoint(x: 3, y: 3), BoardPoint(x: 3, y: 9), BoardPoint(x: 3, y: 15), BoardPoint(x: 9, y: 3), BoardPoint(x: 9, y: 9), BoardPoint(x: 9, y: 15), BoardPoint(x: 15, y: 3), BoardPoint(x: 15, y: 9), BoardPoint(x: 15, y: 15)], dimensions: dimensions)
            } else if dimensions.width == 13 && dimensions.height == 13 {
                // Draw star points for 13x13 board
                drawStarPointsForSize(points: [BoardPoint(x: 6, y: 6), BoardPoint(x: 3, y: 3), BoardPoint(x: 3, y: 9), BoardPoint(x: 9, y: 3), BoardPoint(x: 9, y: 9)], dimensions: dimensions)
            } else if dimensions.width == 9 && dimensions.height == 9 {
                // Draw star points for 9x9 board
                drawStarPointsForSize(points: [BoardPoint(x: 4, y: 4), BoardPoint(x: 2, y: 2), BoardPoint(x: 2, y: 6), BoardPoint(x: 6, y: 2), BoardPoint(x: 6, y: 6)], dimensions: dimensions)
            }
        }
    }
}

#Preview {
    GeometryReader { geometry in
        let dimensions = Dimensions(size: geometry.size,
                                    width: 9,
                                    height: 9,
                                    showCoordinate: true)

        BoardLineView(dimensions: dimensions, showPass: true, verticalFlip: false)
    }
}

#Preview {
    GeometryReader { geometry in
        let dimensions = Dimensions(size: geometry.size,
                                    width: 13,
                                    height: 13)

        BoardLineView(dimensions: dimensions, showPass: true, verticalFlip: false)
    }
}

#Preview {
    GeometryReader { geometry in
        let dimensions = Dimensions(size: geometry.size,
                                    width: 19,
                                    height: 19)

        BoardLineView(dimensions: dimensions, showPass: true, verticalFlip: false)
    }
}

#Preview {
    GeometryReader { geometry in
        let dimensions = Dimensions(size: geometry.size,
                                    width: 29,
                                    height: 29,
                                    showCoordinate: true)

        BoardLineView(dimensions: dimensions, showPass: true, verticalFlip: false)
    }
}
