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
    private func createFetchDescriptor() -> FetchDescriptor<GameRecord> {
        let descriptor = FetchDescriptor<GameRecord>(
            sortBy: [.init(\.lastModificationDate, order: .reverse)]
        )
        return descriptor
    }

    private func fetchGameRecords(container: ModelContainer) throws -> [GameRecord] {
        let context = container.mainContext
        let descriptor = createFetchDescriptor()
        return try context.fetch(descriptor)
    }

    func entities(for identifiers: [GameEntity.ID]) async throws -> [GameEntity] {
        let container = try ModelContainer(for: GameRecord.self)
        let gameRecords = try fetchGameRecords(container: container)
        return gameRecords.compactMap { gameRecord in
            if let uuid = gameRecord.uuid,
               identifiers.contains(uuid) {
                return GameEntity(gameRecord: gameRecord)
            } else {
                return nil
            }
        }
    }

    func suggestedEntities() async throws -> [GameEntity] {
        let container = try ModelContainer(for: GameRecord.self)
        let gameRecords = try fetchGameRecords(container: container)
        return gameRecords.compactMap { GameEntity(gameRecord: $0) }
    }
}

struct GameEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(stringLiteral: "Computer Go Game")
    }

    static let defaultQuery = GameEntityQuery()

    var id: UUID

    @Property(title: "Name")
    var name: String

    @Property(title: "Comment")
    var comment: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: "\(comment)",
                              image: DisplayRepresentation.Image(named: "LoadingIcon"))
    }

    init(gameRecord: GameRecord) {
        self.id = gameRecord.uuid ?? UUID()
        self.name = gameRecord.name
        self.comment = gameRecord.comments?[0] ?? ""
    }
}
