//
//  GameListView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/1.
//

import SwiftUI
import SwiftData

struct GameListView: View {
    @Binding var isInitialized: Bool
    @Binding var isEditorPresented: Bool
    @Binding var selectedGameRecord: GameRecord?
    @Query(sort: \GameRecord.lastModificationDate, order: .reverse) var gameRecords: [GameRecord]
    @Environment(\.modelContext) private var modelContext
    @State var searchText = ""
    @Binding var importing: Bool

    var filteredGameRecords: [GameRecord] {
        if searchText == "" {
            return gameRecords
        } else {
            return gameRecords.filter { gameRecord in
                gameRecord.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var body: some View {
        List(selection: $selectedGameRecord) {
            if isInitialized {
                ForEach(filteredGameRecords) { gameRecord in
                    NavigationLink(gameRecord.name, value: gameRecord)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let gameRecordToDelete = gameRecords[index]
                        if selectedGameRecord?.persistentModelID == gameRecordToDelete.persistentModelID {
                            selectedGameRecord = nil
                        }

                        modelContext.safelyDelete(gameRecord: gameRecordToDelete)
                    }
                }
            } else {
                Text("Initializing...")
            }
        }
        .navigationTitle("Games")
        .sheet(isPresented: $isEditorPresented) {
            NameEditorView(gameRecord: selectedGameRecord)
        }
        .searchable(text: $searchText)
        .toolbar {
            if UIDevice.current.userInterfaceIdiom == .phone {
                ToolbarItem {
                    PlusMenuView(gameRecord: selectedGameRecord, importing: $importing)
                }
            }
        }
    }
}

extension ModelContext {
    @MainActor
    func safelyDelete(gameRecord: GameRecord) {
        Task {
            // Yield control to prevent potential race conditions caused by
            // simultaneous access to the game record.
            await Task.yield()

            // Perform the deletion of the game record on the main actor to
            // ensure thread safety.
            await MainActor.run {
                delete(gameRecord)
            }
        }
    }
}
