import SwiftData
import Foundation

public struct SavedGameSnapshot: Sendable {
    public var gameID: UUID?
    public var name: String
    public var firstComment: String
    public var thumbnail: Data?
    public var boardWidth: Int
    public var boardHeight: Int
    public var lastBlackStones: [String]
    public var lastWhiteStones: [String]

    public init(gameEntity e: GameEntity) {
        gameID = e.id; name = e.name; firstComment = e.firstComment
        thumbnail = e.thumbnail; boardWidth = e.boardWidth; boardHeight = e.boardHeight
        lastBlackStones = e.lastBlackStones; lastWhiteStones = e.lastWhiteStones
    }

    public static var placeholder: SavedGameSnapshot {
        SavedGameSnapshot(gameID: nil, name: "No game selected",
                          firstComment: "Open KataGo Anytime to choose a game.",
                          thumbnail: nil, boardWidth: 19, boardHeight: 19,
                          lastBlackStones: [], lastWhiteStones: [])
    }

    public init(gameID: UUID?, name: String, firstComment: String, thumbnail: Data?,
                boardWidth: Int, boardHeight: Int, lastBlackStones: [String], lastWhiteStones: [String]) {
        self.gameID = gameID; self.name = name; self.firstComment = firstComment
        self.thumbnail = thumbnail; self.boardWidth = boardWidth; self.boardHeight = boardHeight
        self.lastBlackStones = lastBlackStones; self.lastWhiteStones = lastWhiteStones
    }

    /// Resolve the snapshot the widget should render: the configured game if
    /// present and still existing, else the most-recently-modified game, else a
    /// placeholder.
    @MainActor
    public static func resolveSnapshot(for entity: GameEntity?, container: ModelContainer) -> SavedGameSnapshot {
        // Bounded single-record fetch: the widget extension is memory-constrained,
        // so resolve the configured game with a predicate fetch instead of
        // materializing the whole library and filtering in Swift.
        if let entity,
           let match = (try? GameRecord.fetchGameRecord(uuid: entity.id, container: container)) ?? nil {
            return SavedGameSnapshot(gameEntity: GameEntity(gameRecord: match))
        }
        if let recent = (try? GameRecord.fetchGameRecords(container: container, fetchLimit: 1))?.first {
            return SavedGameSnapshot(gameEntity: GameEntity(gameRecord: recent))
        }
        return .placeholder
    }
}
