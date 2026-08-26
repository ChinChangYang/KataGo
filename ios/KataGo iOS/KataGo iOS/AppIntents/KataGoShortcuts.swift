//
//  KataGoShortcuts.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/9/13.
//
//  PAIRED FILE: every phrase below is duplicated, by hand, in SiriPhrasebook
//  (KataGoUICore/Sources/KataGoUICore/Rendering/SiriPhrasesHelpView.swift) —
//  App Shortcut phrases must be string literals (extracted at build time), so
//  the in-app help screen cannot read them back. Change a phrase here → change
//  it there AND in SiriPhrasebookTests, which pins every phrase verbatim; no
//  test can fail on an edit to THIS file alone, so this comment is the guard.
//

import Foundation
import AppIntents
import KataGoUICore

final class KataGoShortcuts: AppShortcutsProvider {

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

        AppShortcut(intent: OpenGame(),
                    phrases: [
                        "Open \(\.$game) with \(.applicationName)",
                        "Open \(\.$game) in \(.applicationName)",
                        "Show \(\.$game) in \(.applicationName)",
                        "Open the game \(\.$game) with \(.applicationName)",
                        "Continue \(\.$game) with \(.applicationName)"
                    ],
                    shortTitle: "Open Go Game",
                    systemImageName: "swirl.circle.righthalf.filled",
                    parameterPresentation: ParameterPresentation(
                        for: \.$game,
                        summary: Summary("Open \(\.$game)"),
                        optionsCollections: {
                            OptionsCollection(GameEntityQuery(), title: "Go Games", systemImageName: "swirl.circle.righthalf.filled")
                        }
                    )
        )

        // Listen ships on iOS only (the CarPlay design); the Mac target
        // compiles this file but not the Listen intents.
        #if os(iOS)
        AppShortcut(intent: ListenToGame(),
                    phrases: [
                        "Listen to \(\.$game) with \(.applicationName)",
                        "Play \(\.$game) aloud with \(.applicationName)",
                        "Narrate \(\.$game) with \(.applicationName)"
                    ],
                    shortTitle: "Listen to Go Game",
                    systemImageName: "headphones",
                    parameterPresentation: ParameterPresentation(
                        for: \.$game,
                        summary: Summary("Listen to \(\.$game)"),
                        optionsCollections: {
                            OptionsCollection(GameEntityQuery(), title: "Go Games", systemImageName: "headphones")
                        }
                    )
        )

        AppShortcut(intent: ListenToLatestGame(),
                    phrases: [
                        "Listen to the latest go game with \(.applicationName)",
                        "Listen to my latest go game with \(.applicationName)",
                        "Narrate my latest go game with \(.applicationName)"
                    ],
                    shortTitle: "Listen to Latest Go Game",
                    systemImageName: "headphones"
        )

        AppShortcut(intent: ResumeListening(),
                    phrases: [
                        "Resume listening with \(.applicationName)",
                        "Keep listening with \(.applicationName)",
                        "Continue my go game narration with \(.applicationName)"
                    ],
                    shortTitle: "Resume Listening",
                    systemImageName: "headphones"
        )
        #endif

        AppShortcut(intent: OpenLatestGame(),
                    phrases: [
                        "Open the latest go game with \(.applicationName)",
                        "Open my latest go game in \(.applicationName)",
                        "Continue the latest go game with \(.applicationName)",
                        "Resume my go game with \(.applicationName)"
                    ],
                    shortTitle: "Open Latest Go Game",
                    systemImageName: "swirl.circle.righthalf.filled"
        )
    }
}
