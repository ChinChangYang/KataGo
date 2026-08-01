import Testing
import CoreGraphics
import KataGoGameStore

/// `BoardSheetFit` sizes the Go board on the Messages extension's expanded
/// sheet, where the board shares a fixed-height sheet with a header and an
/// action row.
///
/// It exists because the screen used to lean on SwiftUI's proposal semantics
/// instead: `.aspectRatio(_:contentMode: .fit)` on a `GeometryReader` inside a
/// `ScrollView`. A ScrollView proposes an UNSPECIFIED height, so the aspect
/// ratio resolved from the width alone — a 9x19 came out 781 pt tall in a
/// ~636 pt sheet, with the bottom rows unreachable because the board's own
/// drag gesture ate the scroll pan. The same nil proposal left a square board
/// hugging the top of the sheet with ~266 pt of dead space below the buttons.
///
/// So the rule is arithmetic here rather than a proposal negotiation: the
/// board fits BOTH axes, the leftover is split evenly above and below the
/// block, and the sheet only scrolls when the chrome itself has outgrown it.
struct BoardSheetFitTests {

    /// An iPhone-sized expanded sheet after the screen's 16 pt padding, plus a
    /// header + action row at ordinary text sizes.
    private static let sheet = CGSize(width: 370, height: 636)
    private static let chrome: CGFloat = 60
    private static let floor: CGFloat = 160

    private func fit(_ width: Int, _ height: Int,
                     available: CGSize = BoardSheetFitTests.sheet,
                     chromeHeight: CGFloat = BoardSheetFitTests.chrome) -> BoardSheetFit {
        BoardSheetFit(available: available, chromeHeight: chromeHeight,
                      boardWidth: width, boardHeight: height,
                      minimumBoardHeight: BoardSheetFitTests.floor)
    }

    // MARK: - The invariant that failed

    /// The regression: a board taller than it is wide must be bounded by the
    /// HEIGHT budget, never by the width. Width-driven sizing is what pushed a
    /// 9x19 to 781 pt in a 636 pt sheet.
    @Test func tallBoardIsBoundedByTheHeightBudgetNotTheWidth() {
        let f = fit(9, 19)
        let budget = Self.sheet.height - Self.chrome

        #expect(f.boardSize.height == budget)
        #expect(f.boardSize.width == budget * 9 / 19)
        #expect(f.boardSize.width < Self.sheet.width)
        #expect(!f.scrolls)
    }

