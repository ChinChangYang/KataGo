//
//  AddGameView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/7.
//

import SwiftUI

struct AddGameView: View {
    var gameRecord: GameRecord?
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanTab.self) var gobanTab
    @State var sgf: String = ""

    var body: some View {
        Form {
            Section("SGF") {
                HStack {
                    TextField("Paste your SGF text", text: $sgf, axis: .vertical)
                        .disableAutocorrection(true)
                        .onAppear {
                            sgf = gameRecord?.sgf ?? ""
                        }

                    Button("Create") {
                        withAnimation {
                            let newGameRecord = createNewGameRecord(sgf: sgf,
                                                                    gameRecord: gameRecord)

                            modelContext.insert(newGameRecord)
                            navigationContext.selectedGameRecord = newGameRecord
                            gobanTab.isCommandPresented = false
                            gobanTab.isConfigPresented = false
                            gobanTab.isAddPresented.toggle()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    func createNewGameRecord(sgf: String, gameRecord: GameRecord?) -> GameRecord {
        if let gameRecord {
            return GameRecord(sgf: sgf,
                              config: Config(config: gameRecord.config),
                              name: gameRecord.name + " (copy)")
        } else {
            return GameRecord(sgf: sgf,
                              config: Config(),
                              name: "New Game")
        }
    }
}
