//
//  GameRecordTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2024/8/19.
//

import Testing
import SwiftData
import KataGoUICore
@testable import KataGo_Anytime
@testable import KataGoUICore

struct GameRecordTests {

    /// Creates an in-memory ModelContainer for testing SwiftData queries.
    private static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([GameRecord.self, Config.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func findExistingGameRecord_noMatch() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let result = GameRecord.findExistingGameRecord(withSgf: "(;FF[4]GM[1]SZ[9])", in: context)
        #expect(result == nil)
    }

    @Test func findExistingGameRecord_matchingSgf() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let sgf = "(;FF[4]GM[1]SZ[9])"
        let record = GameRecord.createGameRecord(sgf: sgf, name: "Test")
        context.insert(record)
        try context.save()

        let found = GameRecord.findExistingGameRecord(withSgf: sgf, in: context)
        #expect(found != nil)
        #expect(found?.sgf == sgf)
        #expect(found?.name == "Test")
    }

    @Test func findExistingGameRecord_differentSgf() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let record = GameRecord.createGameRecord(sgf: "(;FF[4]GM[1]SZ[9])", name: "Test")
        context.insert(record)
        try context.save()

        let found = GameRecord.findExistingGameRecord(withSgf: "(;FF[4]GM[1]SZ[19])", in: context)
        #expect(found == nil)
    }

    // F2: an imported game must carry its final board position so the Saved Game
    // widget can render it before the game is ever opened (no engine, no thumbnail).
    @Test func importGameRecord_populatesFinalStonesAtMoveSize() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        let result = GameRecord.importGameRecord(sgf: sgf, name: "Imported", in: context)
        let record = try #require(result?.gameRecord)
        #expect(result?.isNew == true)
        #expect(record.currentIndex == 2)
        // Stored at the final move index, so GameEntity's lastIndex resolves here.
        #expect(record.blackStones?[2] == "D16")
        #expect(record.whiteStones?[2] == "Q4")
    }

    @Test func importGameRecord_finalStonesFeedGameEntity() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        // 9x9 capture: Black A9 is captured; only G3 (black) and B9/A8 (white) remain.
        let sgf = "(;FF[4]GM[1]SZ[9];B[aa];W[ba];B[gg];W[ab])"
        let result = GameRecord.importGameRecord(sgf: sgf, name: "Imported", in: context)
        let record = try #require(result?.gameRecord)
        let entity = GameEntity(gameRecord: record)
        #expect(entity.lastBlackStones == ["G3"])
        #expect(entity.lastWhiteStones.sorted() == ["A8", "B9"])
    }

    @Test func undoGameRecord() async throws {
        let gameRecord = GameRecord.createGameRecord(currentIndex: 1)
        #expect(gameRecord.sgf == GameRecord.defaultSgf)
        #expect(gameRecord.currentIndex == 1)
        #expect(gameRecord.name == GameRecord.defaultName)
        let copy = gameRecord.clone()
        #expect(gameRecord.sgf == copy.sgf)
        #expect(gameRecord.currentIndex == copy.currentIndex)
        #expect(gameRecord.config !== copy.config)
        #expect(gameRecord.name != copy.name)
        #expect(gameRecord.lastModificationDate != copy.lastModificationDate)
        copy.undo()
        #expect(gameRecord.currentIndex == 1)
        #expect(copy.currentIndex == 0)
        copy.undo()
        #expect(copy.currentIndex == 0)
    }

    @Test func testclearData_noComments() async throws {
        let gameRecord = GameRecord.createGameRecord(comments: nil)
        gameRecord.clearData(after: 0)
        #expect(gameRecord.comments == nil)
    }

    @Test func testclearData_emptyComments() async throws {
        let gameRecord = GameRecord.createGameRecord(comments: [:])
        gameRecord.clearData(after: 0)
        #expect(gameRecord.comments?.isEmpty == true)
    }

    @Test func testclearData_allCommentsCleared() async throws {
        let gameRecord = GameRecord.createGameRecord(comments: [1: "Comment 1", 2: "Comment 2", 3: "Comment 3"])
        gameRecord.clearData(after: 0)
        #expect(gameRecord.comments?.isEmpty == true)
    }

    @Test func testclearData_someCommentsRemain() async throws {
        let gameRecord = GameRecord.createGameRecord(comments: [1: "Comment 1", 2: "Comment 2", 3: "Comment 3"])
        gameRecord.clearData(after: 2)
        #expect(gameRecord.comments?.count == 2)
        #expect(gameRecord.comments?[1] == "Comment 1")
        #expect(gameRecord.comments?[2] == "Comment 2")
        #expect(gameRecord.comments?[3] == nil)
    }

    @Test func testclearData_noCommentsCleared() async throws {
        let gameRecord = GameRecord.createGameRecord(comments: [1: "Comment 1", 2: "Comment 2", 3: "Comment 3"])
        gameRecord.clearData(after: 3)
        #expect(gameRecord.comments?.count == 3)
        #expect(gameRecord.comments?[1] == "Comment 1")
        #expect(gameRecord.comments?[2] == "Comment 2")
        #expect(gameRecord.comments?[3] == "Comment 3")
    }

    @Test func testclearData_withNegativeIndex() async throws {
        let gameRecord = GameRecord.createGameRecord(comments: [1: "Comment 1", 2: "Comment 2", 3: "Comment 3"])
        gameRecord.clearData(after: -1)
        #expect(gameRecord.comments?.isEmpty == true)
    }

    @Test func cloneUpToMoveTruncatesSgfAndData() async throws {
        let sgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])"
        let record = GameRecord.createGameRecord(
            sgf: sgf,
            currentIndex: 4,
            name: "Game",
            comments: [0: "z", 1: "a", 2: "b", 3: "c", 4: "d"],
            winRates: [1: 0.5, 2: 0.6, 3: 0.7, 4: 0.8]
        )

        let copy = record.clone(upToMove: 2)

        #expect(copy.sgf == "(;FF[4]GM[1]SZ[9];B[aa];W[bb])")
        #expect(copy.currentIndex == 2)
        #expect(copy.comments == [0: "z", 1: "a", 2: "b"])
        #expect(copy.winRates == [1: 0.5, 2: 0.6])
        #expect(copy.name == "Game (copy)")
        #expect(record.config !== copy.config)
        // Original is untouched.
        #expect(record.sgf == sgf)
        #expect(record.currentIndex == 4)
    }

    @Test func cloneUpToMoveFromBranchSgfTruncatesLiveLine() async throws {
        // A branch is active: the saved record is the OLD mainline frozen at the
        // divergence point (currentIndex == 1), while the line on screen is a
        // different branch SGF the user navigated into (branchIndex == 3).
        // "Clone Current Position" must copy the branch line the user sees, not
        // the stale mainline, and per-index data is only valid up to divergence.
        let mainlineSgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb])"
        let branchSgf = "(;FF[4]GM[1]SZ[9];B[aa];W[cc];B[dd];W[ee])"
        let record = GameRecord.createGameRecord(
            sgf: mainlineSgf,
            currentIndex: 1,          // divergence point
            name: "Game",
            comments: [0: "z", 1: "a", 2: "old-b"],
            winRates: [1: 0.5, 2: 0.6]
        )

        let copy = record.clone(
            upToMove: 3,
            fromSgf: branchSgf,
            dataValidUpTo: min(record.currentIndex, 3)  // == 1
        )

        // SGF/index follow the branch line, not the frozen mainline.
        #expect(copy.sgf == "(;FF[4]GM[1]SZ[9];B[aa];W[cc];B[dd])")
        #expect(copy.currentIndex == 3)
        #expect(SgfHelper(sgf: copy.sgf).moveSize == 3)
        // Per-index data is trimmed to the divergence point (<= 1); stale
        // mainline data past divergence (index 2) is dropped.
        #expect(copy.comments == [0: "z", 1: "a"])
        #expect(copy.winRates == [1: 0.5])
        #expect(copy.name == "Game (copy)")
        #expect(record.config !== copy.config)
        // Original is untouched.
        #expect(record.sgf == mainlineSgf)
        #expect(record.currentIndex == 1)
    }

    // MARK: - TopUIState multi-select state

    @Test func topUIState_toggle_addsAbsentID() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let record = GameRecord.createGameRecord(name: "A")
        context.insert(record)
        try context.save()

        let state = TopUIState()
        state.toggle(record.persistentModelID)

        #expect(state.selectedGameIDs.contains(record.persistentModelID))
        #expect(state.selectionCount == 1)
    }

    @Test func topUIState_toggle_removesPresentID() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let record = GameRecord.createGameRecord(name: "A")
        context.insert(record)
        try context.save()

        let state = TopUIState()
        state.selectedGameIDs = [record.persistentModelID]
        state.toggle(record.persistentModelID)

        #expect(state.selectedGameIDs.isEmpty)
        #expect(state.selectionCount == 0)
    }

    @Test func topUIState_exitSelection_clearsFlagAndSet() async throws {
        let container = try GameRecordTests.makeInMemoryContainer()
        let context = ModelContext(container)
        let a = GameRecord.createGameRecord(name: "A")
        let b = GameRecord.createGameRecord(name: "B")
        context.insert(a)
        context.insert(b)
        try context.save()

        let state = TopUIState()
        state.isSelecting = true
        state.selectedGameIDs = [a.persistentModelID, b.persistentModelID]
        state.exitSelection()

        #expect(state.isSelecting == false)
        #expect(state.selectedGameIDs.isEmpty)
        #expect(state.selectionCount == 0)
    }
}