    /// No board of any allowed shape may overflow the sheet at ordinary text
    /// sizes. This is the property the whole type exists to guarantee, so it is
    /// checked across the entire 2...37 range the setup card offers rather than
    /// at a few sampled shapes.
    @Test func noAllowedBoardEverOverflowsTheSheet() {
        for w in 2...37 {
            for h in 2...37 {
                let f = fit(w, h)
                #expect(f.boardSize.width <= Self.sheet.width + 0.001,
                        "\(w)x\(h) is wider than the sheet")
                #expect(f.boardSize.height <= Self.sheet.height - Self.chrome + 0.001,
                        "\(w)x\(h) is taller than the height budget")
                #expect(!f.scrolls, "\(w)x\(h) should not need scrolling")
            }
        }
    }

    /// Fitting must not distort: the drawn board keeps the board's own aspect
    /// ratio whichever axis binds.
    @Test func fittedBoardKeepsItsAspectRatio() {
        for (w, h) in [(19, 19), (9, 19), (19, 9), (2, 37), (37, 2), (13, 9)] {
            let f = fit(w, h)
            let expected = CGFloat(w) / CGFloat(h)
            let actual = f.boardSize.width / f.boardSize.height
            #expect(abs(actual - expected) < 0.0001, "\(w)x\(h) aspect drifted")
        }
    }

    // MARK: - Which axis binds

    /// A square board on a portrait sheet is bound by the width, and that is
    /// as large as it can legitimately get — the leftover height is dead space
    /// by construction, not a sizing failure.
    @Test func squareBoardIsBoundedByTheWidth() {
        let f = fit(19, 19)
        #expect(f.boardSize == CGSize(width: 370, height: 370))
        #expect(f.contentHeight == 430)
    }

    /// A board WIDER than it is tall keeps its natural, short height. The
    /// minimum-height floor must not inflate it — a 37x2 is genuinely 20 pt
    /// tall at this width, and forcing it to 160 would either distort it or
    /// push it wider than the sheet.
    @Test func shortWideBoardIsNotInflatedByTheMinimumHeight() {
        let f = fit(37, 2)
        #expect(f.boardSize.width == 370)
        #expect(f.boardSize.height == 20)
        #expect(f.boardSize.height < Self.floor)
    }

    // MARK: - Centering (the dead-space complaint)

    /// When the block is shorter than the sheet the leftover is split evenly
    /// above and below it, so a square board reads as centered instead of
    /// hugging the top with all the emptiness dumped under the buttons.
    @Test func leftoverSpaceIsSplitEvenlyAboveAndBelowTheBlock() {
        let f = fit(19, 19)
        #expect(f.totalHeight == Self.sheet.height)
        #expect(f.topInset == (Self.sheet.height - f.contentHeight) / 2)
        #expect(f.topInset > 0)
    }

    /// A board that fills the sheet has nothing to center.
    @Test func aFillingBoardGetsNoInset() {
        let f = fit(9, 19)
        #expect(f.contentHeight == Self.sheet.height)
        #expect(f.topInset == 0)
    }

    // MARK: - Accessibility text sizes

    /// At large text sizes the header and the stacked action column can eat the
    /// whole sheet. The board floors instead of collapsing to a few points, the
    /// block then genuinely exceeds the sheet, and THAT is the one case where
    /// the screen is expected to scroll.
    @Test func hugeChromeFloorsTheBoardAndMakesTheSheetScroll() {
        let f = fit(19, 19, chromeHeight: 560)
        #expect(f.boardSize == CGSize(width: Self.floor, height: Self.floor))
        #expect(f.contentHeight == 560 + Self.floor)
        #expect(f.scrolls)
        #expect(f.totalHeight == f.contentHeight)
        #expect(f.topInset == 0)
    }

    /// Even at the floor the board still fits the width — flooring the HEIGHT
    /// of a wide board must not push it off the sides.
    @Test func flooredWideBoardStillFitsTheWidth() {
        let f = fit(37, 9, chromeHeight: 560)
        #expect(f.boardSize.width <= Self.sheet.width + 0.001)
    }

    // MARK: - Degenerate input

    /// The sheet reports a zero size for at least one layout pass while the
    /// hosting controller settles; that must not produce NaN, a negative size,
    /// or a division by zero.
    @Test(arguments: [CGSize.zero,
                      CGSize(width: 370, height: 0),
                      CGSize(width: 0, height: 636),
                      CGSize(width: -10, height: -10)])
    func degenerateSheetSizesStayFinite(available: CGSize) {
        let f = fit(19, 19, available: available)
        #expect(f.boardSize.width.isFinite)
        #expect(f.boardSize.height.isFinite)
        #expect(f.boardSize.width >= 0)
        #expect(f.boardSize.height >= 0)
        #expect(f.topInset >= 0)
        #expect(f.totalHeight.isFinite)
    }

    /// SwiftUI proposals legitimately carry `.infinity`, and this is public API
    /// in a module five targets link — so an unbounded proposal must not leak
    /// an infinite inset into a frame. (An infinite height is the dangerous
    /// one: it makes `totalHeight` infinite while `contentHeight` stays finite,
    /// so the centering inset diverges.)
    @Test(arguments: [CGSize(width: 370, height: CGFloat.infinity),
                      CGSize(width: CGFloat.infinity, height: 636),
                      CGSize(width: CGFloat.infinity, height: CGFloat.infinity)])
    func unboundedProposalsStayFinite(available: CGSize) {
        let f = fit(19, 19, available: available)
        #expect(f.boardSize.width.isFinite)
        #expect(f.boardSize.height.isFinite)
        #expect(f.contentHeight.isFinite)
        #expect(f.totalHeight.isFinite)
        #expect(f.topInset.isFinite)
        #expect(f.topInset >= 0)
    }

    /// A degenerate board dimension cannot divide by zero either.
    @Test(arguments: [(0, 19), (19, 0), (0, 0), (-3, 19)])
    func degenerateBoardDimensionsStayFinite(size: (width: Int, height: Int)) {
        let f = fit(size.width, size.height)
        #expect(f.boardSize.width.isFinite)
        #expect(f.boardSize.height.isFinite)
        #expect(f.boardSize.width >= 0)
        #expect(f.boardSize.height >= 0)
    }

    /// Chrome taller than the sheet leaves a negative budget; the floor takes
    /// over rather than the board going negative.
    @Test func chromeTallerThanTheSheetDoesNotProduceANegativeBoard() {
        let f = fit(19, 19, chromeHeight: 900)
        #expect(f.boardSize.height == Self.floor)
        #expect(f.scrolls)
    }

    // MARK: - Landscape / iPad

    /// On a sheet wider than it is tall the height binds instead, and the
    /// board must still fit both axes.
    @Test func wideSheetBindsOnHeight() {
        let landscape = CGSize(width: 800, height: 340)
        let f = fit(19, 19, available: landscape)
        #expect(f.boardSize.height == landscape.height - Self.chrome)
        #expect(f.boardSize.width == landscape.height - Self.chrome)
        #expect(f.boardSize.width < landscape.width)
        #expect(!f.scrolls)
    }
}
