//
//  StoneView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/6.
//

import SwiftUI

public struct StoneView: View {
    @Environment(Stones.self) var stones
    @Environment(GobanState.self) var gobanState

    let dimensions: Dimensions
    let isClassicStoneStyle: Bool
    let verticalFlip: Bool
    var isDrawingCapturedStones: Bool = true
    var speedText: String? = nil
    /// Name shown beside each color's captured-stone count: the engine profile
    /// (e.g. "AI" / "rank_9d") when that side plays with thinking time, or
    /// "Human" otherwise. `nil` hides the label (e.g. the game-list thumbnail).
    var blackPlayerName: String? = nil
    var whitePlayerName: String? = nil
    /// When set (live board), the per-color name renders as a tappable capsule
    /// button that calls this with the tapped color. When nil (game-list
    /// thumbnail / previews) the name is plain, non-interactive text.
    var onToggleAI: ((PlayerColor) -> Void)? = nil

    public init(dimensions: Dimensions,
                isClassicStoneStyle: Bool,
                verticalFlip: Bool,
                isDrawingCapturedStones: Bool = true,
                speedText: String? = nil,
                blackPlayerName: String? = nil,
                whitePlayerName: String? = nil,
                onToggleAI: ((PlayerColor) -> Void)? = nil) {
        self.dimensions = dimensions
        self.isClassicStoneStyle = isClassicStoneStyle
        self.verticalFlip = verticalFlip
        self.isDrawingCapturedStones = isDrawingCapturedStones
        self.speedText = speedText
        self.blackPlayerName = blackPlayerName
        self.whitePlayerName = whitePlayerName
        self.onToggleAI = onToggleAI
    }

    public var body: some View {
        drawStones(dimensions: dimensions)

        if isDrawingCapturedStones {
            drawCapturedStones(color: .black,
                               playerColor: .black,
                               count: stones.blackStonesCaptured,
                               xOffset: 0,
                               name: blackPlayerName,
                               nameAccessibilityID: "blackPlayerName",
                               dimensions: dimensions)
            drawCapturedStones(color: .white,
                               playerColor: .white,
                               count: stones.whiteStonesCaptured,
                               xOffset: 1,
                               name: whitePlayerName,
                               nameAccessibilityID: "whitePlayerName",
                               dimensions: dimensions)

            if let speedText {
                drawSpeedText(speedText, dimensions: dimensions)
            }

        }
    }

    private func drawCapturedStones(color: Color,
                                    playerColor: PlayerColor,
                                    count: Int,
                                    xOffset: CGFloat,
                                    name: String?,
                                    nameAccessibilityID: String,
                                    dimensions: Dimensions) -> some View {
        HStack(spacing: dimensions.squareLengthDiv8) {
            if let name, !name.isEmpty {
                playerNameLabel(name: name,
                                playerColor: playerColor,
                                nameAccessibilityID: nameAccessibilityID,
                                dimensions: dimensions)
            }
            Circle()
                .foregroundStyle(color)
                .frame(width: dimensions.capturedStonesHeight, height: dimensions.capturedStonesHeight)
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv16)
            // The captured count keeps a STATIC size (fixedSize → never scaled
            // down by the adaptive name beside it).
            Text("x\(count)")
                .contentTransition(.numericText())
                .font(.system(size: dimensions.capturedStonesHeight * 0.85, design: .monospaced))
                .fixedSize()
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv16)
        }
        .frame(width: dimensions.capturedStonesWidth, height: dimensions.capturedStonesHeight)
        .position(x: dimensions.getCapturedStoneStartX(xOffset: xOffset),
                  y: dimensions.capturedStonesStartY)
    }

    // The per-color name. With a toggle handler (live board) it is a tappable
    // button styled like the on-board toolbar controls (`.glass`); without one
    // (thumbnail / previews) it is the original plain, non-interactive text.
    @ViewBuilder
    private func playerNameLabel(name: String,
                                 playerColor: PlayerColor,
                                 nameAccessibilityID: String,
                                 dimensions: Dimensions) -> some View {
        if let onToggleAI {
            glassNameButton(name: name,
                            playerColor: playerColor,
                            onToggleAI: onToggleAI,
                            dimensions: dimensions)
                .accessibilityIdentifier(nameAccessibilityID)
        } else {
            Text(name)
                .lineLimit(1)
                .minimumScaleFactor(0.2)
                .font(.system(size: dimensions.capturedStonesHeight * 0.7))
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv16)
                .accessibilityIdentifier(nameAccessibilityID)
        }
    }

    // The tappable AI/Human button. Mirrors the on-board toolbar idiom
    // (StatusToolbarItems uses `.glass`): the same neutral glass for both
    // states, with the side (Human vs the engine profile) shown by the label
    // text. `.mini` control size keeps it within the ~20pt captured-stones
    // strip. visionOS doesn't support the glass styles (same as
    // StatusToolbarItems), so it falls back to `.bordered` there.
    private func glassNameButton(name: String,
                                 playerColor: PlayerColor,
                                 onToggleAI: @escaping (PlayerColor) -> Void,
                                 dimensions: Dimensions) -> some View {
        let button = Button {
            onToggleAI(playerColor)
        } label: {
            Text(name)
                .lineLimit(1)
                .minimumScaleFactor(0.2)
                .font(.system(size: dimensions.capturedStonesHeight * 0.7))
        }
        .controlSize(.mini)

#if os(visionOS)
        return button.buttonStyle(.bordered)
#else
        return button.buttonStyle(.glass)
#endif
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

// Exercises the captured-stone labels with a SHORT name on one side and a LONG
// profile ("proyear_1810") on the other: the "x12"/"x7" counts must stay the
// same (static) size while only the long name scales down to fit.
#Preview("Captured labels — long profile") {
    let stones = Stones()

    return ZStack {
        Rectangle()
            .foregroundStyle(.brown)

        GeometryReader { geometry in
            StoneView(dimensions: Dimensions(size: geometry.size,
                                             width: 19,
                                             height: 19,
                                             showCoordinate: true),
                      isClassicStoneStyle: false,
                      verticalFlip: false,
                      blackPlayerName: "Human",
                      whitePlayerName: "proyear_1810")
        }
        .environment(stones)
        .environment(GobanState())
        .onAppear() {
            stones.blackStonesCaptured = 12
            stones.whiteStonesCaptured = 7
        }
    }
    .frame(width: 393, height: 640)
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

// Interactive AI/Human toggle: the names render as tappable neutral `.glass`
// buttons (both states), the side shown by the label text. Verifies the
// buttons fit the 20pt strip beside the static "x..." counts.
#Preview("Captured labels — tappable toggle") {
    let stones = Stones()

    return ZStack {
        Rectangle()
            .foregroundStyle(.brown)

        GeometryReader { geometry in
            StoneView(dimensions: Dimensions(size: geometry.size,
                                             width: 19,
                                             height: 19,
                                             showCoordinate: true),
                      isClassicStoneStyle: false,
                      verticalFlip: false,
                      blackPlayerName: "Human",
                      whitePlayerName: "AI",
                      onToggleAI: { _ in })
        }
        .environment(stones)
        .environment(GobanState())
        .onAppear {
            stones.blackStonesCaptured = 12
            stones.whiteStonesCaptured = 7
        }
    }
    .frame(width: 393, height: 640)
}
