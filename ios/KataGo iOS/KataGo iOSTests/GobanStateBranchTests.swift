//
//  GobanStateBranchTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime

struct GobanStateBranchTests {
    // Original line: 4 moves. Branch diverges after move 2 with 3 new moves.
    private static let originalSgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])"
    private static let branchLineSgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[ee];W[ff];B[gg])"

    @Test func commitBranchReplacesGame() {
        // Divergence at index 2: data at indices <= 2 is shared with the
        // branch and must survive; index 3+ belongs to the original tail.
        let gameRecord = GameRecord.createGameRecord(
            sgf: Self.originalSgf,
            currentIndex: 2,
            comments: [1: "shared", 2: "at divergence", 3: "original tail"],
            winRates: [1: 0.5, 2: 0.6, 3: 0.7]
        )
        let dateBefore = gameRecord.lastModificationDate
        let gobanState = GobanState()
        gobanState.branchSgf = Self.branchLineSgf
        gobanState.branchIndex = 5

        gobanState.commitBranch(gameRecord: gameRecord)

        #expect(gameRecord.sgf == Self.branchLineSgf)
        #expect(gameRecord.currentIndex == 5)
        #expect(gameRecord.comments == [1: "shared", 2: "at divergence"])
        #expect(gameRecord.winRates == [1: 0.5, 2: 0.6])
        #expect(gameRecord.lastModificationDate != dateBefore)
        #expect(gobanState.isBranchActive == false)
        #expect(gobanState.branchSgf == .inActiveSgf)
        #expect(gobanState.branchIndex == .inActiveCurrentIndex)
    }

    @Test func commitBranchWithoutActiveBranchIsNoOp() {
        let gameRecord = GameRecord.createGameRecord(
            sgf: Self.originalSgf,
            currentIndex: 4,
            comments: [1: "keep", 4: "keep too"]
        )
        let dateBefore = gameRecord.lastModificationDate
        let gobanState = GobanState() // branch fields at inactive sentinels

        gobanState.commitBranch(gameRecord: gameRecord)

        #expect(gameRecord.sgf == Self.originalSgf)
        #expect(gameRecord.currentIndex == 4)
        #expect(gameRecord.comments == [1: "keep", 4: "keep too"])
        #expect(gameRecord.lastModificationDate == dateBefore)
    }

    @Test func commitBranchClearsDataPastDivergenceNotPastNewIndex() {
        // Divergence at index 1; the branch ends at index 3. Data at
        // indices 2-4 belongs to the original tail and must be dropped
        // even though they are <= the NEW currentIndex (3) — i.e.
        // clearData must run before currentIndex is reassigned.
        let gameRecord = GameRecord.createGameRecord(
            sgf: Self.originalSgf,
            currentIndex: 1,
            comments: [0: "root", 1: "divergence", 2: "tail", 3: "tail", 4: "tail"]
        )
        let gobanState = GobanState()
        gobanState.branchSgf = Self.branchLineSgf
        gobanState.branchIndex = 3

        gobanState.commitBranch(gameRecord: gameRecord)

        #expect(gameRecord.comments == [0: "root", 1: "divergence"])
        #expect(gameRecord.currentIndex == 3)
        #expect(gobanState.isBranchActive == false)
    }
}
