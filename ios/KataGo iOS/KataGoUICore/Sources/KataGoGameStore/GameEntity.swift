//
//  GameEntity.swift
//  KataGoGameStore
//
//  Moved from KataGo iOS/AppIntents/GameEntity.swift and extended with widget fields.
//

import AppIntents
import SwiftData
import Foundation

public struct GameEntity: AppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(stringLiteral: "Computer Go Game")
    }
    nonisolated(unsafe) public static let defaultQuery = GameEntityQuery()

    public let id: UUID
    @Property(title: "Name") public var name: String
    @Property(title: "Comments") public var comments: [String]

    public var firstComment: String
    public var boardWidth: Int
    public var boardHeight: Int
    public var lastBlackStones: [String]
    public var lastWhiteStones: [String]
    /// The displayed position's move index (`GameRecord.currentIndex`). Already in
    /// `fetchGameRecord`'s `propertiesToFetch` and read below for `lastIndex`, so
    /// surfacing it adds no fault. Shown as "Move N" on the systemExtraLarge widget.
    public var moveCount: Int

    public var displayRepresentation: DisplayRepresentation {
        // Use an SF Symbol, not `Image(named:)`: a named asset resolves against
        // the loading process's main bundle, so in the widget configuration
        // picker (a `.appex` with no asset catalog) the previous "LoadingIcon"
        // rendered BLANK. `systemName:` resolves in any process — app, widget
        // appex, and Shortcuts alike — and a board grid reads as a Go game.
        DisplayRepresentation(title: "\(name)", subtitle: "\(firstComment)",
                              image: DisplayRepresentation.Image(systemName: "square.grid.3x3"))
    }

    public init(gameRecord: GameRecord) {
        let sortedComments = gameRecord.comments?.keys.sorted().compactMap { gameRecord.comments?[$0] } ?? []
        // Render the position the game is actually sitting on (currentIndex), not
        // the highest move ever visited. The engine writes blackStones/whiteStones
        // for every index navigated to and plain back-navigation never trims them,
        // so keys.max() can point PAST the displayed move. Fall back to the highest
        // stored index only when currentIndex has no recorded entry (e.g. a record
        // written by a path that didn't fill that index).
        let currentIndex = gameRecord.currentIndex
        let lastIndex: Int
        if gameRecord.blackStones?[currentIndex] != nil || gameRecord.whiteStones?[currentIndex] != nil {
            lastIndex = currentIndex
        } else {
            lastIndex = max(gameRecord.blackStones?.keys.max() ?? 0,
                            gameRecord.whiteStones?.keys.max() ?? 0)
        }
        self.id = gameRecord.uuid ?? UUID()
        self.firstComment = GameEntity.firstComment(from: gameRecord.comments)
        self.boardWidth = gameRecord.width ?? 19
        self.boardHeight = gameRecord.height ?? 19
        self.lastBlackStones = GameEntity.stoneList(gameRecord.blackStones, at: lastIndex)
        self.lastWhiteStones = GameEntity.stoneList(gameRecord.whiteStones, at: lastIndex)
        self.moveCount = currentIndex
        self.name = gameRecord.name
        self.comments = sortedComments
    }

    /// Stored stone dictionaries map move index → space-joined GTP vertices
    /// (e.g. "Q16 D4"). Returns the vertices for `index`, or [].
    public static func stoneList(_ dict: [Int: String]?, at index: Int) -> [String] {
        guard let raw = dict?[index], !raw.isEmpty else { return [] }
        return raw.split(separator: " ").map(String.init)
    }

    /// The comment shown for a game: the move-0 comment, or — for an imported SGF whose
    /// first comment is on a later move — the earliest comment present, else "". ONE
    /// definition shared by `GameEntity.init` (what the widget renders) and
    /// `GameEntityQuery.pickerOptions` (the config-picker subtitle) so the two can never
    /// diverge. `comments` is already faulted by both callers, so the key sort is free.
    public static func firstComment(from comments: [Int: String]?) -> String {
        comments?[0] ?? comments?.keys.sorted().first.flatMap { comments?[$0] } ?? ""
    }
}

