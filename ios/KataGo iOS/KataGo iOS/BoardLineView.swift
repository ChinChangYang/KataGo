//
//  BoardLineView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/9.
//

import SwiftUI

struct BoardLineView: View {
    let dimensions: Dimensions
    let texture = WoodImage.createTexture()

    var body: some View {
        ZStack {
            drawBoardBackground(texture: texture, dimensions: dimensions)
            drawLines(dimensions: dimensions)
            drawStarPoints(dimensions: dimensions)

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
            .font(.system(size: 500, design: .monospaced))
            .minimumScaleFactor(0.01)
            .bold()
            .frame(width: dimensions.squareLength, height: dimensions.squareLength)
            .position(x: dimensions.boardLineStartX + (CGFloat(i) * dimensions.squareLength),
                      y: dimensions.boardLineStartY - dimensions.squareLength)
    }

    private func verticalCoordinate(i: Int, dimensions: Dimensions) -> some View {
        Text(String(i + 1))
            .foregroundStyle(.black)
            .font(.system(size: 500, design: .monospaced))
            .minimumScaleFactor(0.01)
            .bold()
            .frame(width: dimensions.squareLength, height: dimensions.squareLength)
            .position(x: dimensions.boardLineStartX - dimensions.squareLength,
                      y: dimensions.boardLineStartY + (CGFloat(i) * dimensions.squareLength))
    }

    private func drawBoardBackground(texture: UIImage, dimensions: Dimensions) -> some View {
        Group {
            Image(uiImage: texture)
                .resizable()
                .frame(width: dimensions.gobanWidth,
                       height: dimensions.gobanHeight)
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv8, y: dimensions.squareLengthDiv8)
        }
    }

    private func drawLines(dimensions: Dimensions) -> some View {
        Group {
            ForEach(0..<Int(dimensions.height), id: \.self) { i in
                horizontalLine(i: i, dimensions: dimensions)
            }
            ForEach(0..<Int(dimensions.width), id: \.self) { i in
                verticalLine(i: i, dimensions: dimensions)
            }
        }
    }

    private func horizontalLine(i: Int, dimensions: Dimensions) -> some View {
        Path { path in
            let y = dimensions.boardLineStartY + CGFloat(i) * dimensions.squareLength
            path.move(to: CGPoint(x: dimensions.boardLineStartX, y: y))
            path.addLine(to: CGPoint(x: dimensions.boardLineStartX + dimensions.boardLineBoundWidth, y: y))
        }
        .stroke(Color.black)
    }

    private func verticalLine(i: Int, dimensions: Dimensions) -> some View {
        Path { path in
            let x = dimensions.boardLineStartX + CGFloat(i) * dimensions.squareLength
            path.move(to: CGPoint(x: x, y: dimensions.boardLineStartY))
            path.addLine(to: CGPoint(x: x, y: dimensions.boardLineStartY + dimensions.boardLineBoundHeight))
        }
        .stroke(Color.black)
    }

    private func drawStarPoint(x: Int, y: Int, dimensions: Dimensions) -> some View {
        // Big black dot
        Circle()
            .frame(width: dimensions.squareLengthDiv4, height: dimensions.squareLengthDiv4)
            .foregroundColor(Color.black)
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
        let dimensions = Dimensions(geometry: geometry,
                                    width: 9,
                                    height: 9,
                                    showCoordinate: true)

        BoardLineView(dimensions: dimensions)
    }
}

#Preview {
    GeometryReader { geometry in
        let dimensions = Dimensions(geometry: geometry,
                                    width: 13,
                                    height: 13)

        BoardLineView(dimensions: dimensions)
    }
}

#Preview {
    GeometryReader { geometry in
        let dimensions = Dimensions(geometry: geometry,
                                    width: 19,
                                    height: 19)

        BoardLineView(dimensions: dimensions)
    }
}

#Preview {
    GeometryReader { geometry in
        let dimensions = Dimensions(geometry: geometry,
                                    width: 29,
                                    height: 29,
                                    showCoordinate: true)

        BoardLineView(dimensions: dimensions)
    }
}
