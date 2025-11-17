//
//  GameRecordTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2024/8/19.
//

import Testing
@testable import KataGo_Anytime

struct GameRecordTests {

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
}
