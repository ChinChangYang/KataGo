//
//  MessagesBoardStyle.swift
//  KataGoAnytimeMessages
//
//  How this extension's two Go boards look — the live board in
//  `GameScreenView` and the bubble snapshot in `BubbleRenderer` — kept in one
//  place so the board you play on and the board in the thread can never drift
//  apart.
//
//  The style is the app's own: the bundled "Wood" texture, the plain black
//  grid, quarter-cell hoshi, the app's coordinate labels, and the app's
//  **Classic** stones (the very same `ShaderLibrary.stone` Metal shader
//  `StoneView` draws). That last part only resolves because the appex compiles
//  `Shaders.metal` itself — an extension's `Bundle.main` is the extension, not
//  the host app. See `add_shader_to_messages_target.rb`.
//

import SwiftUI
import KataGoGameStore

enum MessagesBoardStyle {
    /// `drawsOwnWood: true` — nothing behind this board is already wood.
    static let board: WidgetBoardStyle = .classicGoban(drawsOwnWood: true)

    /// The app defaults coordinates ON, so the extension does too.
    /// `WidgetBoardView` drops the labels (and reclaims their margin) on its
    /// own when the pitch is too small for them to render intact.
    static let showsCoordinates = true

    /// Bubble snapshot raster. The wood grain makes a far denser PNG than the
    /// old flat fill did — measured on a 19x19 with 120 stones, 126 KB flat at
    /// scale 3 became 960 KB. One bubble per move in each direction stays in
    /// the thread forever, so the snapshot renders at scale 2 (~482 KB), still
    /// twice the 300 pt display size.
    static let bubbleRenderScale: CGFloat = 2

    /// The board's own wood, used only as the shadow caster's fill. It is
    /// fully covered by the board drawn on top; the fill exists so no seam can
    /// show through antialiasing at the edge.
    static let woodColor = Color(red: WidgetBoardStyle.gobanWood.red,
                                 green: WidgetBoardStyle.gobanWood.green,
                                 blue: WidgetBoardStyle.gobanWood.blue)

    /// The slab that casts the board's shadow, sized to the board by being
    /// used as its `.background`.
    ///
    /// ⚠️ The shadow is cast by this ONE opaque rectangle, never by the board
    /// itself. SwiftUI's `.shadow` applies per drawn leaf rather than to the
    /// composited result, so shadowing `WidgetBoardView` would put a separate
    /// halo under every grid line, hoshi dot, stone and coordinate label. The
    /// app board looks right because it shadows a single `Image` — this is the
    /// same trick.
    static func shadowCaster(cell: CGFloat) -> some View {
        Rectangle()
            .fill(woodColor)
            .shadow(radius: WidgetBoardStyle.boardShadowRadius(cellSize: cell),
                    x: WidgetBoardStyle.boardShadowOffset(cellSize: cell),
                    y: WidgetBoardStyle.boardShadowOffset(cellSize: cell))
    }
}
