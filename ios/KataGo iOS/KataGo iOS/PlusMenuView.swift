//
//  PlusMenuView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/27.
//

import SwiftUI

struct PlusMenuView: View {
    var gameRecord: GameRecord?
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanState.self) var gobanState
    @Environment(ThumbnailModel.self) var thumbnailModel
    @Environment(TopUIState.self) var topUIState

    var body: some View {
        Menu {
            Button {
                withAnimation {
                    let newGameRecord = GameRecord.createGameRecord()
                    modelContext.insert(newGameRecord)
                    navigationContext.selectedGameRecord = newGameRecord
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
                    }
                } label: {
                    Label("Clone", systemImage: "doc.on.doc")
                }
            }

            Button {
                withAnimation {
                    topUIState.importing = true
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }

            if let gameRecord {
                ShareLink(
                    item: TransferableSgf(
                        name: gameRecord.name,
                        content: gameRecord.sgf
                    ),
                    preview: SharePreview(
                        gameRecord.name,
                        image: gameRecord.image ?? Image(.loadingIcon)
                    )
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    topUIState.confirmingDeletion = true
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

            if let gameRecord {
#if !os(visionOS)
                Divider()
#endif

                NavigationStack {
                    NavigationLink(destination: CommandView(config: gameRecord.concreteConfig)) {
                        Label("Developer Mode", systemImage: "doc.plaintext")
                    }
                    .buttonStyle(.automatic)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

#Preview {
    PlusMenuView(
        gameRecord: GameRecord(config: Config())
    )
    .environment(NavigationContext())
    .environment(GobanState())
    .environment(ThumbnailModel())
    .environment(TopUIState())
}
