//
//  GameListToolbar.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/9/27.
//

import SwiftUI

struct GameListToolbar: ToolbarContent {
    var gameRecord: GameRecord?
    @Binding var quitStatus: QuitStatus

    var body: some ToolbarContent {
        ToolbarItem(id: "ellipsis") {
            PlusMenuView(gameRecord: gameRecord)
        }

        if #available(iOS 26.0, *),
           #available(macOS 26.0, *) {
            ToolbarSpacer()
        }

        ToolbarItem(id: "quit") {
            QuitButton(quitStatus: $quitStatus)
        }
    }
}

#Preview {
    NavigationStack {
        Text("Game List")
            .toolbar {
                GameListToolbar(
                    gameRecord: nil,
                    quitStatus: .constant(.none)
                )
            }
    }
    .environment(NavigationContext())
    .environment(GobanTab())
    .environment(GobanState())
    .environment(ThumbnailModel())
    .environment(TopUIState())
}
