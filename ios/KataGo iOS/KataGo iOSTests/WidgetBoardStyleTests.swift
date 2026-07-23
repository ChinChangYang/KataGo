import Testing
import KataGoGameStore

struct WidgetBoardStyleTests {
    @Test func standardStyle_matchesHistoricalRendering() {
        // `.standard` must be byte-identical to the widget board's historical
        // drawing decisions: wood slab, 0.55-opacity grid/hoshi, plain black and
        // white stone fills, and the green/yellow/orange rank-hued candidate dots.
        let style = WidgetBoardStyle.standard
        #expect(!style.isAccented)
        #expect(style.showsWoodBackground)
        #expect(style.gridOpacity == 0.55)
        #expect(!style.blackStoneIsAccentFill)
        #expect(!style.whiteStoneIsAccentOutline)
        #expect(style.usesRankHueDots)
    }

    @Test func accentedStyle_dropsWoodAndDimsGrid() {
        // In the widget accented/tinted rendering mode the wood would render as a
        // big flat tinted slab, so it is dropped, and the grid recedes further so
        // the stones carry the position.
        let style = WidgetBoardStyle.accented
        #expect(style.isAccented)
        #expect(!style.showsWoodBackground)
        #expect(style.gridOpacity < WidgetBoardStyle.standard.gridOpacity)
        #expect(style.gridOpacity > 0)
    }

    @Test func accentedStyle_keepsStoneColorsDistinguishable() {
        // The core legibility rule for tinted widgets: black and white stones must
        // stay tellable apart. Black becomes a SOLID accent fill; white becomes an
        // accent OUTLINE — two different treatments, never the same one.
        let style = WidgetBoardStyle.accented
        #expect(style.blackStoneIsAccentFill)
        #expect(style.whiteStoneIsAccentOutline)
        // Rank hues are meaningless once the system supplies a single tint.
        #expect(!style.usesRankHueDots)
    }

    @Test func candidateDotOpacity_isMonotoneInAccentedMode() {
        // With hue unavailable, candidate rank is conveyed by opacity alone:
        // strictly decreasing over the first three ranks, then clamped (parity
        // with the historical `min(rank, rankColors.count - 1)` hue clamp).
        let style = WidgetBoardStyle.accented
        let opacities = (0...3).map { style.candidateDotOpacity(rank: $0) }
        #expect(opacities[0] > opacities[1])
        #expect(opacities[1] > opacities[2])
        #expect(opacities[2] == opacities[3])
        #expect(opacities.allSatisfy { $0 > 0 && $0 <= 1 })
    }

    @Test func candidateDotOpacity_isFullInStandardMode() {
        // Standard mode conveys rank by hue, so the dots stay fully opaque.
        let style = WidgetBoardStyle.standard
        for rank in 0...3 {
            #expect(style.candidateDotOpacity(rank: rank) == 1)
        }
    }

    @Test func gobanStyle_matchesTheAppGoban() {
        // The widget's faux-3D goban: the real wood grain image, fully opaque
        // dark-brown (ink) grid, spherical stones — while candidate/annotation
        // semantics stay exactly standard (rank hues, opaque dots).
        let style = WidgetBoardStyle.goban(drawsOwnWood: true)
        #expect(!style.isAccented)
        #expect(style.isGoban)
        #expect(style.showsWoodBackground)
        #expect(style.usesWoodImage)
        #expect(style.gridOpacity == 1)
        #expect(style.stonesAreSpherical)
        #expect(style.usesRankHueDots)
        #expect(!style.blackStoneIsAccentFill)
        #expect(!style.whiteStoneIsAccentOutline)
        for rank in 0...3 {
            #expect(style.candidateDotOpacity(rank: rank) == 1)
        }
    }

    @Test func gobanFullBleed_drawsNoWoodOfItsOwn() {
        // With the Wood widget background the backplate carries the wood; the
        // board itself must draw nothing behind the grid or a seam appears.
        let style = WidgetBoardStyle.goban(drawsOwnWood: false)
        #expect(style.isGoban)
        #expect(!style.showsWoodBackground)
        #expect(style.stonesAreSpherical)
    }

    @Test func gobanMetrics_areMillimeterProportional() {
        // The 3D goban draws 0.8 mm lines and 2 mm-radius hoshi on a 22 mm
        // grid; at cell size 22 those are 0.8 pt and 4 pt exactly, with the
        // legacy floors keeping tiny widgets legible.
        let style = WidgetBoardStyle.goban(drawsOwnWood: true)
        #expect(abs(style.gridLineWidth(cellSize: 22) - 0.8) < 1e-9)
        #expect(style.gridLineWidth(cellSize: 4) == 0.5)
        #expect(abs(style.hoshiDiameter(cellSize: 22) - 4) < 1e-9)
        #expect(style.hoshiDiameter(cellSize: 5) == 2)
    }

