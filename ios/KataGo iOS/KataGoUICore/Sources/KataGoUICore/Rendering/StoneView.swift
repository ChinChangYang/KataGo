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
    /// Each side's current rank profile, already canonical
    /// (`HumanSLModel.canonicalProfile`), for the checkmark in the long-press
    /// rank menu. nil when the label is not interactive.
    var blackRankProfile: String? = nil
    var whiteRankProfile: String? = nil
    /// The long-press rank chooser (iOS): called with the side and the picked
    /// profile. nil hides the menu.
    var onChooseRank: ((PlayerColor, String) -> Void)? = nil
    /// The live board's stone motion (ADR 0015), injected by `BoardView`.
    /// Defaults to nil, which is what makes every STATIC renderer inert by
    /// construction — `ReportBoardView`, the game-list thumbnail, the GIF
    /// frames — without any of them having to opt out.
    var motion: StoneMotionState? = nil

    public init(dimensions: Dimensions,
                isClassicStoneStyle: Bool,
                verticalFlip: Bool,
                isDrawingCapturedStones: Bool = true,
                blackPlayerName: String? = nil,
                whitePlayerName: String? = nil,
                onToggleAI: ((PlayerColor) -> Void)? = nil,
                blackRankProfile: String? = nil,
                whiteRankProfile: String? = nil,
                onChooseRank: ((PlayerColor, String) -> Void)? = nil,
                motion: StoneMotionState? = nil) {
        self.dimensions = dimensions
        self.isClassicStoneStyle = isClassicStoneStyle
        self.verticalFlip = verticalFlip
        self.isDrawingCapturedStones = isDrawingCapturedStones
        self.blackPlayerName = blackPlayerName
        self.whitePlayerName = whitePlayerName
        self.onToggleAI = onToggleAI
        self.blackRankProfile = blackRankProfile
        self.whiteRankProfile = whiteRankProfile
        self.onChooseRank = onChooseRank
        self.motion = motion
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
                            rankProfile: playerColor == .black ? blackRankProfile : whiteRankProfile,
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
                                 rankProfile: String?,
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
        // user may not know to say. The same names carry the long press
        // ("Long press White Player" opens the rank menu).
        .accessibilityInputLabels([name, playerColor == .black ? "Black Player" : "White Player"])

#if os(visionOS) || os(tvOS)
        let styled = button.buttonStyle(.bordered)
#else
        let styled = button.buttonStyle(.glass)
#endif
        return rankMenu(styled, rankProfile: rankProfile, playerColor: playerColor)
    }

    /// Feedback 2026-08-31: "choose rank when I long press the 'rank' button
    /// above the board". A context menu — long press IS iOS's context-menu
    /// gesture, and SwiftUI exposes the items to VoiceOver's actions rotor —
    /// carrying the ladder grouped by `RankCatalog`. iOS only: the Mac
    /// capsule sits under `MacBoardInteractionLayer`, which owns every click
    /// over the board (its rank menu lives in the Inspector), tvOS hides the
    /// strip, and the visionOS chips are the ornament's.
    @ViewBuilder
    private func rankMenu<Content: View>(_ content: Content,
                                         rankProfile: String?,
                                         playerColor: PlayerColor) -> some View {
#if os(iOS)
        if let onChooseRank, let rankProfile {
            content.contextMenu {
                RankMenuContent(current: rankProfile) { onChooseRank(playerColor, $0) }
            }
        } else {
            content
        }
#else
        content
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
                StoneSprites.classicShadow(dimensions: dimensions)
                    .tag(StoneSymbolID.shadow)
                StoneSprites.classicStone(red: 0, green: 0, blue: 0, dimensions: dimensions)
                    .tag(StoneSymbolID.classicBlack)
                StoneSprites.classicStone(red: 0.9, green: 0.9, blue: 0.9, dimensions: dimensions)
                    .tag(StoneSymbolID.classicWhite)
            } else {
                StoneSprites.fastStone(stoneColor: .black, dimensions: dimensions)
                    .tag(StoneSymbolID.fastBlack)
                StoneSprites.fastStone(stoneColor: Color(white: 0.9), dimensions: dimensions)
                    .tag(StoneSymbolID.fastWhite)
            }
        }
        // The old per-stone circles never mattered for input (the wood rect
        // covers every intersection), but a full-board canvas would expand tap
        // coverage into the dead margins — where a resolved tap can reach the
        // pass point — so it must stay transparent to hit testing.
        .allowsHitTesting(false)

        // The canvas is dropped when the board empties, so an empty board costs
        // no draw at all. Its `.transition(.opacity)` is gone: the projector
        // writes the stone arrays inside `withAnimation(.none)`, so that
        // transition could never have run — stone motion is the motion layer's
        // job now (ADR 0015). The haptic stays on the always-present wrapper: a
        // new game projects zero stones and must still buzz.
        let layer = ZStack {
            Group {
                if !blackPoints.isEmpty || !whitePoints.isEmpty {
                    canvas
                }
            }
            // Above the canvas, so an arriving stone covers its own twin for
            // the whole settle. Absent for every static renderer.
            if let motion {
                StoneMotionLayer(dimensions: dimensions,
                                 verticalFlip: verticalFlip,
                                 isClassicStoneStyle: isClassicStoneStyle,
                                 state: motion)
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

}

/// The stone artwork, as free functions rather than `StoneView` methods, so the
/// transient views of `StoneMotionLayer` draw the SAME sprite the board's
/// `Canvas` stamps. An arriving stone that did not match its own twin pixel for
/// pixel would read as two stones instead of one.
enum StoneSprites {
    /// One classic stone, drawn by the same Metal shader as before. The layer
    /// handed to `colorEffect` must stay exactly stoneLength², or the shader's
    /// uv = position / stoneLength mapping breaks — so no padding here.
    static func classicStone(red: Float, green: Float, blue: Float, dimensions: Dimensions) -> some View {
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
    static func classicShadow(dimensions: Dimensions) -> some View {
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
    static func fastStone(stoneColor: Color, dimensions: Dimensions) -> some View {
        Circle()
            .foregroundStyle(stoneColor)
            .frame(width: dimensions.stoneLength, height: dimensions.stoneLength)
            .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv16)
            .padding(0.3 * dimensions.squareLength)
    }

    /// The whole sprite for one stone in the current style — shadow included,
    /// exactly as the Canvas composites it.
    @ViewBuilder
    static func sprite(isClassicStoneStyle: Bool,
                       color: PlayerColor,
                       dimensions: Dimensions) -> some View {
        if isClassicStoneStyle {
            ZStack {
                classicShadow(dimensions: dimensions)
                if color == .black {
                    classicStone(red: 0, green: 0, blue: 0, dimensions: dimensions)
                } else {
                    classicStone(red: 0.9, green: 0.9, blue: 0.9, dimensions: dimensions)
                }
            }
        } else {
            fastStone(stoneColor: color == .black ? .black : Color(white: 0.9),
                      dimensions: dimensions)
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
