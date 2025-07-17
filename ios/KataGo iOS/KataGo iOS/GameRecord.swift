//
//  GameRecord.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/7/7.
//

import Foundation
import SwiftData
import KataGoInterface

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
    var thumbnail: Data?
    var scoreLeads: [Int: Float]?

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
         comments: [Int: String]? = [:],
         thumbnail: Data? = nil,
         scoreLeads: [Int: Float]? = [:]) {
        self.sgf = sgf
        self.currentIndex = currentIndex
        self.config = config
        self.name = name
        self.lastModificationDate = lastModificationDate
        self.comments = comments
        self.thumbnail = thumbnail
        self.scoreLeads = scoreLeads
    }

    func clone() -> GameRecord {
        let newConfig = Config(config: self.config)
        let newGameRecord = GameRecord(sgf: self.sgf,
                                       currentIndex: self.currentIndex,
                                       config: newConfig,
                                       name: self.name + " (copy)",
                                       lastModificationDate: Date.now,
                                       comments: self.comments,
                                       thumbnail: self.thumbnail,
                                       scoreLeads: self.scoreLeads)
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

    func clearScoreLeads(after index: Int) {
        guard let scoreLeads = scoreLeads else { return }
        self.scoreLeads = scoreLeads.filter { $0.key <= index }
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
                                name: String = defaultName,
                                comments: [Int: String]? = [:],
                                thumbnail: Data? = nil,
                                scoreLeads: [Int: Float]? = [:]) -> GameRecord {
        let config = Config()
        let sgfHelper = SgfHelper(sgf: sgf)
        config.boardWidth = sgfHelper.xSize
        config.boardHeight = sgfHelper.ySize
        config.komi = sgfHelper.rules.komi

        let gameRecord = GameRecord(sgf: sgf,
                                    currentIndex: currentIndex,
                                    config: config,
                                    name: name,
                                    comments: comments,
                                    thumbnail: thumbnail,
                                    scoreLeads: scoreLeads)

        config.gameRecord = gameRecord

        return gameRecord
    }

    class func createGameRecord(from file: URL) -> GameRecord? {
        guard file.startAccessingSecurityScopedResource() else { return nil }

        // Get the name
        let name = file.deletingPathExtension().lastPathComponent

        // Attempt to read the contents of the file into a string; exit if reading fails
        guard let fileContents = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        // Release access
        file.stopAccessingSecurityScopedResource()

        // Initialize the SGF helper with the file contents
        let sgfHelper = SgfHelper(sgf: fileContents)

        // Get the index of the last move in the SGF file; exit if the SGF is invalid
        guard let moveSize = sgfHelper.moveSize else { return nil }

        // Create a dictionary of comments for each move by filtering and mapping non-empty comments
        let comments = (0...moveSize)
            .compactMap { index in sgfHelper.getComment(at: index).flatMap { !$0.isEmpty ? (index, $0) : nil } }
            .reduce(into: [:]) { $0[$1.0] = $1.1 }

        // Create a new game record with the SGF content, the current move index, the name, and the comments
        return GameRecord.createGameRecord(sgf: fileContents,
                                           currentIndex: moveSize,
                                           name: name,
                                           comments: comments)
    }
}
