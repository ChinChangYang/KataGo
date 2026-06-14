//
//  PlusMenuView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/27.
//

import SwiftUI

struct PlusMenuView: View {
    var gameRecord: GameRecord?
    var maxBoardLength: Int
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanState.self) var gobanState
    @Environment(ThumbnailModel.self) var thumbnailModel
    @Environment(TopUIState.self) var topUIState
    @State private var showingConfig = false
    @State private var showingDeveloper = false
    @State private var confirmingClone = false

    var body: some View {
        Menu {
            Button {
                withAnimation {
                    let newGameRecord = GameRecord.createGameRecord(maxBoardLength: maxBoardLength)
                    modelContext.insert(newGameRecord)
                    navigationContext.selectedGameRecord = newGameRecord
                }
            } label: {
                Label("New Game", systemImage: "doc")
            }

            if let gameRecord {
                Button {
                    confirmingClone = true
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

            if gameRecord != nil {
#if !os(visionOS)
                Divider()
#endif

                Button {
                    showingConfig = true
                } label: {
                    Label("Configurations", systemImage: "gearshape")
                }

                Button {
                    showingDeveloper = true
                } label: {
                    Label("Developer Mode", systemImage: "doc.plaintext")
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .sheet(isPresented: $showingConfig) {
            if let gameRecord {
                NavigationStack {
                    ConfigView(gameRecord: gameRecord, maxBoardLength: maxBoardLength)
                }
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 600)
                #endif
            }
        }
        .sheet(isPresented: $showingDeveloper) {
            if let gameRecord {
                NavigationStack {
                    CommandView(config: gameRecord.concreteConfig)
                }
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 400)
                #endif
            }
        }
        .confirmationDialog(
            "Clone this game",
            isPresented: $confirmingClone,
            titleVisibility: .visible
        ) {
            if let gameRecord {
                Button("Clone Whole Game") {
                    withAnimation {
                        let newGameRecord = gameRecord.clone()
                        modelContext.insert(newGameRecord)
                        navigationContext.selectedGameRecord = newGameRecord
                    }
                }

                Button("Clone Current Position") {
                    withAnimation {
                        let newGameRecord = gobanState.cloneCurrentPosition(gameRecord: gameRecord)
                        modelContext.insert(newGameRecord)
                        navigationContext.selectedGameRecord = newGameRecord
                    }
                }
            }

            Button("Cancel", role: .cancel) { }
        }
    }
}

#Preview {
    PlusMenuView(
        gameRecord: GameRecord(config: Config()),
        maxBoardLength: 19
    )
    .environment(NavigationContext())
    .environment(GobanState())
    .environment(ThumbnailModel())
    .environment(TopUIState())
}
