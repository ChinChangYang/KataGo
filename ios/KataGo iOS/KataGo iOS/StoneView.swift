//
//  StoneView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/6.
//

import SwiftUI

struct StoneView: View {
    @Environment(Stones.self) var stones
    let dimensions: Dimensions
    let isClassicStoneStyle: Bool
    let verticalFlip: Bool
    var isDrawingCapturedStones: Bool = true

    var body: some View {
        drawStones(dimensions: dimensions)

        if isDrawingCapturedStones {
            drawCapturedStones(color: .black,
                               count: stones.blackStonesCaptured,
                               xOffset: 0,
                               dimensions: dimensions)
            drawCapturedStones(color: .white,
                               count: stones.whiteStonesCaptured,
                               xOffset: 1,
                               dimensions: dimensions)
            
        }
    }

    private func drawCapturedStones(color: Color, count: Int, xOffset: CGFloat, dimensions: Dimensions) -> some View {
        HStack {
            Circle()
                .foregroundStyle(color)
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv16)
            Text("x\(count)")
                .contentTransition(.numericText())
                .font(.system(size: 500, design: .monospaced))
                .minimumScaleFactor(0.01)
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv16)
        }
        .frame(width: dimensions.capturedStonesWidth, height: dimensions.capturedStonesHeight)
        .position(x: dimensions.getCapturedStoneStartX(xOffset: xOffset),
                  y: dimensions.capturedStonesStartY)
    }

    private func drawStoneBase(stoneColor: Color, x: Int, y: CGFloat, dimensions: Dimensions) -> some View {
        Circle()
            .foregroundStyle(stoneColor)
            .frame(width: dimensions.stoneLength, height: dimensions.stoneLength)
            .position(x: dimensions.boardLineStartX + CGFloat(x) * dimensions.squareLength,
                      y: dimensions.boardLineStartY + y * dimensions.squareLength)
    }

    private func drawLightEffect(stoneColor: Color, x: Int, y: CGFloat, dimensions: Dimensions) -> some View {
        Circle()
            .fill(RadialGradient(gradient: Gradient(colors: [stoneColor, Color.white, Color.white]), center: .center, startRadius: dimensions.squareLengthDiv4, endRadius: 0))
            .offset(x: -dimensions.squareLengthDiv8, y: -dimensions.squareLengthDiv8)
            .padding(dimensions.squareLengthDiv4)
            .frame(width: dimensions.stoneLength, height: dimensions.stoneLength)
            .position(x: dimensions.boardLineStartX + CGFloat(x) * dimensions.squareLength,
                      y: dimensions.boardLineStartY + y * dimensions.squareLength)
            .overlay {
                // Mask some light
                Circle()
                    .foregroundStyle(stoneColor)
                    .blur(radius: dimensions.squareLengthDiv16)
                    .frame(width: dimensions.squareLengthDiv2, height: dimensions.squareLengthDiv2)
                    .position(x: dimensions.boardLineStartX + CGFloat(x) * dimensions.squareLength,
                              y: dimensions.boardLineStartY + y * dimensions.squareLength)
            }
    }

    private func drawBlackStone(x: Int, y: CGFloat, dimensions: Dimensions) -> some View {

        ZStack {
            // Black stone
            drawStoneBase(stoneColor: .black, x: x, y: y, dimensions: dimensions)

            // Light source effect
            drawLightEffect(stoneColor: .black, x: x, y: y, dimensions: dimensions)
        }
    }

    private func drawBlackStones(dimensions: Dimensions) -> some View {
        Group {
            ForEach(stones.blackPoints, id: \.self) { point in
                drawBlackStone(x: point.x, y: point.getPositionY(height: dimensions.height, verticalFlip: verticalFlip), dimensions: dimensions)
            }
        }
    }

    private func drawWhiteStone(x: Int, y: CGFloat, dimensions: Dimensions) -> some View {

        ZStack {
            // Make a white stone darker than light
            let stoneColor = Color(white: 0.9)

            // White stone
            drawStoneBase(stoneColor: stoneColor, x: x, y: y, dimensions: dimensions)

            // Light source effect
            drawLightEffect(stoneColor: stoneColor, x: x, y: y, dimensions: dimensions)
        }
    }

    private func drawWhiteStones(dimensions: Dimensions) -> some View {
        Group {
            ForEach(stones.whitePoints, id: \.self) { point in
                drawWhiteStone(x: point.x, y: point.getPositionY(height: dimensions.height, verticalFlip: verticalFlip), dimensions: dimensions)
            }
        }
    }

    private func drawShadow(x: Int, y: CGFloat, dimensions: Dimensions) -> some View {
        Group {
            // Shifted shadow
            Circle()
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv8, y: dimensions.squareLengthDiv8)
                .frame(width: dimensions.stoneLength, height: dimensions.stoneLength)
                .position(x: dimensions.boardLineStartX + CGFloat(x) * dimensions.squareLength,
                          y: dimensions.boardLineStartY + y * dimensions.squareLength)

            // Centered shadow
            Circle()
                .stroke(Color.black.opacity(0.5), lineWidth: dimensions.squareLengthDiv16)
                .blur(radius: dimensions.squareLengthDiv16)
                .frame(width: dimensions.stoneLength, height: dimensions.stoneLength)
                .position(x: dimensions.boardLineStartX + CGFloat(x) * dimensions.squareLength,
                          y: dimensions.boardLineStartY + y * dimensions.squareLength)
        }
    }

    private func drawShadows(dimensions: Dimensions) -> some View {
        Group {
            ForEach(stones.blackPoints, id: \.self) { point in
                drawShadow(x: point.x, y: point.getPositionY(height: dimensions.height, verticalFlip: verticalFlip), dimensions: dimensions)
            }

            ForEach(stones.whitePoints, id: \.self) { point in
                drawShadow(x: point.x, y: point.getPositionY(height: dimensions.height, verticalFlip: verticalFlip), dimensions: dimensions)
            }
        }
    }

    private func drawStones(dimensions: Dimensions) -> some View {
        ZStack {
            if isClassicStoneStyle {
                drawShadows(dimensions: dimensions)

                Group {
                    drawBlackStones(dimensions: dimensions)
                    drawWhiteStones(dimensions: dimensions)
                }
            } else {
                Group {
                    drawFastBlackStones(dimensions: dimensions)
                    drawFastWhiteStones(dimensions: dimensions)
                }
            }
        }
    }

    private func drawFastBlackStones(dimensions: Dimensions) -> some View {
        Group {
            ForEach(stones.blackPoints, id: \.self) { point in
                drawFastStoneBase(stoneColor: .black,
                                  x: point.x,
                                  y: point.getPositionY(height: dimensions.height, verticalFlip: verticalFlip),
                                  dimensions: dimensions)
            }
        }
    }

    private func drawFastWhiteStones(dimensions: Dimensions) -> some View {
        Group {
            ForEach(stones.whitePoints, id: \.self) { point in
                drawFastStoneBase(stoneColor: Color(white: 0.9),
                                  x: point.x,
                                  y: point.getPositionY(height: dimensions.height, verticalFlip: verticalFlip),
                                  dimensions: dimensions)
            }
        }
    }

    private func drawFastStoneBase(stoneColor: Color, x: Int, y: CGFloat, dimensions: Dimensions) -> some View {
        Circle()
            .foregroundStyle(stoneColor)
            .frame(width: dimensions.stoneLength, height: dimensions.stoneLength)
            .position(x: dimensions.boardLineStartX + CGFloat(x) * dimensions.squareLength,
                      y: dimensions.boardLineStartY + y * dimensions.squareLength)
            .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv16)
    }
}

#Preview {
    let stones = Stones()

    return ZStack {
        Rectangle()
            .foregroundStyle(.brown)

        GeometryReader { geometry in
            StoneView(dimensions: Dimensions(size: geometry.size,
                                             width: 2,
                                             height: 2),
                      isClassicStoneStyle: false,
                      verticalFlip: false)
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

#Preview {
    let stones = Stones()

    return ZStack {
        Rectangle()
            .foregroundStyle(.brown)

        GeometryReader { geometry in
            StoneView(dimensions: Dimensions(size: geometry.size,
                                             width: 2,
                                             height: 2),
                      isClassicStoneStyle: true,
                      verticalFlip: false)
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
