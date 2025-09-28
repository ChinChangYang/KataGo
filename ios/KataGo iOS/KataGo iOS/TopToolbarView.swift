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
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanTab.self) var gobanTab
    @Environment(BranchState.self) var branchState
    @Environment(GobanState.self) var gobanState
    @Environment(Turn.self) var player

    var body: some ToolbarContent {
        if gobanTab.isCommandPresented {
            ToolbarItem(id: "doc.plaintext.fill") {
                Button {
                    withAnimation {
                        gobanTab.isCommandPresented = false
                        gobanTab.isConfigPresented = false
                    }
                } label: {
                    Image(systemName: "doc.plaintext.fill")
                }
            }
        } else if gobanTab.isConfigPresented {
            ToolbarItem(id: "gearshape.fill") {
                Button {
                    withAnimation {
                        gobanTab.isCommandPresented = false
                        gobanTab.isConfigPresented = false
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                }
            }
        } else {
            if !branchState.isActive {
                if gobanState.isEditing {
                    ToolbarItem(id: "gearshape") {
                        Button {
                            withAnimation {
                                gobanTab.isCommandPresented = false
                                gobanTab.isConfigPresented = true
                            }
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }

#if !os(visionOS)
                    if #available(iOS 26.0, *),
                       #available(macOS 26.0, *) {
                        ToolbarSpacer()
                    }
#endif // !os(visionOS)

                    ToolbarItem(id: "lock.open") {
                        Button {
                            if !gobanState.isAutoPlaying {
                                gobanState.isEditing = false
                            }
                        } label: {
                            Image(systemName: "lock.open")
                                .foregroundStyle(gobanState.isAutoPlaying ? .secondary : .primary)
                        }
                    }
                } else {
                    ToolbarItemGroup {
                        PlusMenuView(gameRecord: gameRecord)
                    }

#if !os(visionOS)
                    if #available(iOS 26.0, *),
                       #available(macOS 26.0, *) {
                        ToolbarSpacer()
                    }
#endif // !os(visionOS)

                    ToolbarItem(id: "lock") {
                        Button {
                            if !gobanState.isAutoPlaying {
                                gobanState.isEditing = true
                            }
                        } label: {
                            Image(systemName: "lock")
                                .foregroundStyle(gobanState.isAutoPlaying ? .secondary : .primary)
                        }
                    }
                }
            } else if let config = gameRecord.config {
                ToolbarItem(id: "arrow.uturn.backward.circle") {
                    Button {
                        if !gobanState.shouldGenMove(config: config, player: player) {
                            branchState.deactivate()
                        }
                    } label: {
                        if !gobanState.shouldGenMove(config: config, player: player) {
                            Image(systemName: "arrow.uturn.backward.circle")
                                .foregroundStyle(.red)
                        } else {
                            Image(systemName: "arrow.uturn.backward.circle")
                                .foregroundColor(.secondary)
                        }
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
                TopToolbarView(gameRecord: GameRecord(config: Config()))
            }
    }
    .environment(NavigationContext())
    .environment(GobanTab())
    .environment(BranchState())
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
                TopToolbarView(gameRecord: GameRecord(config: Config()))
            }
    }
    .environment(NavigationContext())
    .environment(GobanTab())
    .environment(BranchState())
    .environment(gobanState)
    .environment(Turn())
    .environment(ThumbnailModel())
    .environment(TopUIState())
}

#Preview("Branch Active") {
    let branchState = BranchState(sgf: ";FF[4]GM[1]SZ[19]", currentIndex: 0)
    return NavigationStack {
        Text("Toolbar Preview - Branch Active")
            .toolbar {
                TopToolbarView(gameRecord: GameRecord(config: Config()))
            }
    }
    .environment(NavigationContext())
    .environment(GobanTab())
    .environment(branchState)
    .environment(GobanState())
    .environment(Turn())
    .environment(ThumbnailModel())
    .environment(TopUIState())
}
