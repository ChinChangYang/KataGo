import Testing
@testable import KataGoGameStore

struct WidgetBoardAnnotationTests {
    @Test func candidateDotsMapRankAndDropOffBoardAndPass() {
        let (dots, last) = WidgetBoardView.annotationPoints(
            candidates: ["Q16", "pass", "Z99", "D4"],   // pass + off-board dropped
            lastMove: "Q16", width: 19, height: 19)
        #expect(dots.count == 2)
        #expect(dots[0].x == 15 && dots[0].y == 3 && dots[0].rank == 0)  // Q16
        #expect(dots[1].x == 3 && dots[1].y == 15 && dots[1].rank == 1)  // D4 keeps ORIGINAL rank order after drops? No: rank is the index in the KEPT list
        #expect(last != nil && last! == (x: 15, y: 3))
    }

    @Test func nilLastMoveAndEmptyCandidatesYieldNothing() {
        let (dots, last) = WidgetBoardView.annotationPoints(
            candidates: [], lastMove: nil, width: 9, height: 9)
        #expect(dots.isEmpty)
        #expect(last == nil)
    }
}
