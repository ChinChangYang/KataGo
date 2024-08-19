//
//  GameRecordTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2024/8/19.
//

import Testing
@testable import KataGo_iOS

struct GameRecordTests {

    @Test func undoGameRecord() async throws {
        let gameRecord = GameRecord(currentIndex: 1)
        #expect(gameRecord.sgf == GameRecord.defaultSgf)
        #expect(gameRecord.currentIndex == 1)
        #expect(gameRecord.name == GameRecord.defaultName)
        let copy = GameRecord(gameRecord: gameRecord)
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

}
