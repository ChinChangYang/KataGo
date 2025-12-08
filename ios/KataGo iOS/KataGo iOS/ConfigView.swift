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
            Spacer()
            Stepper(value: $value, in: minValue...maxValue, step: step) {
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
    let format: ValueFormat
    var postFix: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Stepper(value: $value, in: minValue...maxValue, step: step) {
                Text(formattedValue + (postFix ?? ""))
                    .frame(maxWidth: .infinity, alignment: .trailing)
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

struct ConfigTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: $text)
                .multilineTextAlignment(.trailing)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            Color.secondary.opacity(0.5),
                            lineWidth: 1
                        )
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("ConfigTextField") {
    struct PreviewHost: View {
        @State private var text = "Sample Text"
        var body: some View {
            ConfigTextField(title: "Test Field", text: $text)
                .padding()
        }
    }
    return PreviewHost()
}

struct ConfigTextPicker: View {
    let title: String
    let texts: [String]
    @Binding var selectedText: String

    var body: some View {
        Picker(title, selection: $selectedText) {
            ForEach(texts, id: \.self) { text in
                Text(text).tag(text)
            }
        }
    }
}

struct ConfigBoolItem: View {
    let title: String
    @Binding var value: Bool

    var body: some View {
        Toggle(title, isOn: $value)
    }
}

struct HumanStylePicker: View {
    let title: String
    @Binding var humanSLProfile: String

    var body: some View {
        Picker(title, selection: $humanSLProfile) {
            ForEach(HumanSLModel.allProfiles, id: \.self) { profile in
                Text(profile).tag(profile)
            }
        }
    }
}

struct NameConfigView: View {
    var gameRecord: GameRecord
    @State var name: String = ""

