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
    @Environment(\.horizontalSizeClass) var horizontalSizeClass: UserInterfaceSizeClass?
    var maxBoardLength: Int
    
    var body: some View {
        PlayView(gameRecord: gameRecord)
            .toolbar {
                TopToolbarView(gameRecord: gameRecord, maxBoardLength: maxBoardLength)
            }
    }
}

struct GobanView: View {
    @Binding var isEditorPresented: Bool
    @Environment(NavigationContext.self) var navigationContext
    @Environment(\.horizontalSizeClass) var horizontalSizeClass: UserInterfaceSizeClass?
    @State var toolbarUuid = UUID()
    var maxBoardLength: Int
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        Group {
            if let gameRecord = navigationContext.selectedGameRecord {
                if (gameRecord.concreteConfig.boardWidth <= maxBoardLength) &&
                    (gameRecord.concreteConfig.boardHeight <= maxBoardLength) {
                    GobanItems(gameRecord: gameRecord, maxBoardLength: maxBoardLength)
                        .toolbar {
                            ToolbarItem(placement: .principal) {
                                HStack {
#if os(visionOS)
                                    Button(action: toggleFullScreen) {
                                        Image(
                                            systemName: (columnVisibility == .all)
                                            ? "arrow.up.left.and.arrow.down.right"
                                            : "arrow.down.right.and.arrow.up.left"
                                        )
                                    }
                                    .scaledToFit()
#endif

                                    Text(gameRecord.name)
                                        .bold()
                                        .onTapGesture {
                                            isEditorPresented = true
                                        }
                                        .id(toolbarUuid)
                                }
                            }
                        }
                } else {
                    ContentUnavailableView("Too large board size \(gameRecord.concreteConfig.boardWidth)x\(gameRecord.concreteConfig.boardHeight) to run with this neural network.\nPlease select other neural networks.", systemImage: "rectangle.portrait.and.arrow.forward")
                        .toolbar {
                            ToolbarItem {
                                PlusMenuView(gameRecord: nil, maxBoardLength: maxBoardLength)
                                    .id(toolbarUuid)
                            }
                        }
                }
            } else {
                ContentUnavailableView("Select a game", systemImage: "sidebar.left")
                    .toolbar {
                        ToolbarItem {
                            PlusMenuView(gameRecord: nil, maxBoardLength: maxBoardLength)
                                .id(toolbarUuid)
                        }
                    }
            }
        }
        .onChange(of: horizontalSizeClass) { _, _ in
            toolbarUuid = UUID()
        }
    }

    func toggleFullScreen() {
        if columnVisibility == .detailOnly {
            columnVisibility = .all
        } else {
            columnVisibility = .detailOnly
        }
    }
}
