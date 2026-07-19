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
}
