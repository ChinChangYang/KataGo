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
    public var thumbnail: Data?
    public var boardWidth: Int
    public var boardHeight: Int
    public var lastBlackStones: [String]
    public var lastWhiteStones: [String]

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(firstComment)")
    }

    public init(gameRecord: GameRecord) {
        let sortedComments = gameRecord.comments?.keys.sorted().compactMap { gameRecord.comments?[$0] } ?? []
        let lastIndex = (gameRecord.blackStones?.keys.max()).map { max($0, gameRecord.whiteStones?.keys.max() ?? 0) }
            ?? gameRecord.whiteStones?.keys.max() ?? 0
        self.id = gameRecord.uuid ?? UUID()
        self.firstComment = gameRecord.comments?[0] ?? sortedComments.first ?? ""
        self.thumbnail = gameRecord.thumbnail
        self.boardWidth = gameRecord.width ?? 19
        self.boardHeight = gameRecord.height ?? 19
        self.lastBlackStones = GameEntity.stoneList(gameRecord.blackStones, at: lastIndex)
        self.lastWhiteStones = GameEntity.stoneList(gameRecord.whiteStones, at: lastIndex)
        self.name = gameRecord.name
        self.comments = sortedComments
    }

    /// Stored stone dictionaries map move index → space-joined GTP vertices
    /// (e.g. "Q16 D4"). Returns the vertices for `index`, or [].
    public static func stoneList(_ dict: [Int: String]?, at index: Int) -> [String] {
        guard let raw = dict?[index], !raw.isEmpty else { return [] }
        return raw.split(separator: " ").map(String.init)
    }
}

public struct GameEntityQuery: EntityQuery, EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [GameEntity.ID]) async throws -> [GameEntity] {
        try await MainActor.run { try records().filter { identifiers.contains($0.uuid ?? UUID()) }.map(GameEntity.init) }
    }

    public func suggestedEntities() async throws -> [GameEntity] {
        try await MainActor.run { try records(limit: 20).map(GameEntity.init) }
    }

    public func entities(matching string: String) async throws -> [GameEntity] {
        try await MainActor.run { try records().filter { $0.name.localizedCaseInsensitiveContains(string) }.map(GameEntity.init) }
    }

    @MainActor
    private func records(limit: Int? = nil) throws -> [GameRecord] {
        var gameRecords = try GameRecord.fetchGameRecords(container: SharedModelContainer.shared, fetchLimit: limit)
        try repairDuplicateUUIDs(in: &gameRecords, container: SharedModelContainer.shared)
        return gameRecords
    }

    /// Repairs duplicate UUIDs in the provided game records and assigns new UUIDs to records with nil UUIDs.
    /// - Parameters:
    ///   - gameRecords: The array of `GameRecord` instances to be checked and repaired.
    ///   - container: The `ModelContainer` used to persist changes.
    @MainActor
    private func repairDuplicateUUIDs(in gameRecords: inout [GameRecord], container: ModelContainer) throws {
        // Count occurrences of each UUID
        let uuidCount = Dictionary(gameRecords.compactMap { $0.uuid }.map { ($0, 1) }, uniquingKeysWith: +)

        // Identify duplicate UUIDs
        let duplicateUUIDs = uuidCount.filter { $0.value > 1 }.map { $0.key }
        var seenUUIDs = Set<UUID>()
        var existingUUIDs = Set(uuidCount.keys)

        // Iterate and assign new UUIDs where necessary
        gameRecords.forEach { record in
            if let uuid = record.uuid {
                if duplicateUUIDs.contains(uuid) {
                    if seenUUIDs.contains(uuid) {
                        let newUUID = generateUniqueUUID(existingUUIDs: existingUUIDs)
                        record.uuid = newUUID
                        existingUUIDs.insert(newUUID)
                    } else {
                        seenUUIDs.insert(uuid)
                    }
                }
            } else {
                let newUUID = generateUniqueUUID(existingUUIDs: existingUUIDs)
                record.uuid = newUUID
                existingUUIDs.insert(newUUID)
            }
        }

        // Save the updated game records with repaired UUIDs
        try container.mainContext.save()
    }

    /// Generates a unique UUID not present in the existing UUIDs.
    /// - Parameter existingUUIDs: A set of existing UUIDs.
    /// - Returns: A new unique `UUID`.
    private func generateUniqueUUID(existingUUIDs: Set<UUID>) -> UUID {
        var newUUID: UUID
        repeat {
            newUUID = UUID()
        } while existingUUIDs.contains(newUUID)
        return newUUID
    }
}
