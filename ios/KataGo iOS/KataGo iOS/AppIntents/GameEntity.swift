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
    func entities(for identifiers: [GameEntity.ID]) async throws -> [GameEntity] {
        let container = try ModelContainer(for: GameRecord.self)
        let gameRecords = try GameRecord.fetchGameRecords(container: container)
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
        let gameRecords = try GameRecord.fetchGameRecords(container: container, fetchLimit: 3)
        return gameRecords.compactMap { GameEntity(gameRecord: $0) }
    }
}

extension GameEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [GameEntity] {
        let container = try ModelContainer(for: GameRecord.self)
        let gameRecords = try GameRecord.fetchGameRecords(container: container)
        return gameRecords.compactMap { gameRecord in
            if gameRecord.name.localizedCaseInsensitiveContains(string) {
                return GameEntity(gameRecord: gameRecord)
            } else {
                return nil
            }
        }
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

    @Property(title: "Comments")
    var comments: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: "\(comments.first ?? "")",
                              image: DisplayRepresentation.Image(named: "LoadingIcon"))
    }

    init(gameRecord: GameRecord) {
        self.id = gameRecord.uuid ?? UUID()
        self.name = gameRecord.name
        self.comments = gameRecord.comments?.keys.sorted().compactMap { gameRecord.comments?[$0] } ?? []
    }
}
