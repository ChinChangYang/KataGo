//
//  GameListView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/1.
//

import SwiftUI
import SwiftData
import KataGoUICore
import WidgetKit

struct GameLinksView: View {
    @Binding var selectedGameRecord: GameRecord?
    @Binding var searchText: String
    @Query var gameRecords: [GameRecord]
    @Environment(\.modelContext) private var modelContext
    @Environment(TopUIState.self) private var topUIState

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
            if topUIState.isSelecting {
                selectableRow(for: gameRecord)
            } else {
                NavigationLink(value: gameRecord) {
                    GameLinkView(gameRecord: gameRecord)
                }
            }
        }
        .onDelete(perform: deleteAction)

        if isSearchActive {
            Button("Clear Search") { searchText = "" }
                .tint(.primary)
        }
    }

    @ViewBuilder
    private func selectableRow(for gameRecord: GameRecord) -> some View {
        let isSelected = topUIState.selectedGameIDs.contains(gameRecord.persistentModelID)
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .imageScale(.large)
            GameLinkView(gameRecord: gameRecord)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
                topUIState.toggle(gameRecord.persistentModelID)
            }
        }
    }

    private var deleteAction: ((IndexSet) -> Void)? {
        if topUIState.isSelecting {
            return nil
        }
        return deleteRecords
    }

    private func deleteRecords(at indexSet: IndexSet) {
        for index in indexSet {
            let record = gameRecords[index]
            if selectedGameRecord?.persistentModelID == record.persistentModelID {
                selectedGameRecord = nil
            }
            modelContext.safelyDelete(gameRecord: record)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

struct GameListView: View {
    @Binding var isEditorPresented: Bool
    @Binding var selectedGameRecord: GameRecord?
    @State var searchText = ""
    @Binding var isGameListViewAppeared: Bool
    @Environment(ThumbnailModel.self) var thumbnailModel
    @Environment(TopUIState.self) private var topUIState

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
        .toolbar {
            if topUIState.isSelecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Button(role: .destructive) {
                        topUIState.confirmingBulkDeletion = true
                    } label: {
                        Label("Delete (\(topUIState.selectionCount))", systemImage: "trash")
                    }
                    .tint(.red)
                    .disabled(topUIState.selectionCount == 0)
                }
            }
        }
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
            // Don't let select mode (and its bottom bar) linger if the list goes away.
            topUIState.exitSelection()
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

    /// Delete every `GameRecord` whose persistent ID is in `gameIDs`, returning
    /// the IDs actually deleted. Fetch-and-filter (rather than `model(for:)`) so
    /// stale/unknown IDs are simply skipped. Synchronous: it runs inside the
    /// bulk-delete confirmation action (already on the main actor) — unlike the
    /// swipe path, there's no in-flight list-removal animation to race with, so
    /// the deferred `safelyDelete` hop isn't needed.
    func bulkDelete(gameIDs: Set<PersistentIdentifier>) -> [PersistentIdentifier] {
        guard !gameIDs.isEmpty else { return [] }
        let all = (try? fetch(FetchDescriptor<GameRecord>())) ?? []
        var deleted: [PersistentIdentifier] = []
        for record in all where gameIDs.contains(record.persistentModelID) {
            delete(record)
            deleted.append(record.persistentModelID)
        }
        return deleted
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
