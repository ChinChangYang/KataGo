//
//  PlusMenuView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/27.
//

import SwiftUI

struct PlusMenuView: View {
    var gameRecord: GameRecord?
    @Binding var importing: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanTab.self) var gobanTab
    @Environment(GobanState.self) var gobanState
    @Environment(ThumbnailModel.self) var thumbnailModel

    var body: some View {
        Menu {
            Button {
                withAnimation {
                    let newGameRecord = GameRecord.createGameRecord()
                    modelContext.insert(newGameRecord)
                    navigationContext.selectedGameRecord = newGameRecord
                    gobanTab.isCommandPresented = false
                    gobanTab.isConfigPresented = false
                }
            } label: {
                Label("New Game", systemImage: "doc")
            }

            if let gameRecord {
                Button {
                    withAnimation {
                        let newGameRecord = gameRecord.clone()
                        modelContext.insert(newGameRecord)
                        navigationContext.selectedGameRecord = newGameRecord
                        gobanTab.isCommandPresented = false
                        gobanTab.isConfigPresented = false
                    }
                } label: {
                    Label("Clone", systemImage: "doc.on.doc")
                }
            }

            Button {
                withAnimation {
                    importing = true
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }

            if let gameRecord {
                ShareLink(item:
                            TransferableSgf(
                                name: gameRecord.name,
                                content: gameRecord.sgf),
                          preview: SharePreview(
                            gameRecord.name,
                            image: gameRecord.image ?? Image(.loadingIcon))) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    navigationContext.selectedGameRecord = nil
                    modelContext.safelyDelete(gameRecord: gameRecord)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            if thumbnailModel.isGameListViewAppeared {
#if !os(visionOS)
                Divider()
#endif
                Button {
                    withAnimation {
                        thumbnailModel.isLarge.toggle()
                        thumbnailModel.save()
                    }
                } label: {
                    Label(thumbnailModel.title, systemImage: "photo")
                }
            }

            Button {
                withAnimation {
                    gobanTab.isCommandPresented = true
                }
            } label: {
                Label("Developer Mode", systemImage: "doc.plaintext")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}
