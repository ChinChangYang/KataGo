import Testing
import SwiftUI
import UIKit
import KataGoGameStore

/// `WidgetBoardGeometry` is the single source of truth for where a board's
/// intersections land. It exists because the Messages extension hit-tests taps
/// against the grid `WidgetBoardView` draws, and the two used to compute the
/// layout separately — with the tap side hardcoding `margin = 0`. That was
/// only correct while coordinates were off; turning labels on shifts BOTH the
/// cell pitch and the origin, so every tap would have landed on the wrong
/// intersection.
struct WidgetBoardGeometryTests {

    // MARK: - Renderer/tap agreement

    /// The property that actually matters: hit-testing the exact center of an
    /// intersection must return that intersection, coordinates on or off.
    @Test(arguments: [true, false])
    func gridPointRoundTripsThroughPosition(showCoordinates: Bool) {
        let geometry = WidgetBoardGeometry(width: 19, height: 19,
                                           size: CGSize(width: 340, height: 340),
                                           showCoordinates: showCoordinates)
        for x in 0..<19 {
            for y in 0..<19 {
                let center = geometry.position(x: x, y: y)
                let hit = geometry.gridPoint(at: center)
                #expect(hit?.x == x)
                #expect(hit?.y == y)
            }
        }
    }

    /// Rectangles and the extremes the setup card allows (2...37) round-trip
    /// too — the tap math must not assume a square.
    @Test(arguments: [(2, 2), (13, 9), (9, 13), (37, 37)])
    func gridPointRoundTripsOnEveryAllowedBoard(size: (width: Int, height: Int)) {
        let geometry = WidgetBoardGeometry(width: size.width, height: size.height,
                                           size: CGSize(width: 360, height: 360),
                                           showCoordinates: true)
        for x in 0..<size.width {
            for y in 0..<size.height {
                let hit = geometry.gridPoint(at: geometry.position(x: x, y: y))
                #expect(hit?.x == x)
                #expect(hit?.y == y)
            }
        }
    }

    /// The regression itself: with labels shown, the margin genuinely moves the
    /// grid, so a tap layer that assumed margin 0 WOULD have been wrong. If
    /// this ever stops differing, the coordinate margin has silently become a
    /// no-op and the round-trip tests above would pass vacuously.
    @Test func coordinateMarginActuallyMovesTheGrid() {
        let size = CGSize(width: 340, height: 340)
        let withLabels = WidgetBoardGeometry(width: 19, height: 19, size: size,
                                             showCoordinates: true)
        let without = WidgetBoardGeometry(width: 19, height: 19, size: size,
                                          showCoordinates: false)
        #expect(withLabels.showsLabels)
        #expect(!without.showsLabels)
        #expect(withLabels.cell < without.cell)

        // Concretely: the old margin-0 math would resolve the center of the
        // labelled board's A19 to a DIFFERENT intersection.
        let a19 = withLabels.position(x: 0, y: 0)
        let misread = without.gridPoint(at: a19)
        #expect(misread == nil || misread!.x != 0 || misread!.y != 0)
    }

    /// Below the legibility floor the labels are dropped and the margin is
    /// reclaimed, so the geometry must fall back to exactly the no-labels
    /// layout — otherwise the tap layer and renderer disagree in precisely the
    /// case the fit gate is meant to make safe.
    @Test func geometryIgnoresTheMarginWhenLabelsDoNotFit() {
        let tiny = CGSize(width: 110, height: 110)
        #expect(!WidgetBoardGeometry.coordinateLabelsFit(size: tiny, width: 19, height: 19))

        let requested = WidgetBoardGeometry(width: 19, height: 19, size: tiny,
                                            showCoordinates: true)
        let off = WidgetBoardGeometry(width: 19, height: 19, size: tiny,
                                      showCoordinates: false)
        #expect(!requested.showsLabels)
        #expect(requested.cell == off.cell)
        #expect(requested.originX == off.originX)
        #expect(requested.originY == off.originY)
    }

