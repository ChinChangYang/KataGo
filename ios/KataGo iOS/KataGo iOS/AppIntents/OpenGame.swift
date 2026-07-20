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
#if os(macOS)
import AppKit
#endif

struct OpenGame: AppIntent {
    static let title: LocalizedStringResource = "Open Go Game"
    static let description = IntentDescription("Opens a saved game in the app.",
                                               categoryName: "Open")

    /// Run in the foreground: the system opens the app before `perform()`, and
    /// the intent routes in-process. Returning `OpenURLIntent` with the custom
    /// `katago-anytime` scheme is NOT an option — OpenURLIntent supports only
    /// universal links, and on-device Shortcuts refuses the scheme with "The
    /// provided URL scheme 'katago-anytime' is unsupported; launch is
    /// prohibited".
    static let supportedModes: IntentModes = .foreground

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$game)")
    }

    @Parameter(title: "Game", description: "The game to open.")
    var game: GameEntity

    func perform() async throws -> some IntentResult {
        // Route in-process so both platforms reuse the hardened open-by-id
        // pipeline (engine-readiness gating, deleted-game fallback).
        await GameOpener.open(gameID: game.id)
        return .result()
    }
}

struct OpenLatestGame: AppIntent {
    static let title: LocalizedStringResource = "Open Latest Go Game"
    static let description = IntentDescription("Opens the latest game in the app.",
                                               categoryName: "Open")

    /// Foreground-run for in-process routing — see `OpenGame.supportedModes`.
    static let supportedModes: IntentModes = .foreground

    static var parameterSummary: some ParameterSummary {
        Summary("Open the latest game")
    }

    /// Newest record's uuid, or nil when the store is empty. `repair: true` is
    /// allowed here — this intent runs in the main app process (not an appex),
    /// so assigning a uuid to a nil-uuid newest record and saving is permitted;
    /// it guarantees a linkable id. Seam so unit tests can inject a container.
    @MainActor
    static func latestGameID(container: ModelContainer) -> UUID? {
        let records = try? GameEntityQuery.fetchRecords(container: container,
                                                        limit: 1,
                                                        repair: true)
        return records?.first?.uuid
    }

    func perform() async throws -> some IntentResult {
        guard let id = await OpenLatestGame.latestGameID(container: SharedModelContainer.shared)
        else { throw OpenGameError.noSavedGames }
        await GameOpener.open(gameID: id)
        return .result()
    }
}

/// Routes an open-game request into the platform's existing hardened deep-link
/// pipeline, in-process — the system refuses to open the custom scheme on the
/// intents' behalf, so the URL hop is gone. iOS: the shared `DeepLinkRouter`
/// (the same seam the root `.onOpenURL` writes; cold launch reads it after the
/// engine handshake, a warm app applies it via `GameSplitView`'s `.onChange`).
/// macOS: `MainWindowController.selectGame(byID:)` (deleted-game fallback +
/// engine `ReadinessGate` at the `selectGame(_:)` chokepoint).
enum GameOpener {
    @MainActor
    static func open(gameID id: UUID) async {
        #if os(macOS)
        // The same call `application(_:open:)` makes for a deep-link URL, minus
        // the URL. `perform()` normally runs well after
        // `applicationDidFinishLaunching`, but a cold launch is not documented
        // to order them — bounded wait instead of dropping the request.
        for _ in 0..<50 {
            if let windowController = (NSApp.delegate as? AppDelegate)?.windowController {
                windowController.selectGame(byID: id)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #else
        // The same seam the root `.onOpenURL` writes: `ContentView.
        // initializationTask` consumes it on a cold launch (after the engine
        // handshake), and `GameSplitView`'s `.onChange(initial: true)` applies
        // it warm/late.
        DeepLinkRouter.shared.pendingGameID = id
        #endif
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
