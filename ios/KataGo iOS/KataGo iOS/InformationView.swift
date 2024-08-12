//
//  AddGameView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/7.
//

import SwiftUI
import KataGoInterface

struct InformationView: View {
    var gameRecord: GameRecord
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanTab.self) var gobanTab
    @Environment(GobanState.self) var gobanState
    @State var name: String = ""
    @State var sgf: String = ""

    var body: some View {
        VStack {
            Form {
                Section("Name") {
                    TextField("Enter your game name", text: $name)
                        .onAppear {
                            name = gameRecord.name
                        }
                        .onChange(of: name) { _, newValue in
                            gameRecord.name = name
                        }
                }
                
                Section("SGF") {
                    TextField("Paste your SGF text", text: $sgf, axis: .vertical)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .onAppear {
                            sgf = gameRecord.sgf
                        }
                        .onDisappear {
                            if sgf != gameRecord.sgf {
                                let config = gameRecord.config
                                gameRecord.sgf = sgf
                                KataGoHelper.loadSgf(sgf)
                                KataGoHelper.sendCommand(config.getKataPlayoutDoublingAdvantageCommand())
                                KataGoHelper.sendCommand(config.getKataAnalysisWideRootNoiseCommand())
                                KataGoHelper.sendCommand("kata-set-param humanSLProfile \(config.humanSLProfile)")
                                KataGoHelper.sendCommand("kata-set-param humanSLRootExploreProbWeightful \(config.humanSLRootExploreProbWeightful)")
                                KataGoHelper.sendCommand("showboard")
                                gobanState.maybeRequestAnalysis(config: config)
                            }
                        }
                }
            }
        }
    }
}
