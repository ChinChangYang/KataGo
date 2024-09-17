//
//  GameEntity.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/9/14.
//

import AppIntents
import SwiftData

@MainActor
struct GameEntityQuery: EntityQuery {
    
    /// Fetches and repairs game records, ensuring unique UUIDs.
    /// - Parameter fetchLimit: Optional limit for fetching records.
    /// - Returns: An array of repaired `GameRecord` instances.
    private func fetchAndRepairGameRecords(fetchLimit: Int? = nil, container: ModelContainer) async throws -> [GameRecord] {
        var gameRecords = try GameRecord.fetchGameRecords(container: container, fetchLimit: fetchLimit)
        try repairDuplicateUUIDs(in: &gameRecords, container: container)
        return gameRecords
    }
    
    /// Retrieves `GameEntity` instances matching the provided identifiers.
    /// - Parameter identifiers: An array of `UUID` identifiers.
    /// - Returns: An array of `GameEntity` instances.
    func entities(for identifiers: [GameEntity.ID]) async throws -> [GameEntity] {
        let container = try ModelContainer(for: GameRecord.self)
        let gameRecords = try await fetchAndRepairGameRecords(container: container)
        return gameRecords
            .compactMap { record in
                guard let uuid = record.uuid, identifiers.contains(uuid) else { return nil }
                return GameEntity(gameRecord: record)
            }
    }
    
    /// Retrieves a limited number of suggested `GameEntity` instances.
    /// - Returns: An array of up to three `GameEntity` instances.
    func suggestedEntities() async throws -> [GameEntity] {
        let container = try ModelContainer(for: GameRecord.self)
        let gameRecords = try await fetchAndRepairGameRecords(fetchLimit: 20, container: container)
        return gameRecords.map { GameEntity(gameRecord: $0) }
    }
    
    /// Repairs duplicate UUIDs in the provided game records and assigns new UUIDs to records with nil UUIDs.
    /// - Parameters:
    ///   - gameRecords: The array of `GameRecord` instances to be checked and repaired.
    ///   - container: The `ModelContainer` used to persist changes.
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

extension GameEntityQuery: EntityStringQuery {
    /// Retrieves `GameEntity` instances matching the provided string in their names.
    /// - Parameter string: The string to match against game names.
    /// - Returns: An array of matching `GameEntity` instances.
    func entities(matching string: String) async throws -> [GameEntity] {
        let container = try ModelContainer(for: GameRecord.self)
        let gameRecords = try await fetchAndRepairGameRecords(container: container)
        return gameRecords
            .compactMap { record in
                guard let _ = record.uuid,
                      record.name.localizedCaseInsensitiveContains(string) else {
                    return nil
                }
                return GameEntity(gameRecord: record)
            }
    }
}

struct GameEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(stringLiteral: "Computer Go Game")
    }
    
    static let defaultQuery = GameEntityQuery()
    
    let id: UUID
    
    @Property(title: "Name")
    var name: String
    
    @Property(title: "Comments")
    var comments: [String]
    
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: "\(comments.first ?? "")",
                              image: DisplayRepresentation.Image(named: "LoadingIcon"))
    }
    
    /// Initializes a `GameEntity` from a `GameRecord`.
    /// - Parameter gameRecord: The `GameRecord` to initialize from.
    init(gameRecord: GameRecord) {
        self.id = gameRecord.uuid ?? UUID()
        self.name = gameRecord.name
        self.comments = gameRecord.comments?.keys.sorted().compactMap { gameRecord.comments?[$0] } ?? []
    }
}
