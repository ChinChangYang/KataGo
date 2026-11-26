import Testing
@testable import KataGoUICore
import KataGoGameStore

@MainActor
struct FreshBoardTests {
    @Test("no moves and a person on both sides is fresh")
    func untouchedGameIsFresh() {
        #expect(FreshBoard.isFresh(moveCount: 0, config: Config(), gobanState: GobanState()))
    }

    @Test("the first stone ends it")
    func aMoveEndsIt() {
        #expect(!FreshBoard.isFresh(moveCount: 1, config: Config(), gobanState: GobanState()))
    }

    @Test("an unread or unreadable record is never fresh")
    func unknownMoveCountIsNotFresh() {
        #expect(!FreshBoard.isFresh(moveCount: nil, config: Config(), gobanState: GobanState()))
    }

    @Test("a side handed to the AI ends it")
    func anAISideEndsIt() {
        let black = Config()
        black.blackMaxTime = Config.toggleAIThinkingTime
        #expect(!FreshBoard.isFresh(moveCount: 0, config: black, gobanState: GobanState()))

        let white = Config()
        white.whiteMaxTime = Config.toggleAIThinkingTime
        #expect(!FreshBoard.isFresh(moveCount: 0, config: white, gobanState: GobanState()))
    }

    @Test("a branch or auto-play on top of it is not fresh")
    func branchAndAutoPlayAreNotFresh() {
        let branching = GobanState()
        branching.branchSgf = "(;GM[1]FF[4]SZ[19])"
        branching.branchIndex = 0
        #expect(branching.isBranchActive)
        #expect(!FreshBoard.isFresh(moveCount: 0, config: Config(), gobanState: branching))

        let autoPlaying = GobanState()
        autoPlaying.isAutoPlaying = true
        #expect(!FreshBoard.isFresh(moveCount: 0, config: Config(), gobanState: autoPlaying))
    }
}
