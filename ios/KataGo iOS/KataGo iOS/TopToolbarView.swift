//
//  TopToolbarView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/12.
//

import SwiftUI
import KataGoInterface

struct TopToolbarView: ToolbarContent {
    var gameRecord: GameRecord
    var maxBoardLength: Int
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanState.self) var gobanState
    @Environment(Turn.self) var player

    var body: some ToolbarContent {
        if !gobanState.isBranchActive {
            ToolbarItemGroup {
                PlusMenuView(gameRecord: gameRecord, maxBoardLength: maxBoardLength)
            }

#if !os(visionOS)
            ToolbarSpacer()
#endif // !os(visionOS)

            ToolbarItem(id: "lock") {
                Button {
                    if !gobanState.isAutoPlaying {
                        gobanState.isEditing.toggle()
                    }
                } label: {
                    Image(systemName: gobanState.isEditing ? "lock.open" : "lock")
                        .foregroundStyle(gobanState.isAutoPlaying ? .secondary : .primary)
                }
            }
        } else if let config = gameRecord.config {
            ToolbarItem(id: "arrow.uturn.backward.circle") {
                Button {
                    if !gobanState.shouldGenMove(config: config, player: player) {
                        gobanState.deactivateBranch()
                    }
                } label: {
                    if !gobanState.shouldGenMove(config: config, player: player) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .foregroundStyle(.red)
                    } else {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

#Preview("Default") {
    NavigationStack {
        Text("Toolbar Preview")
            .toolbar {
                TopToolbarView(gameRecord: GameRecord(config: Config()), maxBoardLength: 19)
            }
    }
    .environment(NavigationContext())
    .environment(GobanState())
    .environment(Turn())
    .environment(ThumbnailModel())
    .environment(TopUIState())
}

#Preview("Editing") {
    let gobanState = GobanState()
    gobanState.isEditing = true
    return NavigationStack {
        Text("Toolbar Preview - Editing")
            .toolbar {
                TopToolbarView(gameRecord: GameRecord(config: Config()), maxBoardLength: 19)
            }
    }
    .environment(NavigationContext())
    .environment(gobanState)
    .environment(Turn())
    .environment(ThumbnailModel())
    .environment(TopUIState())
}