/// One configuration-picker row for the Saved Game widget: the value stored on the
/// intent (the game's uuid string, which the widget reads back) plus the title and
/// subtitle shown. Built WITHOUT a full `GameEntity` so the memory-constrained widget
/// extension never faults in a game's heavy per-move board dictionaries just to list
/// names (see `GameRecord.fetchGameRecordsForPicker`).
public struct GamePickerOption: Equatable, Sendable {
    public let id: String        // game uuid string — what the widget restores
    public let title: String     // game name
    public let subtitle: String  // first comment
    public init(id: String, title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

public struct GameEntityQuery: EntityQuery, EntityStringQuery {
    public init() {}

    /// True when running inside an app extension (e.g. the widget or its
    /// configuration intent). Such a process is a SECOND sandbox over the same
    /// CloudKit-synced App-Group store, so it must treat the store as READ-ONLY —
    /// only the main app repairs duplicate UUIDs and persists the fix. (An app
    /// extension is packaged as a `.appex` bundle; the host app is not.)
    /// Delegates to the shared `ProcessKind` detector.
    public static var isAppExtension: Bool {
        ProcessKind.isAppExtension
    }

    public func entities(for identifiers: [GameEntity.ID]) async throws -> [GameEntity] {
        try await MainActor.run { try GameEntityQuery.resolveEntities(for: identifiers, container: SharedModelContainer.shared) }
    }

    public func suggestedEntities() async throws -> [GameEntity] {
        try await MainActor.run { try records(limit: 20).map(GameEntity.init) }
    }

    public func entities(matching string: String) async throws -> [GameEntity] {
        try await MainActor.run { try GameEntityQuery.matchingEntities(for: string, container: SharedModelContainer.shared) }
    }

    /// Resolves the configured-game identifiers WITHOUT materializing the whole
    /// library — one bounded predicate fetch per id (mirrors `fetchGameRecord`).
    /// This is the AppIntents round-trip path for a widget's selected game and runs
    /// in the memory-constrained extension, so it must never do a full-library scan
    /// (the old `entities(for:)` fetched all records and filtered in Swift, which
    /// risked jetsam → empty result → the widget falling back to most-recent).
    /// A duplicate uuid (a CloudKit sync artifact) collapses to the single
    /// most-recently-modified match (fetchLimit 1) rather than an ambiguous pair,
    /// so the configured selection still loads instead of being dropped.
    @MainActor
    public static func resolveEntities(for ids: [UUID], container: ModelContainer) throws -> [GameEntity] {
        // Order-preserving de-dup: a repeated identifier must not yield two
        // GameEntity values for one id (the same ambiguity this change removes for
        // duplicate-uuid records).
        var seen = Set<UUID>()
        return try ids.filter { seen.insert($0).inserted }
            .compactMap { try GameRecord.fetchGameRecord(uuid: $0, container: container) }
            .map(GameEntity.init)
    }

    /// Bounded name search for the configuration picker; never materializes the
    /// whole library in the extension. `localizedStandardContains` is case- AND
    /// diacritic-insensitive; the previous in-Swift filter (`localizedCaseInsensitiveContains`)
    /// was case-insensitive only, so this deliberately broadens the picker match. An
    /// empty query returns the newest `limit` games (see `fetchGameRecords(nameContains:)`).
    @MainActor
    public static func matchingEntities(for query: String, container: ModelContainer, limit: Int = 50) throws -> [GameEntity] {
        try GameRecord.fetchGameRecords(nameContains: query, limit: limit, container: container).map(GameEntity.init)
    }

    /// Footprint-bounded options for the widget configuration picker: the newest
    /// `limit` games, each mapped to (uuid string, name, first comment) via the
    /// property-bounded `fetchGameRecordsForPicker` — never building a `GameEntity`
    /// (which would fault in the heavy board dictionaries and blow the 30 MB widget
    /// memory limit, getting the appex jettisoned and the picker left empty). Records
    /// with a nil uuid are skipped: the read-only extension can't mint a stable id for
    /// them (the main app's `repairStoredIdentities` does), and an option whose value
    /// can't round-trip back to a game is worse than a hidden one. Runs on the main
    /// actor (SwiftData mainContext).
    @MainActor
    public static func pickerOptions(container: ModelContainer, limit: Int) throws -> [GamePickerOption] {
        try GameRecord.fetchGameRecordsForPicker(container: container, fetchLimit: limit)
            .compactMap { record -> GamePickerOption? in
                guard let uuid = record.uuid else { return nil }
                return GamePickerOption(id: uuid.uuidString,
                                        title: record.name,
                                        subtitle: GameEntity.firstComment(from: record.comments))
            }
    }

    /// Proactive identity hygiene for the MAIN app: assign stable, unique, non-nil
    /// UUIDs to records that arrived from CloudKit with nil or duplicate uuids, and
    /// persist, so the widget's AppIntents round-trip (`resolveEntities`) can resolve
    /// a configured game by id. No-op in an app extension (the store is read-only
    /// there) and idempotent (a clean store reassigns 0 and does not save, so it
    /// doesn't churn CloudKit on every launch). The normal in-app game list uses a
    /// plain @Query and never repairs, so without this pass nil/duplicate uuids
    /// would persist and stay unselectable in the widget. Returns the number of
    /// records whose uuid was (re)assigned.
    @MainActor
    @discardableResult
    public static func repairStoredIdentities(container: ModelContainer) throws -> Int {
        guard !isAppExtension else { return 0 }
        var records = try GameRecord.fetchGameRecords(container: container)
        return try repairDuplicateUUIDs(in: &records, container: container)
    }

    @MainActor
    private func records(limit: Int? = nil) throws -> [GameRecord] {
        // Repair (which mutates + saves) only in the main app; never from an
        // extension, where the store is read-only.
        try GameEntityQuery.fetchRecords(container: SharedModelContainer.shared,
                                         limit: limit,
                                         repair: !GameEntityQuery.isAppExtension)
    }

    /// Fetches game records and, when `repair` is true, reassigns duplicate/nil
    /// UUIDs and persists the fix. `repair` MUST be false in app extensions (the
    /// store is read-only there); the main app passes true so the picker /
    /// Shortcuts list always has unique entity IDs.
    @MainActor
    public static func fetchRecords(container: ModelContainer, limit: Int? = nil, repair: Bool) throws -> [GameRecord] {
        var gameRecords = try GameRecord.fetchGameRecords(container: container, fetchLimit: limit)
        if repair {
            try repairDuplicateUUIDs(in: &gameRecords, container: container)
        }
        return gameRecords
    }

    /// Repairs duplicate UUIDs in the provided game records and assigns new UUIDs to records with nil UUIDs.
    /// - Parameters:
    ///   - gameRecords: The array of `GameRecord` instances to be checked and repaired.
    ///   - container: The `ModelContainer` used to persist changes.
    /// - Returns: the number of records whose uuid was (re)assigned. Persists only
    ///   when at least one record changed, so a clean store doesn't churn CloudKit.
    @MainActor
    @discardableResult
    private static func repairDuplicateUUIDs(in gameRecords: inout [GameRecord], container: ModelContainer) throws -> Int {
        // Count occurrences of each UUID
        let uuidCount = Dictionary(gameRecords.compactMap { $0.uuid }.map { ($0, 1) }, uniquingKeysWith: +)

        // Identify duplicate UUIDs
        let duplicateUUIDs = uuidCount.filter { $0.value > 1 }.map { $0.key }
        var seenUUIDs = Set<UUID>()
        var existingUUIDs = Set(uuidCount.keys)
        var reassigned = 0

        // Iterate and assign new UUIDs where necessary
        gameRecords.forEach { record in
            if let uuid = record.uuid {
                if duplicateUUIDs.contains(uuid) {
                    if seenUUIDs.contains(uuid) {
                        let newUUID = generateUniqueUUID(existingUUIDs: existingUUIDs)
                        record.uuid = newUUID
                        existingUUIDs.insert(newUUID)
                        reassigned += 1
                    } else {
                        seenUUIDs.insert(uuid)
                    }
                }
            } else {
                let newUUID = generateUniqueUUID(existingUUIDs: existingUUIDs)
                record.uuid = newUUID
                existingUUIDs.insert(newUUID)
                reassigned += 1
            }
        }

        // Save the updated game records with repaired UUIDs (only when changed).
        if reassigned > 0 {
            try container.mainContext.save()
        }
        return reassigned
    }

    /// Generates a unique UUID not present in the existing UUIDs.
    /// - Parameter existingUUIDs: A set of existing UUIDs.
    /// - Returns: A new unique `UUID`.
    private static func generateUniqueUUID(existingUUIDs: Set<UUID>) -> UUID {
        var newUUID: UUID
        repeat {
            newUUID = UUID()
        } while existingUUIDs.contains(newUUID)
        return newUUID
    }
}
