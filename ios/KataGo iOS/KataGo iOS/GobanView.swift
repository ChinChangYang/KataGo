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
    @Binding var importing: Bool
    @State var toolbarUuid = UUID()
    @Environment(GobanTab.self) var gobanTab
    @Environment(\.horizontalSizeClass) var horizontalSizeClass: UserInterfaceSizeClass?

    var body: some View {
        Group {
            if gobanTab.isCommandPresented {
                CommandView(config: gameRecord.concreteConfig)
            } else if gobanTab.isConfigPresented {
                ConfigView(gameRecord: gameRecord)
            } else {
                PlayView(gameRecord: gameRecord)
            }
        }
        .toolbar {
            ToolbarItem {
                TopToolbarView(gameRecord: gameRecord, importing: $importing)
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
    @Binding var importing: Bool
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanTab.self) var gobanTab
    @Environment(\.horizontalSizeClass) var horizontalSizeClass: UserInterfaceSizeClass?
    @State var toolbarUuid = UUID()

    var body: some View {
        Group {
            if isInitialized,
               let gameRecord = navigationContext.selectedGameRecord {
                GobanItems(gameRecord: gameRecord, importing: $importing)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text(gameRecord.name)
                                .bold()
                                .onTapGesture {
                                    isEditorPresented = true
                                }
                                .id(toolbarUuid)
                        }
                    }
            } else {
                ContentUnavailableView("Select a game", systemImage: "sidebar.left")
                    .toolbar {
                        ToolbarItem {
                            PlusMenuView(gameRecord: nil, importing: $importing)
                                .id(toolbarUuid)
                        }
                    }
            }
        }
        .environment(gobanTab)
        .onChange(of: horizontalSizeClass) { _, _ in
            toolbarUuid = UUID()
        }
    }
}
