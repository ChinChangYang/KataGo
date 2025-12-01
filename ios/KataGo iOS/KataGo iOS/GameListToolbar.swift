//
//  GameListToolbar.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/9/27.
//

import SwiftUI

struct GameListToolbar: ToolbarContent {
    var gameRecord: GameRecord?
    var maxBoardLength: Int
    @Binding var quitStatus: QuitStatus

    var body: some ToolbarContent {
        ToolbarItem(id: "ellipsis") {
            PlusMenuView(gameRecord: gameRecord, maxBoardLength: maxBoardLength)
        }

#if !os(visionOS)
        ToolbarSpacer()
#endif // !os(visionOS)

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
                    maxBoardLength: 19,
                    quitStatus: .constant(.none)
                )
            }
    }
    .environment(NavigationContext())
    .environment(GobanState())
    .environment(ThumbnailModel())
    .environment(TopUIState())
}
