//
//  GobanStateBranchClampTests.swift
//  KataGo iOSTests
//
//  Pins the branch navigation floor: while a branch is active, navigation may
//  step back TO the divergence position (branchIndex == the frozen
//  gameRecord.currentIndex) but never earlier. The floor lives in
//  navigationFloor / canStepBackward and is enforced by undoIndex,
//  backwardMoves, and go(to:). Off-branch the floor is 0, so mainline
//  navigation is unchanged (the regression pins).
//
//  The MessageList is standalone (nil session), so appendAndSend only appends:
//  the engine `undo` commands each path emits are COUNTABLE and nothing reaches
//  an engine.
//

import Testing
@testable import KataGoUICore

@MainActor
struct GobanStateBranchClampTests {

    // Original (saved) line: 4 moves. The branch diverges after move 2 (frozen
    // record currentIndex 2) with 3 new moves at indices 2..4, all on points
    // distinct from the shared prefix.
    private static let originalSgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])"
    private static let branchLineSgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[ee];W[ff];B[gg])"

    @MainActor
    private struct Fixture {
        let state = GobanState()
        let record: GameRecord
        let board = BoardSize()
        let stones = Stones()
        let messageList = MessageList.accepting()
        let player = Turn()
        let audioModel = AudioModel()

        /// Builds a record whose `currentIndex` (the frozen divergence while a
        /// branch is active) is `recordIndex`. When `branchIndex` is non-nil the
        /// state is put in branch mode on `branchLineSgf` at that index, so the
        /// floor is `recordIndex`.
        init(recordIndex: Int, branchIndex: Int? = nil) {
            record = GameRecord(sgf: GobanStateBranchClampTests.originalSgf,
                                currentIndex: recordIndex,
                                config: Config(),
                                name: "Game")
            board.width = 9
            board.height = 9
            state.isEditing = false
            if let branchIndex {
                state.branchSgf = GobanStateBranchClampTests.branchLineSgf
                state.branchIndex = branchIndex
            }
            player.nextColorForPlayCommand = .black
        }

        /// Count of engine `undo` commands appended so far. The MessageList
        /// display prefix is "> ", so an undo is the exact line "> undo".
        var undoCount: Int {
            messageList.messages.filter { $0.text == "> undo" }.count
        }

        func backwardAll() {
            state.backwardMoves(limit: nil, gameRecord: record,
                                messageList: messageList, player: player,
                                stones: stones)
        }

        func go(to index: Int) {
            state.go(to: index, gameRecord: record, board: board,
                     messageList: messageList, player: player,
                     audioModel: audioModel, stones: stones)
        }
    }

    @Test("undoIndex stops at the divergence while a branch is active")
    func undoIndexStopsAtDivergence() {
        // Divergence frozen at record.currentIndex 2; branch sits one move above.
        let f = Fixture(recordIndex: 2, branchIndex: 3)

        f.state.undoIndex(gameRecord: f.record)
        #expect(f.state.branchIndex == 2)

        // A second undo cannot cross the floor.
        f.state.undoIndex(gameRecord: f.record)
        #expect(f.state.branchIndex == 2)

        // The frozen divergence itself is untouched.
        #expect(f.record.currentIndex == 2)
    }

    @Test("undoIndex off-branch still reaches index 0 (mainline pin)")
    func undoIndexMainlineStillReachesZero() {
        let f = Fixture(recordIndex: 2) // no branch: floor is 0

        f.state.undoIndex(gameRecord: f.record)
        #expect(f.record.currentIndex == 1)

        f.state.undoIndex(gameRecord: f.record)
        #expect(f.record.currentIndex == 0)

        // Floored at 0 by GameRecord.undo().
        f.state.undoIndex(gameRecord: f.record)
        #expect(f.record.currentIndex == 0)
    }

    @Test("canStepBackward is false at the branch floor, true above it")
    func canStepBackwardFalseAtBranchFloorTrueAbove() {
        // At the divergence (branchIndex == floor) there is nothing to step back
        // into: a caller that sends the engine `undo` itself must not.
        let atFloor = Fixture(recordIndex: 2, branchIndex: 2)
        #expect(atFloor.state.canStepBackward(gameRecord: atFloor.record) == false)

        let aboveFloor = Fixture(recordIndex: 2, branchIndex: 3)
        #expect(aboveFloor.state.canStepBackward(gameRecord: aboveFloor.record) == true)
    }

    @Test("canStepBackward off-branch is true above 0, false at 0 (mainline pin)")
    func canStepBackwardMainlineTrueAboveZeroFalseAtZero() {
        let above = Fixture(recordIndex: 1)
        #expect(above.state.canStepBackward(gameRecord: above.record) == true)

        let atZero = Fixture(recordIndex: 0)
        #expect(atZero.state.canStepBackward(gameRecord: atZero.record) == false)
    }

    @Test("backwardMoves rewind stops at the divergence")
    func backwardMovesRewindStopsAtDivergence() {
        // Branch at index 5, divergence frozen at 2: rewinding to the start
        // stops at the floor after exactly 3 undos.
        let f = Fixture(recordIndex: 2, branchIndex: 5)

        f.backwardAll()

        #expect(f.state.branchIndex == 2)
        #expect(f.undoCount == 3)
        #expect(f.record.currentIndex == 2)
    }

    @Test("backwardMoves off-branch still reaches index 0 (mainline pin)")
    func backwardMovesMainlineStillReachesZero() {
        let f = Fixture(recordIndex: 3) // no branch, 4-move game

        f.backwardAll()

        #expect(f.record.currentIndex == 0)
        #expect(f.undoCount == 3)
    }

    @Test("go(to:) earlier than the divergence clamps to the divergence")
    func goToEarlierThanDivergenceClampsToDivergence() {
        let f = Fixture(recordIndex: 2, branchIndex: 4)

        f.go(to: 0)

        #expect(f.state.branchIndex == 2)
        #expect(f.undoCount == 2)
    }

    @Test("go(to:) within the branch still navigates")
    func goToWithinBranchStillNavigates() {
        let f = Fixture(recordIndex: 2, branchIndex: 5)

        f.go(to: 3)

        #expect(f.state.branchIndex == 3)
        #expect(f.undoCount == 2)
    }
}
