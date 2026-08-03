//
//  SphericalStoneLayer.swift
//  KataGoGameStore
//
//  The goban family's flat-vector approximation of the 3D stones, drawn the
//  way `ClassicStoneLayer` draws the shader stones: one `Canvas` stamping a
//  pre-rasterized sprite per color.
//
//  Why this exists: `SphericalStone` is a `RadialGradient` PLUS a `.shadow`,
//  and `WidgetBoardView` used to instantiate one view per stone. That is the
//  same ~1000-layer shape `StoneView` was rewritten out of (76 ms -> 0.85 ms),
//  on boards that reach 37x37 (1369 points). It was survivable while every
//  consumer rendered once and never moved — a widget snapshot, a Messages
//  bubble raster, a tvOS thumbnail — but the watch re-evaluates the whole
//  board on every Digital Crown detent while scrubbing a game.
//
//  Unlike `ClassicStoneLayer` this needs no `ShaderLibrary`, so it compiles on
//  watchOS and is NOT wrapped in `#if !os(watchOS)`.
//

import SwiftUI

/// Draws all of one board's spherical stones in a single `Canvas`.
///
/// Layer order matches the per-view drawing it replaces: white first, then
/// black. Each sprite carries its OWN drop shadow (the shadow is inside
/// `SphericalStone`), so a later stone's shadow falls over earlier stones
/// exactly as before — deliberately unlike `ClassicStoneLayer`, which draws
/// every shadow first because its shadows are a separate sprite.
struct SphericalStoneLayer: View {
    let black: [(Int, Int)]
    let white: [(Int, Int)]
    /// Cell pitch in points.
    let cell: CGFloat
    /// Stone diameter in points (`cell * style.stoneDiameterRatio`).
    let diameter: CGFloat
    let originX: CGFloat
    let originY: CGFloat

    private enum StoneSymbolID: Hashable {
        case black
        case white
    }

    /// Room the sprite's raster must leave around the stone for its shadow.
    ///
    /// A Canvas symbol is rasterized at its LAYOUT size, and `.shadow` draws
    /// outside that — so an unpadded sprite would have its shadow shorn off
    /// square at the stone's edge, which the per-view rendering never did.
    /// `3 * blurRadius` is where a Gaussian has decayed to nothing, plus the
    /// downward offset. Symmetric, so the stone stays centred in its raster
    /// and `context.draw(_:at:)` still lands it on the intersection.
    private var shadowPadding: CGFloat {
        diameter * (WidgetBoardStyle.stoneShadowRadiusRatio * 3
                    + WidgetBoardStyle.stoneShadowYOffsetRatio)
    }

    var body: some View {
        Canvas { context, _ in
            func center(x: Int, y: Int) -> CGPoint {
                CGPoint(x: originX + CGFloat(x) * cell,
                        y: originY + CGFloat(y) * cell)
            }

            if let whiteStone = context.resolveSymbol(id: StoneSymbolID.white) {
                for s in white { context.draw(whiteStone, at: center(x: s.0, y: s.1)) }
            }
            if let blackStone = context.resolveSymbol(id: StoneSymbolID.black) {
                for s in black { context.draw(blackStone, at: center(x: s.0, y: s.1)) }
            }
        } symbols: {
            sprite(isBlack: false).tag(StoneSymbolID.white)
            sprite(isBlack: true).tag(StoneSymbolID.black)
        }
        // The wood rect underneath covers every intersection, so the board's
        // hosts hit-test against that; a full-board canvas must not start
        // swallowing taps in the margins.
        .allowsHitTesting(false)
    }

    private func sprite(isBlack: Bool) -> some View {
        SphericalStone(isBlack: isBlack, diameter: diameter)
            .frame(width: diameter, height: diameter)
            .padding(shadowPadding)
    }
}

/// A flat-vector approximation of the 3D stones: an off-center radial
/// highlight (upper-left key light) over a darkening rim, plus a soft drop
/// shadow that scales with the stone. White additionally gets a faint dark
/// rim so it separates from the light wood underneath.
///
/// Lives here rather than in `WidgetBoardView.swift` so the layer above and
/// the view can both reach it; it is otherwise unchanged.
struct SphericalStone: View {
    let isBlack: Bool
    let diameter: CGFloat

    var body: some View {
        let stops: [Gradient.Stop] = isBlack
            ? [.init(color: Color(white: 0.52), location: 0),
               .init(color: Color(white: 0.22), location: 0.45),
               .init(color: Color(white: 0.05), location: 1)]
            : [.init(color: .white, location: 0),
               .init(color: Color(white: 0.93), location: 0.55),
               .init(color: Color(white: 0.78), location: 1)]
        ZStack {
            Circle().fill(RadialGradient(stops: stops,
                                         center: UnitPoint(x: 0.37, y: 0.33),
                                         startRadius: 0,
                                         endRadius: diameter * 0.70))
            if !isBlack {
                Circle().strokeBorder(.black.opacity(0.12),
                                      lineWidth: max(diameter * 0.02, 0.5))
            }
        }
        .shadow(color: .black.opacity(WidgetBoardStyle.stoneShadowOpacity),
                radius: diameter * WidgetBoardStyle.stoneShadowRadiusRatio,
                x: 0, y: diameter * WidgetBoardStyle.stoneShadowYOffsetRatio)
    }
}
