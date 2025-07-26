//
//  TopToolbarView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/12.
//

import SwiftUI
import KataGoInterface

struct TopToolbarView: View {
    var gameRecord: GameRecord
    @Binding var importing: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanTab.self) var gobanTab
    @Environment(BranchState.self) var branchState
    @Environment(GobanState.self) var gobanState
    @Environment(Turn.self) var player

    var body: some View {
        HStack {
            if !gobanTab.isConfigPresented {
                Button {
                    withAnimation {
                        gobanTab.isCommandPresented.toggle()
                        gobanTab.isConfigPresented = false
                    }
                } label: {
                    if gobanTab.isCommandPresented {
                        Image(systemName: "doc.plaintext.fill")
                    } else {
                        Image(systemName: "doc.plaintext")
                    }
                }
            }

            if !branchState.isActive {
                if gobanState.isEditing && !gobanTab.isCommandPresented {
                    Button {
                        withAnimation {
                            gobanTab.isCommandPresented = false
                            gobanTab.isConfigPresented.toggle()
                        }
                    } label: {
                        if gobanTab.isConfigPresented {
                            Image(systemName: "gearshape.fill")
                        } else {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                
                if !gobanTab.isCommandPresented && !gobanTab.isConfigPresented && !gobanState.isEditing {
                    PlusMenuView(gameRecord: gameRecord, importing: $importing)
                }
                
                if !gobanTab.isCommandPresented && !gobanTab.isConfigPresented {
                    Button {
                        if !gobanState.isAutoPlaying {
                            gobanState.isEditing.toggle()
                        }
                    } label: {
                        if gobanState.isEditing {
                            Image(systemName: "lock.open")
                                .foregroundStyle(gobanState.isAutoPlaying ? .secondary : .primary)
                        } else {
                            Image(systemName: "lock")
                                .foregroundStyle(gobanState.isAutoPlaying ? .secondary : .primary)
                        }
                    }
                }
            } else if let config = gameRecord.config {
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