    @Test func legacyMetrics_areUnchanged() {
        // The five flat consumers (watch, Messages, TV) ride on these numbers:
        // hairline 0.5 grid and the 0.16-of-a-cell hoshi with a 2 pt floor.
        for style in [WidgetBoardStyle.standard, .accented] {
            #expect(style.gridLineWidth(cellSize: 40) == 0.5)
            #expect(abs(style.hoshiDiameter(cellSize: 40) - 6.4) < 1e-9)
            #expect(style.hoshiDiameter(cellSize: 10) == 2)
            #expect(!style.stonesAreSpherical)
            #expect(!style.usesWoodImage)
        }
    }

    @Test func appGobanStyle_matchesTheAppBoard() {
        // The iOS/macOS widget board is a miniature of the in-app 2D goban:
        // the bundled wood.png (not the procedural grain), opaque black grid,
        // the app's quarter-cell star points, and the app's bold shrink-to-fit
        // coordinate labels. Stones and candidate semantics stay as on goban.
        let style = WidgetBoardStyle.appGoban(drawsOwnWood: true)
        #expect(!style.isAccented)
        #expect(!style.isGoban)
        #expect(style.showsWoodBackground)
        #expect(style.usesBundledWoodAsset)
        #expect(!style.usesWoodImage)
        #expect(style.gridOpacity == 1)
        #expect(style.stonesAreSpherical)
        #expect(style.usesAppCoordinateLabels)
        #expect(style.coordinateLabelsAreBold)
        #expect(style.usesRankHueDots)
        #expect(!style.blackStoneIsAccentFill)
        #expect(!style.whiteStoneIsAccentOutline)
        for rank in 0...3 {
            #expect(style.candidateDotOpacity(rank: rank) == 1)
        }
    }

    @Test func appGobanFullBleed_drawsNoWoodOfItsOwn() {
        // Full-bleed Wood backplate: the board draws nothing behind the grid,
        // exactly like the goban variant, so no grain seam can appear.
        let style = WidgetBoardStyle.appGoban(drawsOwnWood: false)
        #expect(!style.showsWoodBackground)
        #expect(style.usesBundledWoodAsset)
        #expect(style.stonesAreSpherical)
    }

    @Test func appGobanMetrics_matchTheAppRatios() {
        // Grid keeps the goban's millimeter-scaled line (the app's fixed 1 pt
        // doesn't scale down to widget cells); hoshi adopts the app's
        // squareLengthDiv4 ratio, with the 2 pt legibility floor.
        let style = WidgetBoardStyle.appGoban(drawsOwnWood: true)
        #expect(abs(style.gridLineWidth(cellSize: 22) - 0.8) < 1e-9)
        #expect(style.gridLineWidth(cellSize: 4) == 0.5)
        #expect(abs(style.hoshiDiameter(cellSize: 22) - 5.5) < 1e-9)
        #expect(style.hoshiDiameter(cellSize: 5) == 2)
    }

    @Test func coordinateLabelPlan_isAppGobanAndAccentedOnly() {
        // The app-label idiom (size-500 shrink-to-fit, bold, black) belongs to
        // appGoban alone; accented keeps its adaptive color but gains bold;
        // goban and standard are frozen (visionOS/watch/Messages unchanged).
        #expect(!WidgetBoardStyle.standard.usesAppCoordinateLabels)
        #expect(!WidgetBoardStyle.standard.coordinateLabelsAreBold)
        #expect(!WidgetBoardStyle.goban(drawsOwnWood: true).usesAppCoordinateLabels)
        #expect(!WidgetBoardStyle.goban(drawsOwnWood: true).coordinateLabelsAreBold)
        #expect(!WidgetBoardStyle.accented.usesAppCoordinateLabels)
        #expect(WidgetBoardStyle.accented.coordinateLabelsAreBold)
    }

    @Test func gobanPalette_matchesTheTextureGenerator() {
        // BoardTopTexture composites ink RGB(95, 65, 25) over wood around
        // RGB(216, 185, 92); the vector grid must use the same ink and the
        // no-image fallback the same wood so the two renderers agree.
        #expect(WidgetBoardStyle.gobanInk == WidgetBoardStyle.RGB(red: 95 / 255,
                                                                  green: 65 / 255,
                                                                  blue: 25 / 255))
        #expect(WidgetBoardStyle.gobanWood == WidgetBoardStyle.RGB(red: 216 / 255,
                                                                   green: 185 / 255,
                                                                   blue: 92 / 255))
        // Raised from 0.30/0.06/0.05: at widget cell sizes the original shadow
        // blurred into the wood and the stones read as flat discs.
        #expect(WidgetBoardStyle.stoneShadowOpacity == 0.42)
        #expect(WidgetBoardStyle.stoneShadowRadiusRatio == 0.11)
        #expect(WidgetBoardStyle.stoneShadowYOffsetRatio == 0.08)
    }
}
