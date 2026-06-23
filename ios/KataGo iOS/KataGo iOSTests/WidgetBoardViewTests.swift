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

    @MainActor @Test func widgetBoardView_rendersToImage() {
        let view = WidgetBoardView(width: 19, height: 19,
                                   blackVertices: ["Q16", "D4"], whiteVertices: ["Q4"])
        let renderer = ImageRenderer(content: view.frame(width: 120, height: 120))
        #expect(renderer.uiImage != nil)
    }
}
