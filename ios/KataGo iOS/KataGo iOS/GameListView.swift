//
//  GameListView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/1.
//

import SwiftUI
import SwiftData
import KataGoUICore

struct GameLinksView: View {
    @Binding var selectedGameRecord: GameRecord?
    @Binding var searchText: String
    @Query var gameRecords: [GameRecord]
    @Environment(\.modelContext) private var modelContext

    private var isSearchActive: Bool { !searchText.isEmpty }

    init(selectedGameRecord: Binding<GameRecord?>,
         searchText: Binding<String>) {
        _selectedGameRecord = selectedGameRecord
        _searchText = searchText

        let searchTextValue = searchText.wrappedValue
        let predicate = #Predicate<GameRecord> {
            searchTextValue.isEmpty || $0.name.localizedStandardContains(searchTextValue)
        }

        let descriptor = FetchDescriptor<GameRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.lastModificationDate, order: .reverse)]
        )

        _gameRecords = Query(descriptor)
    }

    var body: some View {
        ForEach(gameRecords) { gameRecord in
            NavigationLink(value: gameRecord) {
                GameLinkView(gameRecord: gameRecord)
            }
        }
        .onDelete { indexSet in
            for index in indexSet {
                let record = gameRecords[index]
                if selectedGameRecord?.persistentModelID == record.persistentModelID {
                    selectedGameRecord = nil
                }
                modelContext.safelyDelete(gameRecord: record)
            }
        }

        if isSearchActive {
            Button("Clear Search") { searchText = "" }
                .tint(.primary)
        }
    }
}

struct GameListView: View {
    @Binding var isEditorPresented: Bool
    @Binding var selectedGameRecord: GameRecord?
    @State var searchText = ""
    @Binding var isGameListViewAppeared: Bool
    @Environment(ThumbnailModel.self) var thumbnailModel

    var body: some View {
        List(selection: $selectedGameRecord) {
            GameLinksView(selectedGameRecord: $selectedGameRecord,
                          searchText: $searchText)
        }
        .navigationTitle("Games")
        .sheet(isPresented: $isEditorPresented) {
            NameEditorView(gameRecord: selectedGameRecord)
        }
        .searchable(text: $searchText)
        .onAppear {
            isGameListViewAppeared = true
            thumbnailModel.isGameListViewAppeared = true
            if let selectedGameRecord {
                // reduces unnecessary updates and filters out unrelated game records when a game is edited.
                searchText = selectedGameRecord.name
            }
        }
        .onDisappear {
            isGameListViewAppeared = false
            thumbnailModel.isGameListViewAppeared = false
        }
        .onChange(of: selectedGameRecord?.name) {
            if let name = selectedGameRecord?.name {
                // reduces unnecessary updates and filters out unrelated game records when a game is edited.
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

#Preview {
    @Previewable @State var isEditorPresented = false
    @Previewable @State var selectedGameRecord: GameRecord? = nil
    @Previewable @State var isGameListViewAppeared = false

    let container: ModelContainer = {
        let schema = Schema([GameRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext
        let record1 = GameRecord.createGameRecord(name: "Game 1")
        let record2 = GameRecord.createGameRecord(name: "Game 2")
        context.insert(record1)
        context.insert(record2)
        return container
    }()

    NavigationStack {
        GameListView(
            isEditorPresented: $isEditorPresented,
            selectedGameRecord: $selectedGameRecord,
            isGameListViewAppeared: $isGameListViewAppeared
        )
    }
    .environment(ThumbnailModel())
    .modelContainer(container)
}
