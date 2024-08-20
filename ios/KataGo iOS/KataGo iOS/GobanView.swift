//
//  GobanView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/2.
//

import SwiftUI
import SwiftData
import KataGoInterface

struct GobanItems: View {
    var gameRecord: GameRecord
    @State var toolbarUuid = UUID()
    @Environment(GobanTab.self) var gobanTab
    @Environment(\.horizontalSizeClass) var horizontalSizeClass: UserInterfaceSizeClass?

    var body: some View {
        Group {
            if gobanTab.isCommandPresented {
                CommandView(config: gameRecord.config)
            } else if gobanTab.isConfigPresented {
                ConfigView(gameRecord: gameRecord)
            } else {
                BoardView(config: gameRecord.config)
                    .toolbar {
                        ToolbarItem(placement: .status) {
                            StatusToolbarItems(gameRecord: gameRecord)
                        }
                    }
            }
        }
        .toolbar {
            ToolbarItem {
                TopToolbarView(gameRecord: gameRecord)
                    .id(toolbarUuid)
            }
        }
        .onChange(of: horizontalSizeClass) { _, _ in
            toolbarUuid = UUID()
        }
    }
}

@Observable
class GobanTab {
    var isCommandPresented = false
    var isConfigPresented = false
}

struct GobanView: View {
    @Binding var isInitialized: Bool
    @Binding var isEditorPresented: Bool
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanTab.self) var gobanTab
    @Environment(\.horizontalSizeClass) var horizontalSizeClass: UserInterfaceSizeClass?
    @State var toolbarUuid = UUID()

    var body: some View {
        Group {
            if isInitialized,
               let gameRecord = navigationContext.selectedGameRecord {
                GobanItems(gameRecord: gameRecord)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text(gameRecord.name)
                                .onTapGesture {
                                    isEditorPresented = true
                                }
                                .id(toolbarUuid)
                        }
                    }
                    .onChange(of: horizontalSizeClass) { _, _ in
                        toolbarUuid = UUID()
                    }
            } else {
                ContentUnavailableView("Select a game", systemImage: "sidebar.left")
            }
        }
        .environment(gobanTab)
    }
}
