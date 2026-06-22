import Testing
import SwiftUI
import KataGoUICore

struct WidgetBoardViewTests {
    @Test func parseVertex_handlesGTPCoordinates() {
        // 19x19: "A1" is bottom-left → grid (0, 18); "T19" top-right → (18, 0).
        #expect(parseVertex("A1", height: 19)! == (0, 18))
        #expect(parseVertex("T19", height: 19)! == (18, 0))
        #expect(parseVertex("Q16", height: 19)! == (15, 3))
        #expect(parseVertex("", height: 19) == nil)
        #expect(parseVertex("I5", height: 19) == nil) // 'I' is skipped in GTP columns
    }

    @MainActor @Test func widgetBoardView_rendersToImage() {
        let view = WidgetBoardView(width: 19, height: 19,
                                   blackVertices: ["Q16", "D4"], whiteVertices: ["Q4"])
        let renderer = ImageRenderer(content: view.frame(width: 120, height: 120))
        #expect(renderer.uiImage != nil)
    }
}
