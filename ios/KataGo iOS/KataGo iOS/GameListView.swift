//
//  GameListView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/1.
//

import SwiftUI
import SwiftData

struct GameLinksView: View {
    @Binding var selectedGameRecord: GameRecord?
    @Query var gameRecords: [GameRecord]
    @Environment(\.modelContext) private var modelContext

    init(selectedGameRecord: Binding<GameRecord?>,
         searchText: String) {
        _selectedGameRecord = selectedGameRecord

        let predicate = #Predicate<GameRecord> {
            searchText.isEmpty || $0.name.contains(searchText)
        }

        _gameRecords = Query(filter: predicate,
                             sort: \GameRecord.lastModificationDate,
                             order: .reverse)
    }

    var body: some View {
        ForEach(gameRecords) { gameRecord in
            NavigationLink(value: gameRecord) {
                GameLinkView(gameRecord: gameRecord)
            }
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
    }
}

struct GameListView: View {
    @Binding var isEditorPresented: Bool
    @Binding var selectedGameRecord: GameRecord?
    @State var searchText = ""
    @Binding var importing: Bool
    @Binding var isGameListViewAppeared: Bool
    @Environment(ThumbnailModel.self) var thumbnailModel

    var body: some View {
        List(selection: $selectedGameRecord) {
            GameLinksView(selectedGameRecord: $selectedGameRecord,
                          searchText: searchText)
        }
        .navigationTitle("Games")
        .sheet(isPresented: $isEditorPresented) {
            NameEditorView(gameRecord: selectedGameRecord)
        }
        .searchable(text: $searchText)
        .onAppear {
            isGameListViewAppeared = true
            thumbnailModel.isGameListViewAppeared = true
        }
        .onDisappear {
            isGameListViewAppeared = false
            thumbnailModel.isGameListViewAppeared = false
        }
        .onChange(of: selectedGameRecord) { _, newValue in
            if let name = newValue?.name {
                searchText = name
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
