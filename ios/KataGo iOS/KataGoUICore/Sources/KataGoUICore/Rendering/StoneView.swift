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
    /// Name shown beside each color's captured-stone count: the engine profile
    /// (e.g. "AI" / "9d") when that side plays with thinking time, or
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
                blackPlayerName: String? = nil,
                whitePlayerName: String? = nil,
                onToggleAI: ((PlayerColor) -> Void)? = nil) {
        self.dimensions = dimensions
        self.isClassicStoneStyle = isClassicStoneStyle
        self.verticalFlip = verticalFlip
        self.isDrawingCapturedStones = isDrawingCapturedStones
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
        // A stable speakable name for Voice Control: the visible label is the
        // dynamic player name ("AI" / a rank profile / "Human"), which the
        // user may not know to say.
        .accessibilityInputLabels([name, playerColor == .black ? "Black Player" : "White Player"])

#if os(visionOS) || os(tvOS)
        return button.buttonStyle(.bordered)
#else
        return button.buttonStyle(.glass)
#endif
    }

    /// Every stone of one color/style looks identical, so the whole board is
    /// one `Canvas` stamping a handful of pre-rasterized symbols. The old tree
    /// built ~3 SwiftUI views per classic stone (shader circle + two shadow
    /// circles, one blurred) that were each composited as separate layers —
    /// on a dense 19×19 that meant hundreds of per-stone offscreen shader and
    /// blur passes per redraw.
    private enum StoneSymbolID: Hashable {
        case shadow
        case classicBlack
        case classicWhite
        case fastBlack
        case fastWhite
    }

    private func drawStones(dimensions: Dimensions) -> some View {
        // Snapshot the observable arrays during body evaluation: Observation
        // only tracks reads made here, not inside the Canvas renderer closure
        // (which runs at draw time, after body returns).
        let blackPoints = stones.blackPoints
        let whitePoints = stones.whitePoints

        let canvas = Canvas { context, _ in
            func center(of point: BoardPoint) -> CGPoint {
                CGPoint(x: dimensions.boardLineStartX + CGFloat(point.x) * dimensions.squareLength,
                        y: dimensions.boardLineStartY + point.getPositionY(height: dimensions.height, verticalFlip: verticalFlip) * dimensions.squareLength)
            }

            if isClassicStoneStyle {
                // All shadows under all stones, matching the old layer order.
                if let shadow = context.resolveSymbol(id: StoneSymbolID.shadow) {
                    for point in blackPoints { context.draw(shadow, at: center(of: point)) }
                    for point in whitePoints { context.draw(shadow, at: center(of: point)) }
                }
                if let black = context.resolveSymbol(id: StoneSymbolID.classicBlack) {
                    for point in blackPoints { context.draw(black, at: center(of: point)) }
                }
                if let white = context.resolveSymbol(id: StoneSymbolID.classicWhite) {
                    for point in whitePoints { context.draw(white, at: center(of: point)) }
                }
            } else {
                if let black = context.resolveSymbol(id: StoneSymbolID.fastBlack) {
                    for point in blackPoints { context.draw(black, at: center(of: point)) }
                }
                if let white = context.resolveSymbol(id: StoneSymbolID.fastWhite) {
                    for point in whitePoints { context.draw(white, at: center(of: point)) }
                }
            }
        } symbols: {
            if isClassicStoneStyle {
                classicShadowSymbol(dimensions: dimensions)
                    .tag(StoneSymbolID.shadow)
                classicStoneSymbol(red: 0, green: 0, blue: 0, dimensions: dimensions)
                    .tag(StoneSymbolID.classicBlack)
                classicStoneSymbol(red: 0.9, green: 0.9, blue: 0.9, dimensions: dimensions)
                    .tag(StoneSymbolID.classicWhite)
            } else {
                fastStoneSymbol(stoneColor: .black, dimensions: dimensions)
                    .tag(StoneSymbolID.fastBlack)
                fastStoneSymbol(stoneColor: Color(white: 0.9), dimensions: dimensions)
                    .tag(StoneSymbolID.fastWhite)
            }
        }
        // The old per-stone circles never mattered for input (the wood rect
        // covers every intersection), but a full-board canvas would expand tap
        // coverage into the dead margins — where a resolved tap can reach the
        // pass point — so it must stay transparent to hit testing.
        .allowsHitTesting(false)

        // Removing the canvas when the board empties lets the stones fade out
        // when a switch publishes an empty board, as the per-stone views'
        // removal transitions used to. Per-move updates set the arrays with
        // `.none`, so normal play still swaps instantly. The haptic stays on
        // the always-present wrapper: a new game projects zero stones and must
        // still buzz.
        let layer = Group {
            if !blackPoints.isEmpty || !whitePoints.isEmpty {
                canvas
                    .transition(.opacity)
            }
        }

#if os(tvOS)
        // No haptics on tvOS (the Siri Remote has none); .impact is also not a
        // valid SensoryFeedback case there.
        return layer
#else
        // The stone lands when the RECORD moves, not when the engine catches
        // up: the board is record-owned, so the buzz rides the projection.
        return layer
            .sensoryFeedback(.impact, trigger: stones.positionGeneration) { old, new in
                old != new && gobanState.hapticFeedback
            }
#endif
    }

    /// One classic stone, drawn by the same Metal shader as before. The layer
    /// handed to `colorEffect` must stay exactly stoneLength², or the shader's
    /// uv = position / stoneLength mapping breaks — so no padding here.
    private func classicStoneSymbol(red: Float, green: Float, blue: Float, dimensions: Dimensions) -> some View {
        Circle()
            .colorEffect(ShaderLibrary.stone(
                .float(Float(dimensions.stoneLength)),
                .float3(red, green, blue)
            ))
            .frame(width: dimensions.stoneLength, height: dimensions.stoneLength)
    }

    /// Both shadow layers of one classic stone, pre-composited. Symmetric
    /// padding keeps the sprite center on the stone center while extending the
    /// raster bounds to cover the offset/blur spill (≤ squareLength/4 beyond
    /// the stone edge).
    private func classicShadowSymbol(dimensions: Dimensions) -> some View {
        ZStack {
            // Shifted shadow
            Circle()
                .shadow(radius: dimensions.squareLengthDiv16,
                        x: dimensions.squareLengthDiv8,
                        y: dimensions.squareLengthDiv8)

            // Centered shadow
            Circle()
                .stroke(Color.black.opacity(0.5), lineWidth: dimensions.squareLengthDiv16)
                .blur(radius: dimensions.squareLengthDiv16)
        }
        .frame(width: dimensions.stoneLength, height: dimensions.stoneLength)
        .padding(0.3 * dimensions.squareLength)
    }

    /// One fast-style stone with its drop shadow baked in, so a later stone's
    /// shadow falls over earlier stones exactly like the old per-stone views.
    private func fastStoneSymbol(stoneColor: Color, dimensions: Dimensions) -> some View {
        Circle()
            .foregroundStyle(stoneColor)
            .frame(width: dimensions.stoneLength, height: dimensions.stoneLength)
            .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv16)
            .padding(0.3 * dimensions.squareLength)
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
// profile ("Pro 1810") on the other: the "x12"/"x7" counts must stay the
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
                      whitePlayerName: "Pro 1810")
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
