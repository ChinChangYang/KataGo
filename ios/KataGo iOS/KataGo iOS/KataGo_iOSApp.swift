//
//  KataGo_iOSApp.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/7/2.
//

import SwiftUI

@main
struct KataGo_iOSApp: App {
    init() {
        KataGoShortcuts.updateAppShortcutParameters()
    }

    var scene: some Scene {
#if os(macOS)
        Window("KataGo Anytime", id: "KataGo Anytime") {
            ContentView()
        }
#else
        WindowGroup {
            ContentView()
        }
#endif
    }

    var body: some Scene {
        scene.modelContainer(for: GameRecord.self)
    }
}
