//
//  ListenToGame.swift
//  KataGo iOS
//
//  Siri/Shortcuts entry into a Listening Session — the hands-free start the
//  car needs, since Tier 0 has no dash UI. Foreground-run and routed
//  in-process through DeepLinkRouter, exactly like OpenGame (the custom URL
//  scheme is refused by the system: "launch is prohibited").
//

import AppIntents
import Foundation
import KataGoUICore
import SwiftData

struct ListenToGame: AppIntent {
    static let title: LocalizedStringResource = "Listen to Go Game"
    static let description = IntentDescription(
        "Narrates a saved game aloud, move by move.", categoryName: "Listen")

    /// Foreground-run for in-process routing — see `OpenGame.supportedModes`.
    static let supportedModes: IntentModes = .foreground

    static var parameterSummary: some ParameterSummary {
        Summary("Listen to \(\.$game)")
    }

    @Parameter(title: "Game", description: "The game to listen to.")
    var game: GameEntity

    func perform() async throws -> some IntentResult {
        await ListeningStarter.listen(gameID: game.id)
        return .result()
    }
}

struct ListenToLatestGame: AppIntent {
    static let title: LocalizedStringResource = "Listen to Latest Go Game"
    static let description = IntentDescription(
        "Narrates the latest saved game aloud, move by move.", categoryName: "Listen")

    static let supportedModes: IntentModes = .foreground

    static var parameterSummary: some ParameterSummary {
        Summary("Listen to the latest game")
    }

    func perform() async throws -> some IntentResult {
        guard let id = await OpenLatestGame.latestGameID(container: SharedModelContainer.shared)
        else { throw OpenGameError.noSavedGames }
        await ListeningStarter.listen(gameID: id)
        return .result()
    }
}

struct ResumeListening: AppIntent {
    static let title: LocalizedStringResource = "Resume Listening"
    static let description = IntentDescription(
        "Picks the last narrated game back up at its Listening Cursor.",
        categoryName: "Listen")

    static let supportedModes: IntentModes = .foreground

    static var parameterSummary: some ParameterSummary {
        Summary("Resume listening")
    }

    func perform() async throws -> some IntentResult {
        // The last session's game when one is remembered (device-local, like
        // the cursor itself), else the newest game.
        let id: UUID? = await MainActor.run {
            UserDefaultsListeningCursorStore().lastSessionGameID
                ?? OpenLatestGame.latestGameID(container: SharedModelContainer.shared)
        }
        guard let id else { throw OpenGameError.noSavedGames }
        await ListeningStarter.listen(gameID: id)
        return .result()
    }
}

/// The in-process route: latch the id on the shared router; the app root's
/// drain fetches the record and starts the session. The same latch pattern —
/// and the same cold-launch survival story — as `pendingGameID`.
enum ListeningStarter {
    @MainActor
    static func listen(gameID id: UUID) {
        DeepLinkRouter.shared.pendingListenGameID = id
    }
}
