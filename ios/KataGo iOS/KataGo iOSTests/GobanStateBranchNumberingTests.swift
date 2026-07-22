//
//  GobanStateBranchNumberingTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGoUICore

@MainActor
struct GobanStateBranchNumberingTests {
    // Original line: 4 moves. The branch diverges after move 2 (frozen record
    // currentIndex 2) with 3 new moves at indices 2..4, all on points distinct
    // from the shared prefix so the numbering is unambiguous.
    private static let originalSgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])"
    private static let branchLineSgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[ee];W[ff];B[gg])"

    // Build expected points through the same Location->BoardPoint converter the
    // implementation uses, so the y-flip convention is not re-encoded here.
    private func point(_ x: Int, _ y: Int) -> BoardPoint {
        BoardPoint(location: Location(x: x, y: y), width: 9, height: 9)
    }

    @Test func resolvedStyleIsAllMovesWhileBranchActive() {
        // An active branch always numbers its own stones 1..N (allMoves relative
        // to the divergence), overriding whatever the user picked globally.
        for raw in 0..<Config.moveNumberStyles.count {
            let gobanState = GobanState()
            gobanState.moveNumberStyle = raw
            gobanState.branchSgf = Self.branchLineSgf
            gobanState.branchIndex = 5
            #expect(gobanState.isBranchActive == true)
            #expect(gobanState.resolvedMoveNumberStyle == .allMoves)
        }
    }

    @Test func resolvedStyleIsUserChoiceWhenInactive() {
        for raw in 0..<Config.moveNumberStyles.count {
            let gobanState = GobanState()
            gobanState.moveNumberStyle = raw
            #expect(gobanState.isBranchActive == false)
            #expect(gobanState.resolvedMoveNumberStyle == gobanState.moveNumberStyleChoice)
        }
    }

    @Test func lastThreeMovesStyleIsBypassedInBranchMode() {
        // Global "last 3" would short-circuit getMoveNumbers to .empty on the
        // mainline; in branch mode it must instead number the branch stones from
        // 1 (resolvedMoveNumberStyle == .allMoves bypasses the short-circuit).
        let gameRecord = GameRecord.createGameRecord(sgf: Self.originalSgf, currentIndex: 2)
        let gobanState = GobanState()
        gobanState.moveNumberStyle = MoveNumberStyle.lastThreeMoves.rawValue
        gobanState.branchSgf = Self.branchLineSgf
        gobanState.branchIndex = 5

        let result = gobanState.getMoveNumbers(gameRecord: gameRecord)

        #expect(result != .empty)
        // First branch move (index 2, "ee") is renumbered 1; the shared prefix
        // stones ("aa"/"bb") get no number.
        #expect(result.numbers[point(4, 4)] == 1)
        #expect(result.numbers[point(0, 0)] == nil)
        #expect(result.numbers.count == 3)
        #expect(result.lastNumber == 3)
    }

    @Test func emptyAtDivergencePosition() {
        // branchIndex == the frozen record.currentIndex: the branch has no moves
        // past the divergence yet, so there is nothing to number.
        let gameRecord = GameRecord.createGameRecord(sgf: Self.originalSgf, currentIndex: 2)
        let gobanState = GobanState()
        gobanState.moveNumberStyle = MoveNumberStyle.allMoves.rawValue
        gobanState.branchSgf = Self.branchLineSgf
        gobanState.branchIndex = 2

        #expect(gobanState.getMoveNumbers(gameRecord: gameRecord) == .empty)
    }

    @Test func cacheDoesNotAliasAcrossCommitBranch() {
        // After commitBranch, gameRecord.sgf == branchSgf and currentIndex ==
        // branchIndex, so the (sgf, currentIndex) pair matches the branch-active
        // call's — only startIndex differs (divergence vs 0). The cache key must
        // include startIndex, or the second call would serve the stale
        // branch-relative numbers instead of the absolute ones.
        let gameRecord = GameRecord.createGameRecord(sgf: Self.originalSgf, currentIndex: 2)
        let gobanState = GobanState()
        gobanState.moveNumberStyle = MoveNumberStyle.allMoves.rawValue
        gobanState.branchSgf = Self.branchLineSgf
        gobanState.branchIndex = 5

        // Branch-active: relative numbering (first branch stone "ee" == 1, the
        // root stone "aa" absent) — this is what would poison the cache.
        let active = gobanState.getMoveNumbers(gameRecord: gameRecord)
        #expect(active.numbers[point(4, 4)] == 1)
        #expect(active.numbers[point(0, 0)] == nil)
        #expect(active.numbers.count == 3)

        gobanState.commitBranch(gameRecord: gameRecord)
        #expect(gobanState.isBranchActive == false)

        // Off-branch: absolute numbering from the root — "aa" == 1, all 5 moves.
        let committed = gobanState.getMoveNumbers(gameRecord: gameRecord)
        #expect(committed.numbers[point(0, 0)] == 1)
        #expect(committed.numbers[point(4, 4)] == 3)
        #expect(committed.numbers.count == 5)
        #expect(committed.lastNumber == 5)
    }
}
