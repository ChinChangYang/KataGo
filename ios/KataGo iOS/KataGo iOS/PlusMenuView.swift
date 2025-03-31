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

            if let gameRecordToDelete = gameRecord {
                Button(role: .destructive) {
                    navigationContext.selectedGameRecord = nil
                    modelContext.safelyDelete(gameRecord: gameRecordToDelete)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            Button {
                withAnimation {
                    thumbnailModel.isLarge.toggle()
                    thumbnailModel.save()
                }
            } label: {
                return Label(thumbnailModel.title, systemImage: "photo")
            }
        } label: {
            Image(systemName: "plus.square")
        }
    }
}
