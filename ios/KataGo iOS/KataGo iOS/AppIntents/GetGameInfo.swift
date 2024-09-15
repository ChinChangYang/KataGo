//
//  GetGameInfo.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/9/14.
//

import AppIntents
import Foundation

struct GetGameInfo: AppIntent {
    static let title: LocalizedStringResource = "Get Computer Go Game Information"
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
