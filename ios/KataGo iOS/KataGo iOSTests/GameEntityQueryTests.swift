//
//  GameEntityQueryTests.swift
//  KataGo iOSTests
//

import Testing
import SwiftData
import Foundation
import KataGoUICore

struct GameEntityQueryTests {
    @Test @MainActor func gameEntity_capturesNameAndFirstComment() throws {
        let record = GameRecord(config: Config())
        record.name = "Opening Study"
        record.comments = [0: "Black takes 4-4", 1: "White approaches"]
        record.width = 19
        record.height = 19
        let entity = GameEntity(gameRecord: record)
        #expect(entity.name == "Opening Study")
        #expect(entity.firstComment == "Black takes 4-4")
        #expect(entity.boardWidth == 19)
    }
}
