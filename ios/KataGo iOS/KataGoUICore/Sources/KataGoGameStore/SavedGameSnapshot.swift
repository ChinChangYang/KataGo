import SwiftData
import Foundation

public struct SavedGameSnapshot: Sendable {
    public var gameID: UUID?
    /// The user's EXPLICIT configured selection (the widget configuration intent's
    /// game id), independent of `gameID` (the resolved DISPLAY game). They diverge
    /// only when the display had to fall back to most-recent because the configured
    /// game couldn't be resolved; `SavedGameWidgetView` builds the tap URL from
    /// `configuredGameID ?? gameID`, so the tap always targets the user's choice.
    /// Nil when the widget is unconfigured (tap then opens the displayed most-recent).
    public var configuredGameID: UUID?
    public var name: String
    public var firstComment: String
    public var boardWidth: Int
    public var boardHeight: Int
    public var lastBlackStones: [String]
    public var lastWhiteStones: [String]

    public init(gameEntity e: GameEntity, configuredGameID: UUID? = nil) {
        gameID = e.id; name = e.name; firstComment = e.firstComment
        boardWidth = e.boardWidth; boardHeight = e.boardHeight
        lastBlackStones = e.lastBlackStones; lastWhiteStones = e.lastWhiteStones
        self.configuredGameID = configuredGameID
    }

    public static var placeholder: SavedGameSnapshot {
        SavedGameSnapshot(gameID: nil, name: "No game selected",
                          firstComment: "Open KataGo Anytime to choose a game.",
                          boardWidth: 19, boardHeight: 19,
                          lastBlackStones: [], lastWhiteStones: [])
    }

    public init(gameID: UUID?, name: String, firstComment: String,
                boardWidth: Int, boardHeight: Int, lastBlackStones: [String], lastWhiteStones: [String],
                configuredGameID: UUID? = nil) {
        self.gameID = gameID; self.name = name; self.firstComment = firstComment
        self.boardWidth = boardWidth; self.boardHeight = boardHeight
        self.lastBlackStones = lastBlackStones; self.lastWhiteStones = lastWhiteStones
        self.configuredGameID = configuredGameID
    }

    /// Resolve the snapshot for an AppIntents-configured entity. Delegates to the
    /// id-based resolver so the widget provider can pass a CACHED id when the live
    /// `configuration.game` intermittently resolves to nil (see
    /// `WidgetConfiguredGameStore`).
    @MainActor
    public static func resolveSnapshot(for entity: GameEntity?, container: ModelContainer) -> SavedGameSnapshot {
        resolveSnapshot(configuredID: entity?.id, container: container)
    }

    /// Resolve the snapshot the widget should render for a configured game id: the
    /// game with that id if it still exists, else the most-recently-modified game,
    /// else a placeholder. `configuredGameID` is carried onto EVERY branch so the tap
    /// deep link (`SavedGameWidgetView` uses `configuredGameID ?? gameID`) targets the
    /// configured game even when the DISPLAY had to fall back to most-recent.
    @MainActor
    public static func resolveSnapshot(configuredID: UUID?, container: ModelContainer) -> SavedGameSnapshot {
        // Bounded single-record fetch: the widget extension is memory-constrained,
        // so resolve the configured game with a predicate fetch instead of
        // materializing the whole library and filtering in Swift.
        if let id = configuredID,
           let match = (try? GameRecord.fetchGameRecord(uuid: id, container: container)) ?? nil {
            return SavedGameSnapshot(gameEntity: GameEntity(gameRecord: match), configuredGameID: id)
        }
        if let recent = (try? GameRecord.fetchGameRecords(container: container, fetchLimit: 1))?.first {
            return SavedGameSnapshot(gameEntity: GameEntity(gameRecord: recent), configuredGameID: configuredID)
        }
        var placeholder = SavedGameSnapshot.placeholder
        placeholder.configuredGameID = configuredID
        return placeholder
    }
}