    var body: some View {
        List {
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

struct RuleConfigView: View {
    var config: Config
    @State var isBoardSizeChanged: Bool = false
    @State var isRuleChanged: Bool = false
    @State var boardWidth: Int = -1
    @State var boardHeight: Int = -1
    @State var koRuleText: String = Config.defaultKoRuleText
    @State var scoringRuleText: String = Config.defaultScoringRuleText
    @State var taxRuleText: String = Config.defaultTaxRuleText
    @State var multiStoneSuicideLegal: Bool = Config.defaultMultiStoneSuicideLegal
    @State var hasButton: Bool = Config.defaultHasButton
    @State var whiteHandicapBonusRuleText: String = Config.defaultWhiteHandicapBonusRuleText
    @State var komi: Float = Config.defaultKomi
    @State var komiText: String = String(Config.defaultKomi)
    @Environment(MessageList.self) var messageList
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    var maxBoardLength: Int

    var body: some View {
        List {
            ConfigIntItem(title: "Board width", value: $boardWidth, minValue: 2, maxValue: maxBoardLength)
                .onAppear {
                    boardWidth = config.boardWidth
                }
                .onChange(of: boardWidth) { oldValue, newValue in
                    config.boardWidth = newValue
                    if oldValue != -1 {
                        isBoardSizeChanged = true
                    }
                }

            ConfigIntItem(title: "Board height", value: $boardHeight, minValue: 2, maxValue: maxBoardLength)
                .onAppear {
                    boardHeight = config.boardHeight
                }
                .onChange(of: boardHeight) { oldValue, newValue in
                    config.boardHeight = newValue
                    if oldValue != -1 {
                        isBoardSizeChanged = true
                    }
                }

            ConfigTextPicker(
                title: "Ko rule",
                texts: Config.koRules,
                selectedText: $koRuleText
            )
            .onAppear {
                koRuleText = config.koRuleText
            }
            .onChange(of: koRuleText) { _, newValue in
                let rawValue = Config.koRules.firstIndex(of: newValue) ?? Config.defaultKoRule
                config.koRule = KoRule(rawValue: rawValue) ?? .simple
                messageList.appendAndSend(command: config.koRuleCommand)
                isRuleChanged = true
            }

            ConfigTextPicker(
                title: "Scoring rule",
                texts: Config.scoringRules,
                selectedText: $scoringRuleText
            )
            .onAppear {
                scoringRuleText = config.scoringRuleText
            }
            .onChange(of: scoringRuleText) { _, newValue in
                let rawValue = Config.scoringRules.firstIndex(of: scoringRuleText) ?? Config.defaultScoringRule
                config.scoringRule = ScoringRule(rawValue: rawValue) ?? .area
                messageList.appendAndSend(command: config.scoringRuleCommand)
                isRuleChanged = true
            }

            ConfigTextPicker(
                title: "Tax rule",
                texts: Config.taxRules,
                selectedText: $taxRuleText
            )
            .onAppear {
                taxRuleText = config.taxRuleText
            }
            .onChange(of: taxRuleText) { _, newValue in
                let rawValue = Config.taxRules.firstIndex(of: taxRuleText) ?? Config.defaultTaxRule
                config.taxRule = TaxRule(rawValue: rawValue) ?? .none
                messageList.appendAndSend(command: config.taxRuleCommand)
                isRuleChanged = true
            }

            ConfigBoolItem(title: "Multi-stone suicide", value: $multiStoneSuicideLegal)
                .onAppear {
                    multiStoneSuicideLegal = config.multiStoneSuicideLegal
                }
                .onChange(of: multiStoneSuicideLegal) { _, newValue in
                    config.multiStoneSuicideLegal = newValue
                    messageList.appendAndSend(command: config.multiStoneSuicideLegalCommand)
                    isRuleChanged = true
                }

            ConfigBoolItem(title: "Has button", value: $hasButton)
                .onAppear {
                    hasButton = config.hasButton
                }
                .onChange(of: hasButton) { _, newValue in
                    config.hasButton = newValue
                    messageList.appendAndSend(command: config.hasButtonCommand)
                    isRuleChanged = true
                }

            ConfigTextPicker(
                title: "White handicap bonus",
                texts: Config.whiteHandicapBonusRules,
                selectedText: $whiteHandicapBonusRuleText
            )
            .onAppear {
                whiteHandicapBonusRuleText = config.whiteHandicapBonusRuleText
            }
            .onChange(of: whiteHandicapBonusRuleText) { _, newValue in
                let rawValue = Config.whiteHandicapBonusRules.firstIndex(of: whiteHandicapBonusRuleText) ?? Config.defaultWhiteHandicapBonusRule
                config.whiteHandicapBonusRule = WhiteHandicapBonusRule(rawValue: rawValue) ?? .zero
                messageList.appendAndSend(command: config.whiteHandicapBonusRuleCommand)
                isRuleChanged = true
            }

            ConfigTextField(
                title: "Komi",
                text: $komiText
            )
            .onAppear {
                komi = config.komi
                komiText = String(komi)
            }
            .onChange(of: komiText) { _, newValue in
                config.komi = min(1_000, max(-1_000, ((Float(newValue) ?? Config.defaultKomi) * 2).rounded() / 2))
                messageList.appendAndSend(command: config.getKataKomiCommand())
                isRuleChanged = true
            }
        }
        .onAppear {
            isBoardSizeChanged = false
            isRuleChanged = false
        }
        .onDisappear {
            if isBoardSizeChanged {
                player.nextColorForPlayCommand = .unknown
                messageList.appendAndSend(command: config.getKataBoardSizeCommand())
                gobanState.sendShowBoardCommand(messageList: messageList)
            }

            if isBoardSizeChanged || isRuleChanged {
                messageList.appendAndSend(command: "printsgf")
            }
        }
    }
}

struct AnalysisConfigView: View {
    var config: Config
    @State var analysisInformationText: String = Config.defaultAnalysisInformationText
    @State var analysisForWhomText: String = Config.defaultAnalysisForWhomText
    @State var hiddenAnalysisVisitRatio: Float = Config.defaultHiddenAnalysisVisitRatio
    @State var hiddenAnalysisVisitRatioText = String(Config.defaultHiddenAnalysisVisitRatio)
    @State var analysisWideRootNoise: Float = Config.defaultAnalysisWideRootNoise
    @State var analysisWideRootNoiseText = String(Config.defaultAnalysisWideRootNoise)
    @State var maxAnalysisMoves: Int = Config.defaultMaxAnalysisMoves
    @State var analysisInterval: Int = Config.defaultAnalysisInterval
    @Environment(MessageList.self) var messageList

    var body: some View {
        List {
            ConfigTextPicker(
                title: "Analysis information",
                texts: Config.analysisInformations,
                selectedText: $analysisInformationText
            )
            .onAppear {
                analysisInformationText = config.analysisInformationText
            }
            .onChange(of: analysisInformationText) { _, newValue in
                config.analysisInformation = Config.analysisInformations.firstIndex(of: newValue) ?? Config.defaultAnalysisInformation
            }

            ConfigTextPicker(
                title: "Analysis for",
                texts: Config.analysisForWhoms,
                selectedText: $analysisForWhomText
            )
            .onAppear {
                analysisForWhomText = config.analysisForWhomText
            }
            .onChange(of: analysisForWhomText) { _, newValue in
                config.analysisForWhom = Config.analysisForWhoms.firstIndex(of: newValue) ?? Config.defaultAnalysisForWhom
            }

            ConfigTextField(
                title: "Hidden analysis visit ratio",
                text: $hiddenAnalysisVisitRatioText
            )
            .onAppear {
                hiddenAnalysisVisitRatio = config.hiddenAnalysisVisitRatio
                hiddenAnalysisVisitRatioText = String(config.hiddenAnalysisVisitRatio)
            }
            .onChange(of: hiddenAnalysisVisitRatioText) { _, newValue in
                config.hiddenAnalysisVisitRatio = min(1, max(0, Float(newValue) ?? Config.defaultHiddenAnalysisVisitRatio))
            }

            ConfigTextField(
                title: "Analysis wide root noise",
                text: $analysisWideRootNoiseText
            )
            .onAppear {
                analysisWideRootNoise = config.analysisWideRootNoise
                analysisWideRootNoiseText = String(config.analysisWideRootNoise)
            }
            .onChange(of: analysisWideRootNoiseText) { _, newValue in
                config.analysisWideRootNoise = min(1, max(0, Float(newValue) ?? Config.defaultAnalysisWideRootNoise))
                messageList.appendAndSend(command: config.getKataAnalysisWideRootNoiseCommand())
            }

            ConfigIntItem(title: "Max analysis moves", value: $maxAnalysisMoves, minValue: 1, maxValue: 1_000)
                .onAppear {
                    maxAnalysisMoves = config.maxAnalysisMoves
                }
                .onChange(of: maxAnalysisMoves) { _, newValue in
                    config.maxAnalysisMoves = newValue
                }

            ConfigIntItem(title: "Analysis interval", value: $analysisInterval, minValue: 10, maxValue: 300, step: 10)
                .onAppear {
                    analysisInterval = config.analysisInterval
                }
                .onChange(of: analysisInterval) { _, newValue in
                    config.analysisInterval = newValue
                }
        }
    }
}

struct ViewConfigView: View {
    var config: Config
    @State var stoneStyleText = Config.defaultStoneStyleText
    @State var analysisStyleText = Config.defaultAnalysisStyleText
    @State var showCoordinate = Config.defaultShowCoordinate
    @State var showPass = Config.defaultShowPass
    @State var verticalFlip = Config.defaultVerticalFlip
    @State var showCharts = Config.defaultShowCharts
    @State var showOwnership: Bool = Config.defaultShowOwnership
    @State var showWinrateBar: Bool = Config.defaultShowWinrateBar

    var body: some View {
        List {
            ConfigTextPicker(
                title: "Stone style",
                texts: Config.stoneStyles,
                selectedText: $stoneStyleText
            )
            .onAppear {
                stoneStyleText = config.stoneStyleText
            }
            .onChange(of: stoneStyleText) { _, newValue in
                config.stoneStyle = Config.stoneStyles.firstIndex(of: newValue) ?? Config.defaultStoneStyle
            }

            ConfigTextPicker(
                title: "Analysis style",
                texts: Config.analysisStyles,
                selectedText: $analysisStyleText
            )
            .onAppear {
                analysisStyleText = config.analysisStyleText
            }
            .onChange(of: analysisStyleText) { _, newValue in
                config.analysisStyle = Config.analysisStyles.firstIndex(of: newValue) ?? Config.defaultAnalysisStyle
            }

            ConfigBoolItem(title: "Show coordinate", value: $showCoordinate)
                .onAppear {
                    showCoordinate = config.showCoordinate
                }
                .onChange(of: showCoordinate) { _, newValue in
                    config.showCoordinate = showCoordinate
                }

            ConfigBoolItem(title: "Show pass", value: $showPass)
                .onAppear {
                    showPass = config.showPass
                }
                .onChange(of: showPass) { _, newValue in
                    config.showPass = showPass
                }

            ConfigBoolItem(title: "Vertical flip", value: $verticalFlip)
                .onAppear {
                    verticalFlip = config.verticalFlip
                }
                .onChange(of: verticalFlip) { _, newValue in
                    config.verticalFlip = verticalFlip
                }

            ConfigBoolItem(title: "Show chart/comments", value: $showCharts)
                .onAppear {
                    showCharts = config.showCharts
                }
                .onChange(of: showCharts) { _, newValue in
                    config.showCharts = showCharts
                }

            ConfigBoolItem(title: "Show ownership", value: $showOwnership)
                .onAppear {
                    showOwnership = config.showOwnership
                }
                .onChange(of: showOwnership) { _, newValue in
                    config.showOwnership = newValue
                }

            ConfigBoolItem(title: "Show win rate bar", value: $showWinrateBar)
                .onAppear {
                    showWinrateBar = config.showWinrateBar
                }
                .onChange(of: showWinrateBar) { _, newValue in
                    config.showWinrateBar = newValue
                }
        }
    }
}

struct SoundConfigView: View {
    var config: Config
    @State var soundEffect: Bool = Config.defaultSoundEffect

    var body: some View {
        List {
            ConfigBoolItem(title: "Sound effect", value: $soundEffect)
                .onAppear {
                    soundEffect = config.soundEffect
                }
                .onChange(of: soundEffect) { _, newValue in
                    config.soundEffect = soundEffect
                }
        }
    }
}

struct AIConfigView: View {
    var config: Config
    @State var playoutDoublingAdvantage: Float = Config.defaultPlayoutDoublingAdvantage
    @State var humanProfileForBlack = Config.defaultHumanSLProfile
    @State var blackMaxTime = Config.defaultBlackMaxTime
    @State var humanProfileForWhite = Config.defaultHumanSLProfile
    @State var whiteMaxTime = Config.defaultWhiteMaxTime
    @State var blackHumanSLModel = HumanSLModel()
    @State var whiteHumanSLModel = HumanSLModel()
    @Environment(Turn.self) var player
    @Environment(MessageList.self) var messageList

    var body: some View {
        List {
            ConfigFloatItem(title: "White advantage",
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

            Text("Black AI".uppercased())
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .padding(.top)

            HumanStylePicker(title: "Human profile", humanSLProfile: $humanProfileForBlack)
                .onAppear {
                    humanProfileForBlack = config.humanSLProfile
                    blackHumanSLModel.profile = config.humanProfileForBlack
                }
                .onChange(of: humanProfileForBlack) { _, newValue in
                    config.humanSLProfile = newValue
                    blackHumanSLModel.profile = newValue
                    if player.nextColorForPlayCommand != .white {
                        messageList.appendAndSend(commands: blackHumanSLModel.commands)
                    }
                }

            ConfigFloatItem(title: "Time per move",
                            value: $blackMaxTime,
                            step: 0.5,
                            minValue: 0,
                            maxValue: 60,
                            format: .number,
                            postFix: "s")
            .onAppear {
                blackMaxTime = config.blackMaxTime
            }
            .onChange(of: blackMaxTime) { _, newValue in
                config.blackMaxTime = newValue
            }

            Text("White AI".uppercased())
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .padding(.top)

            HumanStylePicker(title: "Human profile", humanSLProfile: $humanProfileForWhite)
                .onAppear {
                    humanProfileForWhite = config.humanProfileForWhite
                    whiteHumanSLModel.profile = config.humanProfileForWhite
                }
                .onChange(of: humanProfileForWhite) { _, newValue in
                    config.humanProfileForWhite = newValue
                    whiteHumanSLModel.profile = newValue
                    if player.nextColorForPlayCommand != .black {
                        messageList.appendAndSend(commands: whiteHumanSLModel.commands)
                    }
                }

            ConfigFloatItem(title: "Time per move",
                            value: $whiteMaxTime,
                            step: 0.5,
                            minValue: 0,
                            maxValue: 60,
                            format: .number,
                            postFix: "s")
            .onAppear {
                whiteMaxTime = config.whiteMaxTime
            }
            .onChange(of: whiteMaxTime) { _, newValue in
                config.whiteMaxTime = newValue
            }
        }
    }
}

struct CommentConfigView: View {
    var config: Config
    @State var useLLM: Bool = Config.defaultUseLLM
    @State var toneText: String = Config.defaultToneText
    @State var temperature: Float = Config.defaultTemperature

    var body: some View {
        List {
            ConfigBoolItem(title: "Apple Intelligence", value: $useLLM)
                .onAppear {
                    useLLM = config.useLLM
                }
                .onChange(of: useLLM) { _, newValue in
                    config.useLLM = useLLM
                }

            ConfigTextPicker(
                title: "Tone",
                texts: Config.tones,
                selectedText: $toneText
            )
            .onAppear {
                toneText = config.toneText
            }
            .onChange(of: toneText) { _, newValue in
                let rawValue = Config.tones.firstIndex(of: newValue) ?? Config.defaultTone
                config.tone = CommentTone(rawValue: rawValue) ?? .technical
            }

            ConfigFloatItem(
                title: "Temperature",
                value: $temperature,
                step: 0.1,
                minValue: 0,
                maxValue: 1,
                format: .number
            )
            .onAppear {
                temperature = ((config.temperature) * 10).rounded() / 10
            }
            .onChange(of: temperature) { _, newValue in
                config.temperature = (newValue * 10).rounded() / 10
            }
        }
    }
}

struct SgfConfigView: View {
    var gameRecord: GameRecord
    @State var sgf: String = ""
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    @Environment(MessageList.self) var messageList

    var body: some View {
        List {
            TextField("Paste your SGF text", text: $sgf, axis: .vertical)
                .disableAutocorrection(true)
#if !os(macOS)
                .textInputAutocapitalization(.never)
#endif
                .onAppear {
                    sgf = gameRecord.sgf
                }
                .onDisappear {
                    if sgf != gameRecord.sgf {
                        let config = gameRecord.concreteConfig
                        let sgfHelper = SgfHelper(sgf: sgf)
                        config.boardWidth = sgfHelper.xSize
                        config.boardHeight = sgfHelper.ySize
                        config.koRule = sgfHelper.rules.koRule
                        config.scoringRule = sgfHelper.rules.scoringRule
                        config.taxRule = sgfHelper.rules.taxRule
                        config.multiStoneSuicideLegal = sgfHelper.rules.multiStoneSuicideLegal
                        config.hasButton = sgfHelper.rules.hasButton
                        config.whiteHandicapBonusRule = sgfHelper.rules.whiteHandicapBonusRule
                        config.komi = sgfHelper.rules.komi
                        gameRecord.sgf = sgf
                        player.nextColorForPlayCommand = .unknown

                        gobanState.maybeLoadSgf(
                            gameRecord: gameRecord,
                            messageList: messageList
                        )

                        messageList.appendAndSend(commands: config.ruleCommands)
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

struct ConfigItems: View {
    var gameRecord: GameRecord
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(Turn.self) var player
    @Environment(MessageList.self) var messageList
    var maxBoardLength: Int

    var config: Config {
        gameRecord.concreteConfig
    }

    var body: some View {
        List {
            NavigationLink("Name") {
                NameConfigView(gameRecord: gameRecord)
                    .navigationTitle("Name")
            }

            NavigationLink("Rule") {
                RuleConfigView(config: config, maxBoardLength: maxBoardLength)
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

            NavigationLink("Comment") {
                CommentConfigView(config: config)
                    .navigationTitle("Comment")
            }

            NavigationLink("SGF") {
                SgfConfigView(gameRecord: gameRecord)
                    .navigationTitle("SGF")
            }
        }
    }
}

struct ConfigView: View {
    var gameRecord: GameRecord
    var maxBoardLength: Int

    var body: some View {
        NavigationStack {
            ConfigItems(gameRecord: gameRecord, maxBoardLength: maxBoardLength)
        }
        .navigationTitle("Configuration")
    }
}