    /// With labels off the layout is byte-identical to the original widget
    /// math (margin 0), so already-shipped surfaces cannot have moved.
    @Test func noLabelsMatchesTheHistoricalLayout() {
        let size = CGSize(width: 300, height: 220)
        let geometry = WidgetBoardGeometry(width: 19, height: 13, size: size)
        let cell = min(size.width / 19, size.height / 13)
        #expect(geometry.cell == cell)
        #expect(geometry.originX == (size.width - cell * 18) / 2)
        #expect(geometry.originY == (size.height - cell * 12) / 2)
    }

    /// Off-board points resolve to nil rather than clamping onto an edge
    /// intersection — a tap in the coordinate margin must not place a stone.
    @Test func offBoardLocationsReturnNil() {
        let geometry = WidgetBoardGeometry(width: 9, height: 9,
                                           size: CGSize(width: 300, height: 300),
                                           showCoordinates: true)
        #expect(geometry.gridPoint(at: CGPoint(x: -50, y: -50)) == nil)
        #expect(geometry.gridPoint(at: CGPoint(x: 350, y: 350)) == nil)
    }

    /// `WidgetBoardView.coordinateLabelsFit` is now a forwarding shim; it must
    /// keep agreeing with the type that owns the rule.
    @Test func widgetBoardViewShimMatchesTheOwningType() {
        for side in [CGFloat(109), 160, 320, 400] {
            let size = CGSize(width: side, height: side)
            for n in [9, 13, 19, 37] {
                #expect(WidgetBoardView.coordinateLabelsFit(size: size, width: n, height: n)
                        == WidgetBoardGeometry.coordinateLabelsFit(size: size, width: n, height: n))
            }
        }
    }
}

/// The Messages extension's board style: the app's own goban surface plus the
/// app's Classic (Metal shader) stones.
struct ClassicGobanStyleTests {

    /// Classic inherits the whole app board surface from appGoban — only the
    /// stones differ.
    @Test func classicGobanSharesTheAppBoardSurface() {
        let classic = WidgetBoardStyle.classicGoban(drawsOwnWood: true)
        let app = WidgetBoardStyle.appGoban(drawsOwnWood: true)

        #expect(classic.usesAppBoardSurface)
        #expect(classic.usesBundledWoodAsset == app.usesBundledWoodAsset)
        #expect(classic.usesAppCoordinateLabels == app.usesAppCoordinateLabels)
        #expect(classic.coordinateLabelsAreBold == app.coordinateLabelsAreBold)
        #expect(classic.gridOpacity == app.gridOpacity)
        #expect(classic.hoshiDiameter(cellSize: 20) == app.hoshiDiameter(cellSize: 20))
        #expect(classic.gridLineWidth(cellSize: 20) == app.gridLineWidth(cellSize: 20))
        #expect(classic.showsWoodBackground)
        #expect(!WidgetBoardStyle.classicGoban(drawsOwnWood: false).showsWoodBackground)
    }

    /// ⚠️ The shader's uv constants are calibrated against the app board's
    /// 0.95 stone (`div4_ratio = (1/4)/0.95`), so the classic sprite must be
    /// 0.95 of the cell — a 0.92 sprite puts the specular highlight in the
    /// wrong place. Every other variant keeps the historical 0.92.
    @Test func classicStonesUseTheAppStoneRatio() {
        #expect(WidgetBoardStyle.classicGoban(drawsOwnWood: true).stoneDiameterRatio == 0.95)
        #expect(WidgetBoardStyle.appGoban(drawsOwnWood: true).stoneDiameterRatio == 0.92)
        #expect(WidgetBoardStyle.standard.stoneDiameterRatio == 0.92)
        #expect(WidgetBoardStyle.goban(drawsOwnWood: true).stoneDiameterRatio == 0.92)
        #expect(WidgetBoardStyle.accented.stoneDiameterRatio == 0.92)
    }

