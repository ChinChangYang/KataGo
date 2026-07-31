//
//  ClassicStoneLayer.swift
//  KataGoGameStore
//
//  The app's Classic stone style, drawn for `WidgetBoardStyle.classicGoban`.
//  This is the SAME `ShaderLibrary.stone` Metal shader `StoneView` uses on the
//  live board, stamped the SAME way — one `Canvas` over a handful of
//  pre-rasterized symbols.
//
//  Why a Canvas and not a view per stone: `StoneView` used to build ~3 views
//  per classic stone (shader circle + two shadow circles, one blurred), which
//  on a dense 19x19 meant ~1000 layers and ~361 offscreen shader passes per
//  redraw — 76 ms. The Canvas rewrite took that to 0.85 ms. `WidgetBoardView`
//  still draws its other variants' stones one view apiece, which is fine for
//  flat discs; putting a per-stone `colorEffect` into that ForEach would walk
//  straight back into the 76 ms case, on boards up to 37x37 (1369 points), in
//  a memory-capped app extension.
//
//  ⚠️ The shader's uv mapping is `position / stoneLength`, so the layer handed
//  to `colorEffect` must be EXACTLY stoneLength² — never pad it. Only the
//  shadow sprite is padded, to give its offset and blur room to spill.
//

import SwiftUI

#if !os(watchOS)

/// Draws all of one board's classic stones in a single `Canvas`.
///
/// Layer order matches `StoneView.drawStones`: every stone's shadow first, so
/// no shadow lands on top of a neighbouring stone, then black, then white.
struct ClassicStoneLayer: View {
    let black: [(Int, Int)]
    let white: [(Int, Int)]
    /// Cell pitch in points; the stone is `stoneDiameterRatio` of it.
    let cell: CGFloat
    let stoneLength: CGFloat
    let originX: CGFloat
    let originY: CGFloat

    private enum StoneSymbolID: Hashable {
        case shadow
        case classicBlack
        case classicWhite
    }

    var body: some View {
        Canvas { context, _ in
            func center(x: Int, y: Int) -> CGPoint {
                CGPoint(x: originX + CGFloat(x) * cell,
                        y: originY + CGFloat(y) * cell)
            }

            if let shadow = context.resolveSymbol(id: StoneSymbolID.shadow) {
                for s in black { context.draw(shadow, at: center(x: s.0, y: s.1)) }
                for s in white { context.draw(shadow, at: center(x: s.0, y: s.1)) }
            }
            if let blackStone = context.resolveSymbol(id: StoneSymbolID.classicBlack) {
                for s in black { context.draw(blackStone, at: center(x: s.0, y: s.1)) }
            }
            if let whiteStone = context.resolveSymbol(id: StoneSymbolID.classicWhite) {
                for s in white { context.draw(whiteStone, at: center(x: s.0, y: s.1)) }
            }
        } symbols: {
            shadowSymbol.tag(StoneSymbolID.shadow)
            // The same RGB triples StoneView passes: pure black, and 0.9 grey
            // for white (the shader lightens from there).
            stoneSymbol(red: 0, green: 0, blue: 0).tag(StoneSymbolID.classicBlack)
            stoneSymbol(red: 0.9, green: 0.9, blue: 0.9).tag(StoneSymbolID.classicWhite)
        }
        .allowsHitTesting(false)
    }

    /// One classic stone. ⚠️ Exactly stoneLength² — see the file comment.
    private func stoneSymbol(red: Float, green: Float, blue: Float) -> some View {
        Circle()
            .colorEffect(ShaderLibrary.stone(
                .float(Float(stoneLength)),
                .float3(red, green, blue)
            ))
            .frame(width: stoneLength, height: stoneLength)
    }

    /// Both shadow layers of one classic stone, pre-composited — the shifted
    /// drop shadow plus the centered blurred ring, mirroring
    /// `StoneView.classicShadowSymbol`. Symmetric padding keeps the sprite
    /// centered on the stone while giving the offset and blur room to spill.
    private var shadowSymbol: some View {
        let div8 = cell / 8
        let div16 = cell / 16
        return ZStack {
            Circle()
                .shadow(radius: div16, x: div8, y: div8)
            Circle()
                .stroke(Color.black.opacity(0.5), lineWidth: div16)
                .blur(radius: div16)
        }
        .frame(width: stoneLength, height: stoneLength)
        .padding(0.3 * cell)
    }
}

#endif
