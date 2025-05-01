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
    var step: Int = 1

    var body: some View {
        HStack {
            Text(title)
#if !os(macOS)
            Spacer()
#endif
            Stepper(value: $value, in: minValue...maxValue, step: step) {
                Text("\(value)")
#if !os(macOS)
                    .frame(maxWidth: .infinity, alignment: .trailing)
#endif
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
    let format: ValueFormat

    var body: some View {
        HStack {
            Text(title)
#if !os(macOS)
            Spacer()
#endif
            Stepper(value: $value, in: minValue...maxValue, step: step) {
                Text(formattedValue)
#if !os(macOS)
                    .frame(maxWidth: .infinity, alignment: .trailing)
#endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formattedValue: String {
        switch format {
        case .number:
            return value.formatted(.number)
        case .percent:
            return value.formatted(.percent)
        }
    }

    enum ValueFormat {
        case number
        case percent
    }
}

struct ConfigTextItem: View {
    let title: String
    let texts: [String]
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(title)
#if !os(macOS)
            Spacer()
#endif
            Stepper {
                Text(texts[value])
#if !os(macOS)
                    .frame(maxWidth: .infinity, alignment: .trailing)
#endif
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
#if !os(macOS)
            Spacer()
#endif
            Stepper {
                Text(label)
#if !os(macOS)
                    .frame(maxWidth: .infinity, alignment: .trailing)
#endif
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
    let title: String
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
        Picker(title, selection: $humanSLProfile) {
            ForEach(profiles, id: \.self) { profile in
                Text(profile).tag(profile)
            }
        }
    }
}

struct NameConfigView: View {
    var gameRecord: GameRecord
    @State var name: String = ""

    var body: some View {
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
        }
    }
}

struct RuleConfigView: View {
    var config: Config
    @Binding var isBoardSizeChanged: Bool
    @State var boardWidth: Int = -1
    @State var boardHeight: Int = -1
    @State var rule: Int = Config.defaultRule
    @State var komi: Float = Config.defaultKomi
    @Environment(MessageList.self) var messageList

    var body: some View {
        Form {
            Section("Rule") {
                ConfigIntItem(title: "Board width:", value: $boardWidth, minValue: 2, maxValue: 29)
                    .onAppear {
                        boardWidth = config.boardWidth
                    }
                    .onChange(of: boardWidth) { oldValue, newValue in
                        config.boardWidth = newValue
                        if oldValue != -1 {
                            isBoardSizeChanged = true
                        }
                    }

                ConfigIntItem(title: "Board height:", value: $boardHeight, minValue: 2, maxValue: 29)
                    .onAppear {
                        boardHeight = config.boardHeight
                    }
                    .onChange(of: boardHeight) { oldValue, newValue in
                        config.boardHeight = newValue
                        if oldValue != -1 {
                            isBoardSizeChanged = true
                        }
                    }

                ConfigTextItem(title: "Rule:", texts: Config.rules, value: $rule)
                    .onAppear {
                        rule = config.rule
                    }
                    .onChange(of: rule) { _, newValue in
                        config.rule = newValue
                        messageList.appendAndSend(command: config.getKataRuleCommand())
                    }

                ConfigFloatItem(title: "Komi:", value: $komi, step: 0.5, minValue: -1_000, maxValue: 1_000, format: .number)
                    .onAppear {
                        komi = config.komi
                    }
                    .onChange(of: komi) { _, newValue in
                        config.komi = newValue
                        messageList.appendAndSend(command: config.getKataKomiCommand())
                    }
            }
        }
    }
}

struct AnalysisConfigView: View {
    var config: Config
    @State var analysisInformation: Int = Config.defaultAnalysisInformation
    @State var showOwnership: Bool = Config.defaultShowOwnership
    @State var analysisForWhom: Int = Config.defaultAnalysisForWhom
    @State var hiddenAnalysisVisitRatio: Float = Config.defaultHiddenAnalysisVisitRatio
    @State var analysisWideRootNoise: Float = Config.defaultAnalysisWideRootNoise
    @State var maxAnalysisMoves: Int = Config.defaultMaxAnalysisMoves
    @State var analysisInterval: Int = Config.defaultAnalysisInterval
    @Environment(MessageList.self) var messageList

    var body: some View {
        Form {
            Section("Analysis") {
                ConfigTextItem(title: "Analysis information:", texts: Config.analysisInformations, value: $analysisInformation)
                    .onAppear {
                        analysisInformation = config.analysisInformation
                    }
                    .onChange(of: analysisInformation) { _, newValue in
                        config.analysisInformation = newValue
                    }

                ConfigBoolItem(title: "Show ownership:", value: $showOwnership)
                    .onAppear {
                        showOwnership = config.showOwnership
                    }
                    .onChange(of: showOwnership) { _, newValue in
                        config.showOwnership = newValue
                    }

                ConfigTextItem(title: "Analysis for:", texts: Config.analysisForWhoms, value: $analysisForWhom)
                    .onAppear {
                        analysisForWhom = config.analysisForWhom
                    }
                    .onChange(of: analysisForWhom) { _, newValue in
                        config.analysisForWhom = newValue
                    }

                ConfigFloatItem(title: "Hidden analysis visit ratio:", value: $hiddenAnalysisVisitRatio, step: 0.0078125, minValue: 0.0, maxValue: 1.0, format: .number)
                    .onAppear {
                        hiddenAnalysisVisitRatio = config.hiddenAnalysisVisitRatio
                    }
                    .onChange(of: hiddenAnalysisVisitRatio) { _, newValue in
                        config.hiddenAnalysisVisitRatio = newValue
                    }

                ConfigFloatItem(title: "Analysis wide root noise:", value: $analysisWideRootNoise, step: 0.0078125, minValue: 0.0, maxValue: 1.0, format: .number)
                    .onAppear {
                        analysisWideRootNoise = config.analysisWideRootNoise
                    }
                    .onChange(of: analysisWideRootNoise) { _, newValue in
                        config.analysisWideRootNoise = newValue
                        messageList.appendAndSend(command: config.getKataAnalysisWideRootNoiseCommand())
                    }

                ConfigIntItem(title: "Max analysis moves:", value: $maxAnalysisMoves, minValue: 1, maxValue: 1_000)
                    .onAppear {
                        maxAnalysisMoves = config.maxAnalysisMoves
                    }
                    .onChange(of: maxAnalysisMoves) { _, newValue in
                        config.maxAnalysisMoves = newValue
                    }

                ConfigIntItem(title: "Analysis interval:", value: $analysisInterval, minValue: 10, maxValue: 300, step: 10)
                    .onAppear {
                        analysisInterval = config.analysisInterval
                    }
                    .onChange(of: analysisInterval) { _, newValue in
                        config.analysisInterval = newValue
                    }
            }
        }
    }
}

struct ViewConfigView: View {
    var config: Config
    @State var stoneStyle = Config.defaultStoneStyle
    @State var showCoordinate = Config.defaultShowCoordinate
    @State var showComments = Config.defaultShowComments
    @State var showPass = Config.defaultShowPass
    @State var verticalFlip = Config.defaultVerticalFlip

    var body: some View {
        Form {
            Section("View") {
                ConfigTextItem(title: "Stone style:", texts: Config.stoneStyles, value: $stoneStyle)
                    .onAppear {
                        stoneStyle = config.stoneStyle
                    }
                    .onChange(of: stoneStyle) { _, newValue in
                        config.stoneStyle = stoneStyle
                    }

                ConfigBoolItem(title: "Show coordinate:", value: $showCoordinate)
                    .onAppear {
                        showCoordinate = config.showCoordinate
                    }
                    .onChange(of: showCoordinate) { _, newValue in
                        config.showCoordinate = showCoordinate
                    }

                ConfigBoolItem(title: "Show comments:", value: $showComments)
                    .onAppear {
                        showComments = config.showComments
                    }
                    .onChange(of: showComments) { _, newValue in
                        config.showComments = showComments
                    }

                ConfigBoolItem(title: "Show pass:", value: $showPass)
                    .onAppear {
                        showPass = config.showPass
                    }
                    .onChange(of: showPass) { _, newValue in
                        config.showPass = showPass
                    }

                ConfigBoolItem(title: "Vertical flip:", value: $verticalFlip)
                    .onAppear {
                        verticalFlip = config.verticalFlip
                    }
                    .onChange(of: verticalFlip) { _, newValue in
                        config.verticalFlip = verticalFlip
                    }
            }
        }
    }
}

struct SoundConfigView: View {
    var config: Config
    @State var soundEffect: Bool = Config.defaultSoundEffect

    var body: some View {
        Form {
            Section("Sound") {
                ConfigBoolItem(title: "Sound effect:", value: $soundEffect)
                    .onAppear {
                        soundEffect = config.soundEffect
                    }
                    .onChange(of: soundEffect) { _, newValue in
                        config.soundEffect = soundEffect
                    }
            }
        }
    }
}

struct AIConfigView: View {
    var config: Config
    @State var playoutDoublingAdvantage: Float = Config.defaultPlayoutDoublingAdvantage
    @State var humanSLProfile = Config.defaultHumanSLProfile
    @State var humanSLRootExploreProbWeightful = Config.defaultHumanSLRootExploreProbWeightful
    @State var humanProfileForWhite = Config.defaultHumanSLProfile
    @State var humanRatioForWhite = Config.defaultHumanSLRootExploreProbWeightful
    @Environment(Turn.self) var player
    @Environment(MessageList.self) var messageList

    var body: some View {
        Form {
            Section("AI") {
                ConfigFloatItem(title: "White advantage:",
                                value: $playoutDoublingAdvantage,
                                step: 1/4,
                                minValue: -3.0,
                                maxValue: 3.0,
                                format: .percent)
                .onAppear {
                    playoutDoublingAdvantage = config.playoutDoublingAdvantage
                }
                .onChange(of: playoutDoublingAdvantage) { _, newValue in
                    config.playoutDoublingAdvantage = newValue
                    messageList.appendAndSend(command: config.getKataPlayoutDoublingAdvantageCommand())
                }
            }

            Section("Black AI") {
                HumanStylePicker(title: "Human profile:", humanSLProfile: $humanSLProfile)
                    .onAppear {
                        humanSLProfile = config.humanSLProfile
                    }
                    .onChange(of: humanSLProfile) { _, newValue in
                        config.humanSLProfile = newValue
                        if player.nextColorForPlayCommand != .white {
                            messageList.appendAndSend(command: "kata-set-param humanSLProfile \(config.humanSLProfile)")
                        }
                    }

                ConfigFloatItem(title: "Humanness:",
                                value: $humanSLRootExploreProbWeightful,
                                step: 1/4,
                                minValue: 0.0,
                                maxValue: 1.0,
                                format: .percent)
                .onAppear {
                    humanSLRootExploreProbWeightful = config.humanSLRootExploreProbWeightful
                }
                .onChange(of: humanSLRootExploreProbWeightful) { _, newValue in
                    config.humanSLRootExploreProbWeightful = newValue
                    if player.nextColorForPlayCommand != .white {
                        messageList.appendAndSend(command: "kata-set-param humanSLRootExploreProbWeightful \(newValue)")
                    }
                }
            }

            Section("White AI") {
                HumanStylePicker(title: "Human profile:", humanSLProfile: $humanProfileForWhite)
                    .onAppear {
                        humanProfileForWhite = config.humanProfileForWhite
                    }
                    .onChange(of: humanProfileForWhite) { _, newValue in
                        config.humanProfileForWhite = newValue
                        if player.nextColorForPlayCommand != .black {
                            messageList.appendAndSend(command: "kata-set-param humanSLProfile \(config.humanSLProfile)")
                        }
                    }

                ConfigFloatItem(title: "Humanness:",
                                value: $humanRatioForWhite,
                                step: 1/4,
                                minValue: 0.0,
                                maxValue: 1.0,
                                format: .percent)
                .onAppear {
                    humanRatioForWhite = config.humanRatioForWhite
                }
                .onChange(of: humanRatioForWhite) { _, newValue in
                    config.humanRatioForWhite = newValue
                    if player.nextColorForPlayCommand != .black {
                        messageList.appendAndSend(command: "kata-set-param humanSLRootExploreProbWeightful \(newValue)")
                    }
                }
            }
        }
    }
}

struct SgfConfigView: View {
    var gameRecord: GameRecord
    @Binding var isBoardSizeChanged: Bool
    @State var sgf: String = ""
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    @Environment(MessageList.self) var messageList

    var body: some View {
        Form {
            Section("SGF") {
                TextField("Paste your SGF text", text: $sgf, axis: .vertical)
                    .disableAutocorrection(true)
#if !os(macOS)
                    .textInputAutocapitalization(.never)
#endif
                    .onAppear {
                        sgf = gameRecord.sgf
                    }
                    .onDisappear {
                        if (!isBoardSizeChanged) && (sgf != gameRecord.sgf) {
                            let config = gameRecord.concreteConfig
                            gameRecord.sgf = sgf
                            player.nextColorForPlayCommand = .unknown
                            messageList.maybeLoadSgf(sgf: sgf)
                            messageList.appendAndSend(command: config.getKataRuleCommand())
                            messageList.appendAndSend(command: config.getKataKomiCommand())
                            messageList.appendAndSend(command: config.getKataPlayoutDoublingAdvantageCommand())
                            messageList.appendAndSend(command: config.getKataAnalysisWideRootNoiseCommand())
                            messageList.appendAndSend(commands: config.getSymmetricHumanAnalysisCommands())
                            gobanState.sendShowBoardCommand(messageList: messageList)
                            messageList.appendAndSend(command: "printsgf")
                        }
                    }
            }
        }
    }
}

struct ConfigItems: View {
    var gameRecord: GameRecord
    @State private var isBoardSizeChanged = false
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanTab.self) var gobanTab
    @Environment(GobanState.self) var gobanState
    @Environment(Turn.self) var player
    @Environment(MessageList.self) var messageList

    var config: Config {
        gameRecord.concreteConfig
    }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Name") {
                    NameConfigView(gameRecord: gameRecord)
                        .navigationTitle("Name")
                }

                NavigationLink("Rule") {
                    RuleConfigView(config: config, isBoardSizeChanged: $isBoardSizeChanged)
                        .navigationTitle("Rule")
                }

                NavigationLink("Analysis") {
                    AnalysisConfigView(config: config)
                        .navigationTitle("Analysis")
                }

                NavigationLink("View") {
                    ViewConfigView(config: config)
                        .navigationTitle("View")
                }

                NavigationLink("Sound") {
                    SoundConfigView(config: config)
                        .navigationTitle("Sound")
                }

                NavigationLink("AI") {
                    AIConfigView(config: config)
                        .navigationTitle("AI")
                }

                NavigationLink("SGF") {
                    SgfConfigView(gameRecord: gameRecord, isBoardSizeChanged: $isBoardSizeChanged)
                        .navigationTitle("SGF")
                }
            }
            .navigationTitle("Configuration")
        }
        .onAppear {
            isBoardSizeChanged = false
        }
        .onDisappear {
            if isBoardSizeChanged {
                player.nextColorForPlayCommand = .unknown
                messageList.appendAndSend(command: gameRecord.concreteConfig.getKataBoardSizeCommand())
                gobanState.sendShowBoardCommand(messageList: messageList)
                messageList.appendAndSend(command: "printsgf")
            }
        }
    }
}

struct ConfigView: View {
    var gameRecord: GameRecord

    var body: some View {
        VStack {
            ConfigItems(gameRecord: gameRecord)
                .padding()
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}
