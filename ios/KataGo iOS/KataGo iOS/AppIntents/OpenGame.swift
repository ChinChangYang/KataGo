//
//  OpenGame.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2026/7/17.
//

import AppIntents
import KataGoUICore
import Foundation
import SwiftData

struct OpenGame: AppIntent {
    static let title: LocalizedStringResource = "Open Go Game"
    static let description = IntentDescription("Opens a saved game in the app.",
                                               categoryName: "Open")

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$game)")
    }

    @Parameter(title: "Game", description: "The game to open.")
    var game: GameEntity

    func perform() async throws -> some IntentResult & OpensIntent {
        // Route through the deep-link URL so both platforms reuse the hardened
        // open-by-id pipeline (engine-readiness gating, deleted-game fallback).
        .result(opensIntent: OpenURLIntent(GameDeepLink.url(for: game.id)))
    }
}

struct OpenLatestGame: AppIntent {
    static let title: LocalizedStringResource = "Open Latest Go Game"
    static let description = IntentDescription("Opens the latest game in the app.",
                                               categoryName: "Open")

    static var parameterSummary: some ParameterSummary {
        Summary("Open the latest game")
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        // repair: true is allowed here — this intent runs in the main app process
        // (not an appex), so assigning a uuid to a nil-uuid newest record and
        // saving is permitted; it guarantees a linkable id.
        let id: UUID? = await MainActor.run {
            let records = try? GameEntityQuery.fetchRecords(container: SharedModelContainer.shared,
                                                            limit: 1,
                                                            repair: true)
            return records?.first?.uuid
        }
        guard let id else { throw OpenGameError.noSavedGames }
        return .result(opensIntent: OpenURLIntent(GameDeepLink.url(for: id)))
    }
}

enum OpenGameError: Error, CustomLocalizedStringResourceConvertible {
    case noSavedGames

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noSavedGames:
            "There are no saved games to open."
        }
    }
}
