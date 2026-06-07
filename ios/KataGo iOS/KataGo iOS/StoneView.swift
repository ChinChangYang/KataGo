//
//  StoneView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/6.
//

import SwiftUI

struct StoneView: View {
    @Environment(Stones.self) var stones
    @Environment(GobanState.self) var gobanState

    let dimensions: Dimensions
    let isClassicStoneStyle: Bool
    let verticalFlip: Bool
    var isDrawingCapturedStones: Bool = true
    var speedText: String? = nil

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

            if let speedText {
                drawSpeedText(speedText, dimensions: dimensions)
            }
            
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

    // Shows the visits/s readout centered in the empty gap between the captured-stone
    // counts. The counts keep their fixed positions, so enabling/disabling the readout
    // never shifts them.
    private func drawSpeedText(_ text: String, dimensions: Dimensions) -> some View {
        let spread = 0.75 * max(dimensions.gobanWidth / 2, dimensions.capturedStonesWidth)
        let gapWidth = max(0, (2 * spread) - dimensions.capturedStonesWidth)
        return Text(text)
            .contentTransition(.numericText())
            .font(.system(size: dimensions.capturedStonesHeight * 0.85, design: .monospaced))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .frame(width: gapWidth, height: dimensions.capturedStonesHeight)
            .position(x: dimensions.gobanStartX + (dimensions.gobanWidth / 2),
                      y: dimensions.capturedStonesStartY)
    }

    private func drawClassicStone(x: Int, y: CGFloat, r: Float, g: Float, b: Float, dimensions: Dimensions) -> some View {
        Circle()
            .colorEffect(ShaderLibrary.stone(
                .float(Float(dimensions.stoneLength)),
                .float3(r, g, b)
            ))
            .frame(width: dimensions.stoneLength, height: dimensions.stoneLength)
            .position(x: dimensions.boardLineStartX + CGFloat(x) * dimensions.squareLength,
                      y: dimensions.boardLineStartY + y * dimensions.squareLength)
    }

    private func drawBlackStone(x: Int, y: CGFloat, dimensions: Dimensions) -> some View {
        drawClassicStone(x: x, y: y, r: 0, g: 0, b: 0, dimensions: dimensions)
    }

    private func drawBlackStones(dimensions: Dimensions) -> some View {
        Group {
            ForEach(stones.blackPoints, id: \.self) { point in
                drawBlackStone(x: point.x, y: point.getPositionY(height: dimensions.height, verticalFlip: verticalFlip), dimensions: dimensions)
            }
        }
    }

    private func drawWhiteStone(x: Int, y: CGFloat, dimensions: Dimensions) -> some View {
        drawClassicStone(x: x, y: y, r: 0.9, g: 0.9, b: 0.9, dimensions: dimensions)
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
        .sensoryFeedback(.impact, trigger: stones.isReady) { wasReady, isReady in
            !wasReady && isReady && gobanState.hapticFeedback
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
        .environment(GobanState())
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
        .environment(GobanState())
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
