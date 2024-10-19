//
//  GameRecord.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/7/7.
//

import Foundation
import SwiftData

@Model
final class GameRecord {
    static let defaultSgf = "(;FF[4]GM[1]SZ[19]PB[]PW[]HA[0]KM[7]RU[koSIMPLEscoreAREAtaxNONEsui0whbN])"
    static let defaultName = "New Game"
    var sgf: String = defaultSgf
    var currentIndex: Int = 0
    // The iCloud servers don’t guarantee atomic processing of relationship changes,
    // so CloudKit requires all relationships to be optional.
    @Relationship(deleteRule: .cascade) var config: Config?
    var name: String = defaultName
    var lastModificationDate: Date?
    var comments: [Int: String]?
    var uuid: UUID? = UUID()

    var concreteConfig: Config {
        // A config must not be nil in any case.
        // If it is not the case, there is a bug in the GameRecord initialization function.
        // Anyway, it will create a default config for this case, but the config is probably wrong.
        assert(self.config != nil)
        if let config {
            return config
        } else {
            let newConfig = Config(gameRecord: self)
            self.config = newConfig
            return newConfig
        }
    }

    init(sgf: String = defaultSgf,
         currentIndex: Int = 0,
         config: Config,
         name: String = defaultName,
         lastModificationDate: Date? = Date.now,
         comments: [Int: String]? = [:]) {
        self.sgf = sgf
        self.currentIndex = currentIndex
        self.config = config
        self.name = name
        self.lastModificationDate = lastModificationDate
        self.comments = comments
    }

    func clone() -> GameRecord {
        let newConfig = Config(config: self.config)
        let newGameRecord = GameRecord(sgf: self.sgf,
                                       currentIndex: self.currentIndex,
                                       config: newConfig,
                                       name: self.name + " (copy)",
                                       lastModificationDate: Date.now,
                                       comments: self.comments)
        newConfig.gameRecord = newGameRecord
        return newGameRecord
    }

    func undo() {
        if (currentIndex > 0) {
            currentIndex = currentIndex - 1
        }
    }

    func clearComments(after index: Int) {
        guard let comments = comments else { return }
        self.comments = comments.filter { $0.key <= index }
    }

    class func createFetchDescriptor(fetchLimit: Int? = nil) -> FetchDescriptor<GameRecord> {
        var descriptor = FetchDescriptor<GameRecord>(
            sortBy: [.init(\.lastModificationDate, order: .reverse)]
        )
        descriptor.fetchLimit = fetchLimit
        return descriptor
    }

    @MainActor
    class func fetchGameRecords(container: ModelContainer, fetchLimit: Int? = nil) throws -> [GameRecord] {
        let context = container.mainContext
        let descriptor = createFetchDescriptor(fetchLimit: fetchLimit)
        return try context.fetch(descriptor)
    }

    class func createGameRecord(sgf: String = defaultSgf,
                                currentIndex: Int = 0,
                                comments: [Int: String]? = [:]) -> GameRecord {
        let config = Config()
        let gameRecord = GameRecord(sgf: sgf, currentIndex: currentIndex, config: config, comments: comments)
        config.gameRecord = gameRecord
        return gameRecord
    }
}
