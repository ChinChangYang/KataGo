//
//  GobanView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/2.
//

import SwiftUI
import KataGoUICore
import SwiftData
#if os(iOS)
import UIKit
#endif

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
    @Environment(GobanState.self) var gobanState
    @Environment(\.horizontalSizeClass) var horizontalSizeClass: UserInterfaceSizeClass?
    @State var toolbarUuid = UUID()
    var maxBoardLength: Int
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        Group {
            if let gameRecord = navigationContext.selectedGameRecord {
                // A board bigger than the engine's Max Board Size used to
                // REPLACE the board with a "Too large board size" placeholder.
                // It no longer does: the board is record-owned and draws
                // regardless of what any engine can hold, so the size mismatch
                // is reported the same way every other engine state is — as the
                // inline *Held* line over a board the user can still read,
                // scrub and navigate. `AppEngineController.applyHeldStatus`
                // raises it; the feed refuses the record on its own
                // (`GobanState.boardFitsEngine`), so nothing here has to gate.
                GobanItems(gameRecord: gameRecord, maxBoardLength: maxBoardLength)
                    .toolbar {
                        // iPad only: iPhone's compact top-left belongs to the
                        // back button.
                        if UIDevice.current.userInterfaceIdiom == .pad {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(action: toggleBoardFullScreen) {
                                    Label(
                                        gobanState.isBoardFullScreen ? "Exit Full Screen" : "Full Screen",
                                        systemImage: gobanState.isBoardFullScreen
                                            ? "arrow.down.right.and.arrow.up.left"
                                            : "arrow.up.left.and.arrow.down.right"
                                    )
                                    .labelStyle(.iconOnly)
                                }
                                .contentTransition(.symbolEffect(.replace))
                                .id(toolbarUuid)
                            }
                        }

                        ToolbarItem(placement: .principal) {
                            HStack {
                                // A real Button (not Text + tap gesture) so
                                // Voice Control / VoiceOver can invoke the
                                // rename editor; .plain keeps the title look.
                                Button {
                                    isEditorPresented = true
                                } label: {
                                    Text(gameRecord.name)
                                        .bold()
                                }
                                .buttonStyle(.plain)
                                .accessibilityInputLabels([gameRecord.name, "Rename Game", "Game Name"])
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

    /// iPad full-screen board mode: hides the chart/comments pane (PlayView
    /// gates it on `gobanState.isInfoPaneVisible`) and collapses the sidebar,
    /// Notes-style.
    func toggleBoardFullScreen() {
        withAnimation {
            gobanState.isBoardFullScreen.toggle()
            if gobanState.isBoardFullScreen {
                columnVisibility = .detailOnly
            }
        }
    }
}
