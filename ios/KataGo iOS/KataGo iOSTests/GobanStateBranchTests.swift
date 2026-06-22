//
//  GobanStateBranchTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

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

    @Test func commitBranchUnlocksEditing() {
        // A branch only forms while the game is locked (isEditing == false).
        // Replacing the original game with the branch is an explicit edit, so
        // committing must unlock the game (isEditing == true) — see
        // 2026-06-22-unlock-on-branch-replace-design.md.
        let gameRecord = GameRecord.createGameRecord(
            sgf: Self.originalSgf,
            currentIndex: 2
        )
        let gobanState = GobanState()
        gobanState.isEditing = false // locked, as it always is during a branch
        gobanState.branchSgf = Self.branchLineSgf
        gobanState.branchIndex = 5

        gobanState.commitBranch(gameRecord: gameRecord)

        #expect(gobanState.isEditing == true)
    }

    @Test func commitBranchRequestsUnlockOnReload() {
        // commitBranch ends by deactivating the branch, which drives a board
        // reload through loadGame (the last writer of isEditing). The flag
        // carries the unlock intent across that reload.
        let gameRecord = GameRecord.createGameRecord(
            sgf: Self.originalSgf,
            currentIndex: 2
        )
        let gobanState = GobanState()
        gobanState.branchSgf = Self.branchLineSgf
        gobanState.branchIndex = 5

        gobanState.commitBranch(gameRecord: gameRecord)

        #expect(gobanState.unlockEditingOnReload == true)
    }

    @Test func deactivateBranchKeepsLockState() {
        // The Discard / Cancel path deactivates the branch without committing.
        // Only the Replace path (commitBranch) unlocks, so deactivating must
        // leave the game locked (isEditing == false) and must NOT request an
        // unlock on the reload it triggers.
        let gobanState = GobanState()
        gobanState.isEditing = false
        gobanState.branchSgf = Self.branchLineSgf
        gobanState.branchIndex = 5

        gobanState.deactivateBranch()

        #expect(gobanState.isEditing == false)
        #expect(gobanState.unlockEditingOnReload == false)
        #expect(gobanState.isBranchActive == false)
    }

    @Test func consumeUnlockEditingOnReloadReadsAndClears() {
        // loadGame consumes the one-shot intent via this helper. It must return
        // the pending value AND clear it, so the intent can never leak into a
        // later, unrelated load.
        let gobanState = GobanState()
        gobanState.unlockEditingOnReload = true

        #expect(gobanState.consumeUnlockEditingOnReload() == true)
        #expect(gobanState.unlockEditingOnReload == false)
        // Idempotent: a second consume (e.g. a later unrelated load) sees no intent.
        #expect(gobanState.consumeUnlockEditingOnReload() == false)
    }

    @Test func editingAfterLoadDecidesUnlock() {
        // A brand-new default game starts unlocked for immediate play; a
        // committed-branch reload requests unlock; any other loaded game stays
        // locked.
        #expect(GobanState.editingAfterLoad(sgf: GameRecord.defaultSgf, unlockRequested: false) == true)
        #expect(GobanState.editingAfterLoad(sgf: Self.originalSgf, unlockRequested: false) == false)
        #expect(GobanState.editingAfterLoad(sgf: Self.originalSgf, unlockRequested: true) == true)
        #expect(GobanState.editingAfterLoad(sgf: GameRecord.defaultSgf, unlockRequested: true) == true)
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

    @Test func cloneCurrentPositionClonesBranchLineWhenActive() {
        // Saved mainline frozen at the divergence point (currentIndex 2); the
        // viewed line is the branch at branchIndex 4.
        let gameRecord = GameRecord.createGameRecord(
            sgf: Self.originalSgf,
            currentIndex: 2,
            name: "Game",
            comments: [0: "root", 1: "a", 2: "divergence", 3: "tail", 4: "tail"]
        )
        let gobanState = GobanState()
        gobanState.branchSgf = Self.branchLineSgf
        gobanState.branchIndex = 4

        let copy = gobanState.cloneCurrentPosition(gameRecord: gameRecord)

        // Clones the live branch line truncated to branchIndex (4 of 5 moves).
        #expect(copy.sgf == "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[ee];W[ff])")
        #expect(copy.currentIndex == 4)
        // Per-index data is trimmed to min(currentIndex 2, branchIndex 4) = 2.
        #expect(copy.comments == [0: "root", 1: "a", 2: "divergence"])
        #expect(copy.name == "Game (copy)")
        // Read-only: original game and branch state are untouched.
        #expect(gameRecord.sgf == Self.originalSgf)
        #expect(gameRecord.currentIndex == 2)
        #expect(gobanState.isBranchActive == true)
    }

    @Test func cloneCurrentPositionClonesMainlineWhenNoBranch() {
        let gameRecord = GameRecord.createGameRecord(
            sgf: Self.originalSgf,
            currentIndex: 2,
            name: "Game",
            comments: [0: "root", 1: "a", 2: "b", 3: "tail"]
        )
        let gobanState = GobanState() // no active branch

        let copy = gobanState.cloneCurrentPosition(gameRecord: gameRecord)

        #expect(copy.sgf == "(;FF[4]GM[1]SZ[9];B[aa];W[bb])")
        #expect(copy.currentIndex == 2)
        #expect(copy.comments == [0: "root", 1: "a", 2: "b"])
        #expect(gameRecord.sgf == Self.originalSgf)
    }
}
