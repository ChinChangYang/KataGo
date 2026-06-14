//
//  GameRecordTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2024/8/19.
//

import Testing
import SwiftData
@testable import KataGo_Anytime

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
}