    /// Classic hands its stones to the Metal shader; the spherical vector
    /// stones are what the OTHER goban variants draw. (On watchOS, where there
    /// is no ShaderLibrary at all, the flags invert — see the #if in
    /// `usesShaderStones`. These tests run on iOS.)
    @Test func classicStonesGoThroughTheShaderNotTheVectorPath() {
        let classic = WidgetBoardStyle.classicGoban(drawsOwnWood: true)
        #expect(classic.usesShaderStones)
        #expect(!classic.stonesAreSpherical)

        #expect(!WidgetBoardStyle.appGoban(drawsOwnWood: true).usesShaderStones)
        #expect(WidgetBoardStyle.appGoban(drawsOwnWood: true).stonesAreSpherical)
        #expect(!WidgetBoardStyle.standard.usesShaderStones)
        #expect(!WidgetBoardStyle.standard.stonesAreSpherical)
    }

    /// The app marks the last move with a solid red dot at 0.3 of the square
    /// (`MoveNumberView.lastMoveMarker`); the other variants keep the hollow
    /// 0.6-cell ring.
    @Test func classicUsesTheAppLastMoveMarker() {
        let classic = WidgetBoardStyle.classicGoban(drawsOwnWood: true)
        #expect(classic.lastMoveIsFilledDot)
        #expect(classic.lastMoveMarkerDiameter(cellSize: 20) == 6)

        #expect(!WidgetBoardStyle.standard.lastMoveIsFilledDot)
        #expect(WidgetBoardStyle.standard.lastMoveMarkerDiameter(cellSize: 20) == 12)
        #expect(!WidgetBoardStyle.appGoban(drawsOwnWood: true).lastMoveIsFilledDot)
    }

    /// The classic board renders end-to-end — including the `Canvas` symbol
    /// path the shader stones go through — at the Messages board size, the
    /// bubble raster, and both board extremes. ImageRenderer rasterizes the
    /// shader (verified 2026-07-07), so a nil here means the Canvas/symbol
    /// wiring broke, not that shaders are unavailable.
    @MainActor @Test(arguments: [CGFloat(160), CGFloat(340), CGFloat(600)])
    func classicBoardRendersToImage(side: CGFloat) {
        let board = WidgetBoardView(width: 19, height: 19,
                                    blackVertices: ["Q16", "D4", "K10"],
                                    whiteVertices: ["Q4", "D16"],
                                    lastMoveVertex: "D16",
                                    showCoordinates: true,
                                    style: .classicGoban(drawsOwnWood: true))
        #expect(ImageRenderer(content: board.frame(width: side, height: side)).uiImage != nil)

        let widest = WidgetBoardView(width: 37, height: 37,
                                     blackVertices: ["A1"], whiteVertices: ["AM37"],
                                     showCoordinates: true,
                                     style: .classicGoban(drawsOwnWood: true))
        #expect(ImageRenderer(content: widest.frame(width: side, height: side)).uiImage != nil)

        let rectangle = WidgetBoardView(width: 13, height: 9,
                                        blackVertices: ["C3"], whiteVertices: ["G7"],
                                        showCoordinates: true,
                                        style: .classicGoban(drawsOwnWood: true))
        #expect(ImageRenderer(content: rectangle.frame(width: side, height: side * 9 / 13)).uiImage != nil)
    }

    /// An EMPTY classic board still renders: the Canvas resolves its symbols
    /// even with nothing to stamp.
    @MainActor @Test func classicEmptyBoardRenders() {
        let empty = WidgetBoardView(width: 9, height: 9,
                                    blackVertices: [], whiteVertices: [],
                                    showCoordinates: true,
                                    style: .classicGoban(drawsOwnWood: true))
        #expect(ImageRenderer(content: empty.frame(width: 200, height: 200)).uiImage != nil)
    }
}
