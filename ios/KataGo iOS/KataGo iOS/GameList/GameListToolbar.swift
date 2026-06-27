//
//  GameListToolbar.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/9/27.
//

import SwiftUI
import KataGoUICore

struct GameListToolbar: ToolbarContent {
    var gameRecord: GameRecord?
    var maxBoardLength: Int
    @Environment(TopUIState.self) private var topUIState

    var body: some ToolbarContent {
        if topUIState.isSelecting {
            // Multi-select is a focused mode: the only top-level control is
            // "Done" (lifted out of the ellipsis menu). The menu itself is
            // hidden so it doesn't compete with the bottom "Delete (N)" action.
            ToolbarItem(id: "done") {
                Button("Done") {
                    withAnimation { topUIState.exitSelection() }
                }
            }
        } else {
            ToolbarItem(id: "ellipsis") {
                PlusMenuView(gameRecord: gameRecord, maxBoardLength: maxBoardLength)
            }
        }
    }
}

#Preview {
    NavigationStack {
        Text("Game List")
            .toolbar {
                GameListToolbar(
                    gameRecord: nil,
                    maxBoardLength: 19
                )
            }
    }
    .environment(NavigationContext())
    .environment(GobanState())
    .environment(ThumbnailModel())
    .environment(TopUIState())
}
