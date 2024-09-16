//
//  KataGoShortcuts.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/9/13.
//

import Foundation
import AppIntents

class KataGoShortcuts: AppShortcutsProvider {

    static let shortcutTileColor = ShortcutTileColor.yellow

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetGameInfo(),
                    phrases: [
                        "Get \(\.$game) information with \(.applicationName)",
                        "Get information on \(\.$game) with \(.applicationName)",
                        "Show \(\.$game) details using \(.applicationName)",
                        "Find out about \(\.$game) with \(.applicationName)",
                        "Check \(\.$game) info using \(.applicationName)",
                        "Tell me about \(\.$game) with \(.applicationName)"
                    ],
                    shortTitle: "Get Go Game Information",
                    systemImageName: "swirl.circle.righthalf.filled",
                    parameterPresentation: ParameterPresentation(
                        for: \.$game,
                        summary: Summary("Get \(\.$game) information"),
                        optionsCollections: {
                            OptionsCollection(GameEntityQuery(), title: "Go Games", systemImageName: "swirl.circle.righthalf.filled")
                        }
                    )
        )

        AppShortcut(intent: GetLatestGameInfo(),
                    phrases: [
                        "Get the latest go game information with \(.applicationName)",
                        "Get information on the latest go game with \(.applicationName)",
                        "Show the most recent go game details with \(.applicationName)",
                        "Find the latest go game info using \(.applicationName)",
                        "What's the latest go game with \(.applicationName)?",
                        "Tell me the latest go game info with \(.applicationName)"
                    ],
                    shortTitle: "Get Latest Go Game",
                    systemImageName: "swirl.circle.righthalf.filled"
        )
    }
}
