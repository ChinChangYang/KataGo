//
//  TopToolbarView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/12.
//

import SwiftUI
import KataGoInterface
import KataGoUICore

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
                    gobanState.isEditing.toggle()
                } label: {
                    Label(gobanState.isEditing ? "Unlock" : "Lock", systemImage: gobanState.isEditing ? "lock.open" : "lock")
                        .labelStyle(.iconOnly)
                }
                .disabled(gobanState.isAutoPlaying)
            }
        } else if let config = gameRecord.config {
            ToolbarItem(id: "arrow.uturn.backward.circle") {
                Button {
                    gobanState.confirmingBranchDeactivation = true
                } label: {
                    Label("Deactivate Branch", systemImage: "arrow.uturn.backward.circle")
                        .labelStyle(.iconOnly)
                }
                .tint(.red)
                .disabled(gobanState.shouldGenMove(config: config, player: player))
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
#Preview("Branch Active") {
    let gobanState = GobanState()
    gobanState.branchSgf = "(;GM[1]FF[4]SZ[19])"
    gobanState.branchIndex = 0
    return NavigationStack {
        Text("Toolbar Preview - Branch Active")
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

