//
//  ConfigView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/19.
//

import SwiftUI
import KataGoInterface

struct ConfigIntItem: View {
    let title: String
    @Binding var value: Int
    let minValue: Int
    let maxValue: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Stepper(value: $value, in: minValue...maxValue) {
                Text("\(value)")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConfigFloatItem: View {
    let title: String
    @Binding var value: Float
    let step: Float
    let minValue: Float
    let maxValue: Float

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Stepper(value: $value, in: minValue...maxValue, step: step) {
                Text("\(value.formatted(.number))")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConfigTextItem: View {
    let title: String
    let texts: [String]
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Stepper {
                Text(texts[value])
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } onIncrement: {
                value = ((value + 1) < texts.count) ? (value + 1) : 0
            } onDecrement: {
                value = ((value - 1) >= 0) ? (value - 1) : (texts.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConfigBoolItem: View {
    let title: String
    @Binding var value: Bool

    var label: String {
        value ? "Yes" : "No"
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Stepper {
                Text(label)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } onIncrement: {
                value.toggle()
            } onDecrement: {
                value.toggle()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HumanStylePicker: View {
    @Binding var humanSLProfile: String

    var profiles: [String] {
        let dans = (1...9).reversed().map() { dan in
            return "\(dan)d"
        }

        let kyus = (1...20).map() { kyu in
            return "\(kyu)k"
        }

        let dansKyus = dans + kyus

        let ranks = dansKyus.map() { rank in
            return "rank_\(rank)"
        }

        let preAlphaZeros = dansKyus.map() { rank in
            return "preaz_\(rank)"
        }

        let proYears = (1800...2023).map() { year in
            return "proyear_\(year)"
        }

        return ranks + preAlphaZeros + proYears
    }

    var body: some View {
        Picker("Profile", selection: $humanSLProfile) {
            ForEach(profiles, id: \.self) { profile in
                Text(profile).tag(profile)
            }
        }
    }
}

struct ConfigItems: View {
    var config: Config
    @State var boardWidth: Int = Config.defaultBoardWidth
    @State var boardHeight: Int = Config.defaultBoardHeight
    @State var rule: Int = Config.defaultRule
    @State var komi: Float = Config.defaultKomi
    @State var playoutDoublingAdvantage: Float = Config.defaultPlayoutDoublingAdvantage
    @State var analysisWideRootNoise: Float = Config.defaultAnalysisWideRootNoise
    @State var maxAnalysisMoves: Int = Config.defaultMaxAnalysisMoves
    @State var analysisInformation: Int = Config.defaultAnalysisInformation
    @State var hiddenAnalysisVisitRatio: Float = Config.defaultHiddenAnalysisVisitRatio
    @State var stoneStyle = Config.defaultStoneStyle
    @State var showCoordinate = Config.defaultShowCoordinate
    @State var humanSLRootExploreProbWeightful = Config.defaultHumanSLRootExploreProbWeightful
    @State var humanSLProfile = Config.defaultHumanSLProfile
    @State var analysisForWhom: Int = Config.defaultAnalysisForWhom
    @Binding var isBoardSizeChanged: Bool

    var body: some View {
        Form {
            Section("Rule") {
                ConfigIntItem(title: "Board width:", value: $boardWidth, minValue: 2, maxValue: 29)
                    .onChange(of: boardWidth) { _, newValue in
                        config.boardWidth = newValue
                        isBoardSizeChanged = true
                    }

                ConfigIntItem(title: "Board height:", value: $boardHeight, minValue: 2, maxValue: 29)
                    .onChange(of: boardHeight) { _, newValue in
                        config.boardHeight = newValue
                        isBoardSizeChanged = true
                    }

                ConfigTextItem(title: "Rule:", texts: Config.rules, value: $rule)
                    .onChange(of: rule) { _, newValue in
                        config.rule = newValue
                        KataGoHelper.sendCommand(config.getKataRuleCommand())
                    }

                ConfigFloatItem(title: "Komi:", value: $komi, step: 0.5, minValue: -1_000, maxValue: 1_000)
                    .onChange(of: komi) { _, newValue in
                        config.komi = newValue
                        KataGoHelper.sendCommand(config.getKataKomiCommand())
                    }
            }

            Section("Analysis") {
                ConfigTextItem(title: "Analysis information:", texts: Config.analysisInformations, value: $analysisInformation)
                    .onChange(of: analysisInformation) { _, newValue in
                        config.analysisInformation = newValue
                    }

                ConfigTextItem(title: "Analysis for:", texts: Config.analysisForWhoms, value: $analysisForWhom)
                    .onChange(of: analysisForWhom) { _, newValue in
                        config.analysisForWhom = newValue
                    }

                ConfigFloatItem(title: "Playout doubling advantage:", value: $playoutDoublingAdvantage, step: 0.125, minValue: -3.0, maxValue: 3.0)
                    .onChange(of: playoutDoublingAdvantage) { _, newValue in
                        config.playoutDoublingAdvantage = newValue
                        KataGoHelper.sendCommand(config.getKataPlayoutDoublingAdvantageCommand())
                    }

                ConfigFloatItem(title: "Hidden analysis visit ratio:", value: $hiddenAnalysisVisitRatio, step: 0.0078125, minValue: 0.0, maxValue: 1.0)
                    .onChange(of: hiddenAnalysisVisitRatio) { _, newValue in
                        config.hiddenAnalysisVisitRatio = newValue
                    }

                ConfigFloatItem(title: "Analysis wide root noise:", value: $analysisWideRootNoise, step: 0.0078125, minValue: 0.0, maxValue: 1.0)
                    .onChange(of: analysisWideRootNoise) { _, newValue in
                        config.analysisWideRootNoise = newValue
                        KataGoHelper.sendCommand(config.getKataAnalysisWideRootNoiseCommand())
                    }

                ConfigIntItem(title: "Max analysis moves:", value: $maxAnalysisMoves, minValue: 1, maxValue: 1_000)
                    .onChange(of: maxAnalysisMoves) { _, newValue in
                        config.maxAnalysisMoves = newValue
                    }
            }

            Section("View") {
                ConfigTextItem(title: "Stone style:", texts: Config.stoneStyles, value: $stoneStyle)
                    .onChange(of: stoneStyle) { _, newValue in
                        config.stoneStyle = stoneStyle
                    }

                ConfigBoolItem(title: "Show coordinate", value: $showCoordinate)
                    .onChange(of: showCoordinate) { _, newValue in
                        config.showCoordinate = showCoordinate
                    }
            }

            Section("Human Style") {
                HumanStylePicker(humanSLProfile: $humanSLProfile)
                    .onChange(of: humanSLProfile) { _, newValue in
                        config.humanSLProfile = newValue
                        KataGoHelper.sendCommand("kata-set-param humanSLProfile \(newValue)")
                    }

                ConfigFloatItem(title: "Ratio", value: $humanSLRootExploreProbWeightful, step: 1/4, minValue: 0.0, maxValue: 1.0)
                    .onChange(of: humanSLRootExploreProbWeightful) { _, newValue in
                        config.humanSLRootExploreProbWeightful = newValue
                        KataGoHelper.sendCommand("kata-set-param humanSLRootExploreProbWeightful \(newValue)")
                    }
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
            hiddenAnalysisVisitRatio = config.hiddenAnalysisVisitRatio
            stoneStyle = config.stoneStyle
            showCoordinate = config.showCoordinate
            humanSLRootExploreProbWeightful = config.humanSLRootExploreProbWeightful
            humanSLProfile = config.humanSLProfile
            analysisForWhom = config.analysisForWhom
        }
    }
}

struct ConfigView: View {
    var config: Config
    @Binding var isBoardSizeChanged: Bool

    var body: some View {
        VStack {
            ConfigItems(config: config, isBoardSizeChanged: $isBoardSizeChanged)
                .padding()
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .onAppear() {
            KataGoHelper.sendCommand("stop")
        }
    }
}
