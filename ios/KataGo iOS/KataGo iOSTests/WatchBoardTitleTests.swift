import Testing
@testable import KataGoGameStore

struct WatchBoardTitleTests {
    @Test func itShowsTheCounterOnlyWhileScrubbing() {
        #expect(WatchBoardTitle.game(name: "Sanren-sei", index: 3, count: 50,
                                     showsCounter: true) == "3/50")
        #expect(WatchBoardTitle.game(name: "Sanren-sei", index: 3, count: 50,
                                     showsCounter: false) == "Sanren-sei")
    }
}
