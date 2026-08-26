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
    /// The displayed position's comment (see `GameEntity.comment`); "" when that
    /// move has no comment.
    public var comment: String
    public var boardWidth: Int
    public var boardHeight: Int
    public var lastBlackStones: [String]
    public var lastWhiteStones: [String]
    /// The displayed position's move index (`GameRecord.currentIndex`); the
    /// systemExtraLarge layout shows it as a "Move N" line. Free under the widget's
    /// memory budget — `currentIndex` is already in the bounded fetch's
    /// `propertiesToFetch`, so this faults no per-move analysis dictionary.
    public var moveCount: Int

    /// The snapshot for one record, drawn at an already-resolved position.
    ///
    /// Everything positional is keyed on `position.moveIndex` — the stones, the
    /// "Move N" line, and the comment — so the widget cannot caption one move
    /// while drawing another. That was reachable before: the stones came from
    /// whichever index the per-move cache happened to hold and the comment
    /// followed them, so a record parked somewhere the cache never reached
    /// showed a different move than the app did.
    public init(record: GameRecord,
                position: RecordDisplayPosition,
                configuredGameID: UUID? = nil) {
        gameID = record.uuid
        name = record.name
        comment = record.comments?[position.moveIndex] ?? ""
        boardWidth = position.width
        boardHeight = position.height
        lastBlackStones = position.blackVertices
        lastWhiteStones = position.whiteVertices
        moveCount = position.moveIndex
        self.configuredGameID = configuredGameID
    }

    public static var placeholder: SavedGameSnapshot {
        SavedGameSnapshot(gameID: nil, name: "No game selected",
                          comment: "Open KataGo Anytime to choose a game.",
                          boardWidth: 19, boardHeight: 19,
                          lastBlackStones: [], lastWhiteStones: [])
    }

    public init(gameID: UUID?, name: String, comment: String,
                boardWidth: Int, boardHeight: Int, lastBlackStones: [String], lastWhiteStones: [String],
                moveCount: Int = 0, configuredGameID: UUID? = nil) {
        self.gameID = gameID; self.name = name; self.comment = comment
        self.boardWidth = boardWidth; self.boardHeight = boardHeight
        self.lastBlackStones = lastBlackStones; self.lastWhiteStones = lastWhiteStones
        self.moveCount = moveCount
        self.configuredGameID = configuredGameID
    }

    /// How a record's drawn position is resolved.
    ///
    /// Injected rather than called directly because replaying a game needs the
    /// rules, and `GoRulesKit` sits ABOVE this module — see
    /// `RecordDisplayPosition`. There is exactly one implementation in the app
    /// (`GoRulesKit.SgfDisplayPosition.resolve`); the parameter has no default
    /// on purpose, so nothing can quietly fall back to reading the per-move
    /// stone cache again.
    public typealias PositionResolver = @MainActor (GameRecord) -> RecordDisplayPosition?

    /// Resolve the snapshot for an AppIntents-configured entity. Delegates to the
    /// id-based resolver, which renders the configured game when present and falls
    /// back to the most-recently-modified game when `configuration.game` could not be
    /// re-materialized (a nil entity).
    @MainActor
    public static func resolveSnapshot(for entity: GameEntity?,
                                       container: ModelContainer,
                                       position: PositionResolver) -> SavedGameSnapshot {
        resolveSnapshot(configuredID: entity?.id, container: container, position: position)
    }

    /// Resolve the snapshot the widget should render for a configured game id: the
    /// game with that id if it still exists, else the most-recently-modified game,
    /// else a placeholder. `configuredGameID` is carried onto EVERY branch so the tap
    /// deep link (`SavedGameWidgetView` uses `configuredGameID ?? gameID`) targets the
    /// configured game even when the DISPLAY had to fall back to most-recent.
    @MainActor
    public static func resolveSnapshot(configuredID: UUID?,
                                       container: ModelContainer,
                                       position: PositionResolver) -> SavedGameSnapshot {
        // Bounded single-record fetch: the widget extension is memory-constrained,
        // so resolve the configured game with a predicate fetch instead of
        // materializing the whole library and filtering in Swift.
        if let id = configuredID,
           let match = (try? GameRecord.fetchGameRecord(uuid: id, container: container)) ?? nil {
            return snapshot(for: match, configuredGameID: id, position: position)
        }
        // The most-recent fallback is bounded too. It was not: it went through the
        // unbounded `fetchGameRecords`, which materializes a whole record —
        // ownership dictionaries included — making the fallback branch heavier
        // than the configured branch it exists to rescue.
        if let recent = try? GameRecord.fetchMostRecentGameRecord(container: container) {
            return snapshot(for: recent, configuredGameID: configuredID, position: position)
        }
        var placeholder = SavedGameSnapshot.placeholder
        placeholder.configuredGameID = configuredID
        return placeholder
    }

    /// A record's snapshot, or — when its SGF cannot be read — the record with an
    /// empty board of its cached size.
    ///
    /// An unreadable game still resolves rather than falling through to
    /// most-recent: the configured game DOES exist, and quietly showing a
    /// different one would be the same "wrong game" failure from the other end.
    @MainActor
    private static func snapshot(for record: GameRecord,
                                 configuredGameID: UUID?,
                                 position: PositionResolver) -> SavedGameSnapshot {
        let drawn = position(record)
            ?? RecordDisplayPosition.unreadable(width: record.width, height: record.height)
        return SavedGameSnapshot(record: record,
                                 position: drawn,
                                 configuredGameID: configuredGameID)
    }
}
