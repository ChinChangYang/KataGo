//
//  GetGameInfo.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/9/14.
//

import AppIntents
import Foundation
import SwiftData

struct GetGameInfo: AppIntent {
    static let title: LocalizedStringResource = "Get Go Game Information"
    static let description = IntentDescription("Provides complete details on a game.",
                                               categoryName: "Discover")

    static var parameterSummary: some ParameterSummary {
        Summary("Get information on \(\.$game)")
    }

    @Parameter(title: "Game", description: "The game to get information on.")
    var game: GameEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let comments = game.comments.joined(separator: ". ")
        return .result(dialog: IntentDialog("\(game.name). \(comments)"))
    }
}

struct GetLatestGameInfo: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Go Game Information"
    static let description = IntentDescription("Provides complete details on the latest game.",
                                               categoryName: "Discover")

    static var parameterSummary: some ParameterSummary {
        Summary("Get information on the latest game")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try ModelContainer(for: GameRecord.self)
        let task = Task {
            await MainActor.run {
                let gameRecords = try? GameRecord.fetchGameRecords(container: container, fetchLimit: 1)
                let firstGame = gameRecords?.first
                let name = firstGame?.name ?? ""
                let comments = firstGame?.comments?.keys.sorted().compactMap { firstGame?.comments?[$0] } ?? []
                return (name, comments)
            }
        }

        let (name, comments) = await task.value
        let joinedComments = comments.joined(separator: ". ")
        return .result(dialog: IntentDialog("\(name). \(joinedComments)"))
    }
}
