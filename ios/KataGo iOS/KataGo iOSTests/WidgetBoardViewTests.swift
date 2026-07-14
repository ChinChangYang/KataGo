import Testing
import SwiftUI
import KataGoUICore

struct WidgetBoardViewTests {
    @Test func parseVertex_handlesGTPCoordinates() {
        // 19x19: "A1" is bottom-left → grid (0, 18); "T19" top-right → (18, 0).
        #expect(parseVertex("A1", width: 19, height: 19)! == (0, 18))
        #expect(parseVertex("T19", width: 19, height: 19)! == (18, 0))
        #expect(parseVertex("Q16", width: 19, height: 19)! == (15, 3))
        #expect(parseVertex("", width: 19, height: 19) == nil)
        #expect(parseVertex("I5", width: 19, height: 19) == nil) // 'I' is skipped in GTP columns
    }

    @Test func parseVertex_handlesTwoLetterColumnsOnWideBoards() {
        // KataGo encodes columns ≥25 as "A"+letter (skipping I and AI), matching
        // Coordinate.xMap. 37x37: "AA" = col 25, "AM" = col 36.
        // Optional-chained (not force-unwrapped) so a regression fails gracefully.
        let aa = parseVertex("AA1", width: 37, height: 37)
        #expect(aa?.x == 25 && aa?.y == 36)
        let am = parseVertex("AM19", width: 37, height: 37)
        #expect(am?.x == 36 && am?.y == 18)
        #expect(parseVertex("AI1", width: 37, height: 37) == nil) // 'AI' is skipped, like 'I'
    }

    @Test func parseVertex_rejectsColumnBeyondWidth() {
        // The column must be bounded to 0..<width, mirroring the existing row
        // guard and Coordinate.init?(x:y:width:height:). On a 9x9 the rightmost
        // column is 'J' (index 8); without a width guard a wider column letter
        // returned an off-board (x ≥ width) coordinate and the widget drew a
        // stone outside the grid.
        #expect(parseVertex("J9", width: 9, height: 9)! == (8, 0)) // last valid column
        #expect(parseVertex("K9", width: 9, height: 9) == nil)     // one past the right edge
        #expect(parseVertex("T1", width: 9, height: 9) == nil)     // far off-board column
        // A two-letter column also out of range on a 19x19 board.
        #expect(parseVertex("AA1", width: 19, height: 19) == nil)
    }

    /// The crisp vector board renders to an image at every family's square size —
    /// from the small family (~120pt) up to the systemExtraLarge square (~360pt). It
    /// has no intrinsic size (greedy GeometryReader), so it must fill whatever square
    /// frame it's given rather than collapsing or faulting.
    @MainActor @Test(arguments: [CGFloat(120), CGFloat(360)])
    func widgetBoardView_rendersToImage(side: CGFloat) {
        let view = WidgetBoardView(width: 19, height: 19,
                                   blackVertices: ["Q16", "D4", "C16"], whiteVertices: ["Q4", "D16"])
        let renderer = ImageRenderer(content: view.frame(width: side, height: side))
        #expect(renderer.uiImage != nil)
    }

    /// visionOS creates any 2..37 board, square or rectangular, and those games
    /// reach the widget thumbnails and the watch (WatchBoardPage renders this
    /// same view) — the extremes must render, not collapse or fault.
    @MainActor @Test func widgetBoardView_rendersLargeRectangularAndTinyBoards() {
        let large = WidgetBoardView(width: 37, height: 37,
                                    blackVertices: ["AA1", "AM37"], whiteVertices: ["A1"])
        #expect(ImageRenderer(content: large.frame(width: 360, height: 360)).uiImage != nil)

        let rectangle = WidgetBoardView(width: 13, height: 9,
                                        blackVertices: ["C3"], whiteVertices: ["L7"])
        #expect(ImageRenderer(content: rectangle.frame(width: 360, height: 360)).uiImage != nil)

        let tiny = WidgetBoardView(width: 2, height: 2,
                                   blackVertices: ["A1"], whiteVertices: [])
        #expect(ImageRenderer(content: tiny.frame(width: 120, height: 120)).uiImage != nil)
    }

    /// The crisp vector board (now the only widget renderer) draws star points so
    /// it reads as a real goban, matching the standard hoshi layout per board size.
    /// Counts/booleans are computed into locals first: passing a non-empty
    /// `[(Int, Int)]` directly into `#expect` crashes the swift-testing macro's
    /// expression reflection (an empty tuple-array is fine, a single tuple is fine).
    @Test func hoshiPoints_standardSquareSizes() {
        let count19 = WidgetBoardView.hoshiPoints(width: 19, height: 19).count
        let count13 = WidgetBoardView.hoshiPoints(width: 13, height: 13).count
        let count9 = WidgetBoardView.hoshiPoints(width: 9, height: 9).count
        #expect(count19 == 9)   // 3×3 grid {3,9,15}
        #expect(count13 == 5)   // 4 corners + center
        #expect(count9 == 5)

        let has9Tengen = WidgetBoardView.hoshiPoints(width: 9, height: 9).contains { $0.0 == 4 && $0.1 == 4 }
        let has19Tengen = WidgetBoardView.hoshiPoints(width: 19, height: 19).contains { $0.0 == 9 && $0.1 == 9 }
        #expect(has9Tengen)
        #expect(has19Tengen)
    }

    /// Non-standard and rectangular boards now get star points too, from the
    /// shared BoardStarPoints rule (even sizes still have none).
    @Test func hoshiPoints_nonStandardSizes_useSharedRule() {
        let count7 = WidgetBoardView.hoshiPoints(width: 7, height: 7).count
        let count19x13 = WidgetBoardView.hoshiPoints(width: 19, height: 13).count
        let count37 = WidgetBoardView.hoshiPoints(width: 37, height: 37).count
        #expect(count7 == 5)      // corners + tengen
        #expect(count19x13 == 5)  // corner crosses + tengen, no mixed side stars
        #expect(count37 == 9)     // full 3x3 grid, like 19x19
        #expect(WidgetBoardView.hoshiPoints(width: 24, height: 24).isEmpty)
    }
}
