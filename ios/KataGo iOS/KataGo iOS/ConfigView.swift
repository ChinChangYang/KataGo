//
//  ConfigView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/19.
//

import SwiftUI

struct EditButtonBar: View {
    @Environment(\.editMode) private var editMode
    @EnvironmentObject var config: Config

    var body: some View {
        HStack {
            Spacer()
            EditButton().onChange(of: editMode?.wrappedValue) {
                if (editMode?.wrappedValue == .inactive) && (config.isBoardSizeChanged) {
                    KataGoHelper.sendCommand(config.getKataBoardSizeCommand())
                    config.isBoardSizeChanged = false
                }
            }
        }
    }
}

struct ConfigIntItem: View {
    @Environment(\.editMode) private var editMode
    let title: String
    @Binding var value: Int
    let minValue: Int
    let maxValue: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if editMode?.wrappedValue.isEditing == true {
                Stepper(value: $value, in: minValue...maxValue) {
                    Text("\(value)")
                }
            } else {
                Text("\(value)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConfigFloatItem: View {
    @Environment(\.editMode) private var editMode
    let title: String
    @Binding var value: Float
    let step: Float
    let minValue: Float
    let maxValue: Float

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if editMode?.wrappedValue.isEditing == true {
                Stepper(value: $value, in: minValue...maxValue, step: step) {
                    Text("\(value.formatted(.number))")
                }
            } else {
                Text("\(value.formatted(.number))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConfigTextItem: View {
    @Environment(\.editMode) private var editMode
    let title: String
    let texts: [String]
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if editMode?.wrappedValue.isEditing == true {
                Stepper {
                    Text(texts[value])
                } onIncrement: {
                    value = ((value + 1) < texts.count) ? (value + 1) : 0
                } onDecrement: {
                    value = ((value - 1) >= 0) ? (value - 1) : (texts.count - 1)
                }
            } else {
                Text(texts[value])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConfigItems: View {
    @EnvironmentObject var config: Config
    @State var boardWidth: Int = Config.defaultBoardWidth
    @State var boardHeight: Int = Config.defaultBoardHeight
    @State var rule: Int = Config.defaultRule
    @State var komi: Float = Config.defaultKomi
    @State var playoutDoublingAdvantage: Float = Config.defaultPlayoutDoublingAdvantage
    @State var analysisWideRootNoise: Float = Config.defaultAnalysisWideRootNoise
    @State var maxMessageCharacters: Int = Config.defaultMaxMessageCharacters
    @State var maxAnalysisMoves: Int = Config.defaultMaxAnalysisMoves
    @State var analysisInformation: Int = Config.defaultAnalysisInformation
    @State var analysisInterval: Int = Config.defaultAnalysisInterval
    @State var maxMessageLines: Int = Config.defaultMaxMessageLines
    @State var hiddenAnalysisVisitRatio: Float = Config.defaultHiddenAnalysisVisitRatio

    var body: some View {
        VStack {
            ConfigIntItem(title: "Board width:", value: $boardWidth, minValue: 2, maxValue: 29)
                .onChange(of: boardWidth) { _, newValue in
                    config.boardWidth = newValue
                    config.isBoardSizeChanged = true
                }
                .padding(.bottom)

            ConfigIntItem(title: "Board height:", value: $boardHeight, minValue: 2, maxValue: 29)
                .onChange(of: boardHeight) { _, newValue in
                    config.boardHeight = newValue
                    config.isBoardSizeChanged = true
                }
                .padding(.bottom)

            ConfigTextItem(title: "Rule:", texts: Config.rules, value: $rule)
                .onChange(of: rule) { _, newValue in
                    config.rule = newValue
                    KataGoHelper.sendCommand(config.getKataRuleCommand())
            }
            .padding(.bottom)

            ConfigFloatItem(title: "Komi:", value: $komi, step: 0.5, minValue: -1_000, maxValue: 1_000)
                .onChange(of: komi) { _, newValue in
                    config.komi = newValue
                    KataGoHelper.sendCommand(config.getKataKomiCommand())
            }
            .padding(.bottom)

            ConfigFloatItem(title: "Playout doubling advantage:", value: $playoutDoublingAdvantage, step: 0.125, minValue: -3.0, maxValue: 3.0)
                .onChange(of: playoutDoublingAdvantage) { _, newValue in
                    config.playoutDoublingAdvantage = newValue
                    KataGoHelper.sendCommand(config.getKataPlayoutDoublingAdvantageCommand())
            }
            .padding(.bottom)

            ConfigFloatItem(title: "Analysis wide root noise:", value: $analysisWideRootNoise, step: 0.0078125, minValue: 0.0, maxValue: 1.0)
                .onChange(of: analysisWideRootNoise) { _, newValue in
                    config.analysisWideRootNoise = newValue
                    KataGoHelper.sendCommand(config.getKataAnalysisWideRootNoiseCommand())
            }
            .padding(.bottom)

            ConfigIntItem(title: "Max analysis moves:", value: $maxAnalysisMoves, minValue: 1, maxValue: 1_000)
                .onChange(of: maxAnalysisMoves) { _, newValue in
                    config.maxAnalysisMoves = newValue
                }
                .padding(.bottom)

            ConfigFloatItem(title: "Hidden analysis visit ratio:", value: $hiddenAnalysisVisitRatio, step: 0.0078125, minValue: 0.0, maxValue: 1.0)
                .onChange(of: hiddenAnalysisVisitRatio) { _, newValue in
                    config.hiddenAnalysisVisitRatio = newValue
            }
            .padding(.bottom)

            ConfigTextItem(title: "Analysis information:", texts: Config.analysisInformations, value: $analysisInformation)
                .onChange(of: analysisInformation) { _, newValue in
                    config.analysisInformation = newValue
            }
            .padding(.bottom)

            ConfigIntItem(title: "Analysis interval (centiseconds):", value: $analysisInterval, minValue: 5, maxValue: 1_000)
                .onChange(of: analysisInterval) { _, newValue in
                    config.analysisInterval = newValue
                }
        }
        .onAppear {
            boardWidth = config.boardWidth
            boardHeight = config.boardHeight
            rule = config.rule
            komi = config.komi
            playoutDoublingAdvantage = config.playoutDoublingAdvantage
            analysisWideRootNoise = config.analysisWideRootNoise
            maxAnalysisMoves = config.maxAnalysisMoves
            analysisInformation = config.analysisInformation
            analysisInterval = config.analysisInterval
            hiddenAnalysisVisitRatio = config.hiddenAnalysisVisitRatio
        }
    }
}

struct ConfigView: View {
    var body: some View {
        VStack {
            EditButtonBar()
                .padding()
            ConfigItems()
                .padding()
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .onAppear() {
            KataGoHelper.sendCommand("stop")
        }
    }
}

struct ConfigView_Previews: PreviewProvider {
    static let isEditing = EditMode.inactive
    static let config = Config()
    static var previews: some View {
        ConfigView()
            .environmentObject(config)
    }
}
