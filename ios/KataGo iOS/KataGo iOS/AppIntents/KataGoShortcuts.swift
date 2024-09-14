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
        AppShortcut(intent: GetGameInfo(), phrases: [
            "Get \(\.$game) information with \(.applicationName)",
            "Get information on \(\.$game) with \(.applicationName)"
        ],
        shortTitle: "Get Information",
        systemImageName: "swirl.circle.righthalf.filled",
        parameterPresentation: ParameterPresentation(
            for: \.$game,
            summary: Summary("Get \(\.$game) information"),
            optionsCollections: {
                OptionsCollection(GameEntityQuery(), title: "Go Games", systemImageName: "swirl.circle.righthalf.filled")
            }
        ))
    }
}
