//
//  ConfigView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/19.
//

import SwiftUI
import KataGoUICore

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
    /// Optional identifier applied to the Stepper so UI tests can address a
    /// specific control when several share the same visible title.
    var stepperAccessibilityID: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Stepper(value: $value, in: minValue...maxValue, step: step) {
                Text(formattedValue + (postFix ?? ""))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .accessibilityIdentifier(stepperAccessibilityID ?? "")
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
                .onChange(of: name) { _, _ in
                    gameRecord.name = name
                }
        }
    }
}

struct RuleConfigView: View {
    var config: Config
    var maxBoardLength: Int
    var gameRecord: GameRecord

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
    @Environment(BoardSize.self) var board
    @Environment(Stones.self) var stones
    @Environment(BookLookup.self) var bookLookup

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
                let koRule = KoRule(rawValue: rawValue) ?? .simple
                ConfigEngineSync.setKoRule(koRule, config: config, messageList: messageList)
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
            .onChange(of: scoringRuleText) { _, _ in
                let rawValue = Config.scoringRules.firstIndex(of: scoringRuleText) ?? Config.defaultScoringRule
                let scoringRule = ScoringRule(rawValue: rawValue) ?? .area
                ConfigEngineSync.setScoringRule(scoringRule, config: config, messageList: messageList)
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
            .onChange(of: taxRuleText) { _, _ in
                let rawValue = Config.taxRules.firstIndex(of: taxRuleText) ?? Config.defaultTaxRule
                let taxRule = TaxRule(rawValue: rawValue) ?? .none
                ConfigEngineSync.setTaxRule(taxRule, config: config, messageList: messageList)
                isRuleChanged = true
            }

            ConfigBoolItem(title: "Multi-stone suicide", value: $multiStoneSuicideLegal)
                .onAppear {
                    multiStoneSuicideLegal = config.multiStoneSuicideLegal
                }
                .onChange(of: multiStoneSuicideLegal) { _, newValue in
                    ConfigEngineSync.setMultiStoneSuicideLegal(newValue, config: config, messageList: messageList)
                    isRuleChanged = true
                }

            ConfigBoolItem(title: "Has button", value: $hasButton)
                .onAppear {
                    hasButton = config.hasButton
                }
                .onChange(of: hasButton) { _, newValue in
                    ConfigEngineSync.setHasButton(newValue, config: config, messageList: messageList)
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
            .onChange(of: whiteHandicapBonusRuleText) { _, _ in
                let rawValue = Config.whiteHandicapBonusRules.firstIndex(of: whiteHandicapBonusRuleText) ?? Config.defaultWhiteHandicapBonusRule
                let rule = WhiteHandicapBonusRule(rawValue: rawValue) ?? .zero
                ConfigEngineSync.setWhiteHandicapBonusRule(rule, config: config, messageList: messageList)
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
                ConfigEngineSync.setKomi(Float(newValue) ?? Config.defaultKomi, config: config, messageList: messageList)
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
                messageList.appendAndSend(command: GtpCommandBuilder.boardSizeCommand(width: config.boardWidth, height: config.boardHeight))
                gobanState.sendShowBoardCommand(messageList: messageList)
            } else if isRuleChanged {
                // The "printsgf" will trigger the app to save the printed sgf to the game record, so this ensures the printed sgf contains all moves.
                gobanState.forwardMoves(
                    limit: nil,
                    gameRecord: gameRecord,
                    board: board,
                    messageList: messageList,
                    player: player,
                    audioModel: nil,
                    stones: stones
                )
            }

            if isBoardSizeChanged || isRuleChanged {
                messageList.appendAndSend(command: "printsgf")

                if config.isBookCompatible && gobanState.eyeStatus == .opened {
                    bookLookup.loadIfNeeded()
                    gobanState.eyeStatus = .book
                }

                if !config.isBookCompatible && gobanState.eyeStatus == .book {
                    gobanState.eyeStatus = .opened
                }
            }
        }
    }
}

struct AnalysisConfigView: View {
    var config: Config
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
                ConfigEngineSync.setAnalysisWideRootNoise(Float(newValue) ?? Config.defaultAnalysisWideRootNoise, config: config, messageList: messageList)
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
    @Environment(GobanState.self) var gobanState

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
                ConfigEngineSync.setPlayoutDoublingAdvantage(newValue, config: config, messageList: messageList)
            }

            Text("Black AI".uppercased())
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .padding(.top)

            HumanStylePicker(title: "Human profile", humanSLProfile: $humanProfileForBlack)
                .onAppear {
                    let canonical = HumanSLModel.canonicalProfile(config.humanProfileForBlack)
                    humanProfileForBlack = canonical
                    blackHumanSLModel.profile = canonical
                }
                .onChange(of: humanProfileForBlack) { _, newValue in
                    blackHumanSLModel.profile = newValue
                    ConfigEngineSync.setBlackHumanProfile(newValue, config: config, player: player, messageList: messageList)
                }

            ConfigFloatItem(title: "Time per move",
                            value: $blackMaxTime,
                            step: 0.5,
                            minValue: 0,
                            maxValue: 60,
                            format: .number,
                            postFix: "s",
                            stepperAccessibilityID: "blackTimePerMove")
            .onAppear {
                blackMaxTime = config.blackMaxTime
            }
            .onChange(of: blackMaxTime) { _, newValue in
                // Route through ConfigEngineSync (like macOS / the board's name-label
                // toggle) so flipping Black to/from Human here also reconfigures the
                // engine's human-SL state for analysis, not just the stored value.
                ConfigEngineSync.setBlackMaxTime(newValue, config: config, gobanState: gobanState,
                                                 player: player, messageList: messageList)
            }

            Text("White AI".uppercased())
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .padding(.top)

            HumanStylePicker(title: "Human profile", humanSLProfile: $humanProfileForWhite)
                .onAppear {
                    let canonical = HumanSLModel.canonicalProfile(config.humanProfileForWhite)
                    humanProfileForWhite = canonical
                    whiteHumanSLModel.profile = canonical
                }
                .onChange(of: humanProfileForWhite) { _, newValue in
                    whiteHumanSLModel.profile = newValue
                    ConfigEngineSync.setWhiteHumanProfile(newValue, config: config, player: player, messageList: messageList)
                }

            ConfigFloatItem(title: "Time per move",
                            value: $whiteMaxTime,
                            step: 0.5,
                            minValue: 0,
                            maxValue: 60,
                            format: .number,
                            postFix: "s",
                            stepperAccessibilityID: "whiteTimePerMove")
            .onAppear {
                whiteMaxTime = config.whiteMaxTime
            }
            .onChange(of: whiteMaxTime) { _, newValue in
                // Route through ConfigEngineSync (like macOS / the board's name-label
                // toggle) so flipping White to/from Human here also reconfigures the
                // engine's human-SL state for analysis, not just the stored value.
                ConfigEngineSync.setWhiteMaxTime(newValue, config: config, gobanState: gobanState,
                                                 player: player, messageList: messageList)
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
                .onChange(of: useLLM) { _, _ in
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

                        messageList.appendAndSend(commands: GtpCommandBuilder.ruleCommandsBundle(
                            ko: config.koRuleText, scoring: config.scoringRuleText, tax: config.taxRuleText,
                            multiStoneSuicide: config.multiStoneSuicideLegal, hasButton: config.hasButton,
                            whiteHandicapBonus: config.whiteHandicapBonusRuleText))
                        messageList.appendAndSend(command: GtpCommandBuilder.komiCommand(config.komi))
                        messageList.appendAndSend(command: GtpCommandBuilder.playoutDoublingAdvantageCommand(config.playoutDoublingAdvantage))
                        messageList.appendAndSend(command: GtpCommandBuilder.analysisWideRootNoiseCommand(config.analysisWideRootNoise))
                        messageList.appendAndSend(commands: GtpCommandBuilder.symmetricHumanAnalysisCommands(
                            humanSLProfile: config.effectiveHumanProfileForBlack, humanProfileForWhite: config.effectiveHumanProfileForWhite,
                            humanRatioForBlack: config.humanRatioForBlack, humanRatioForWhite: config.humanRatioForWhite))
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
                RuleConfigView(
                    config: config,
                    maxBoardLength: maxBoardLength,
                    gameRecord: gameRecord
                )
                .navigationTitle("Rule")
            }

            NavigationLink("Analysis") {
                AnalysisConfigView(config: config)
                    .navigationTitle("Analysis")
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

struct GlobalSettingsView: View {
    @State private var soundEffect: Bool = false
    @State private var hapticFeedback: Bool = false
    @State private var showVisitsPerSecond: Bool = false
    @State private var stoneStyleText = Config.defaultStoneStyleText
    @State private var moveNumberStyleText = Config.defaultMoveNumberStyleText
    @State private var analysisStyleText = Config.defaultAnalysisStyleText
    @State private var analysisInformationText = Config.defaultAnalysisInformationText
    @State private var showCoordinate = Config.defaultShowCoordinate
    @State private var showPass = Config.defaultShowPass
    @State private var verticalFlip = Config.compatibleVerticalFlip
    @State private var showCharts = Config.defaultShowCharts
    @State private var showOwnership = Config.defaultShowOwnership
    @State private var showWinrateBar = Config.defaultShowWinrateBar
    @Environment(GobanState.self) private var gobanState

    var body: some View {
        List {
            Section("Board") {
                ConfigTextPicker(
                    title: "Stone style",
                    texts: Config.stoneStyles,
                    selectedText: $stoneStyleText
                )
                .onAppear {
                    stoneStyleText = gobanState.stoneStyleText
                }
                .onChange(of: stoneStyleText) { _, newValue in
                    gobanState.stoneStyle = Config.stoneStyles.firstIndex(of: newValue) ?? Config.defaultStoneStyle
                }

                ConfigTextPicker(
                    title: "Move numbers",
                    texts: Config.moveNumberStyles,
                    selectedText: $moveNumberStyleText
                )
                .onAppear {
                    moveNumberStyleText = gobanState.moveNumberStyleText
                }
                .onChange(of: moveNumberStyleText) { _, newValue in
                    gobanState.moveNumberStyle = Config.moveNumberStyles.firstIndex(of: newValue) ?? Config.defaultMoveNumberStyle
                }

                ConfigBoolItem(title: "Show coordinate", value: $showCoordinate)
                    .onAppear {
                        showCoordinate = gobanState.showCoordinate
                    }
                    .onChange(of: showCoordinate) {
                        gobanState.showCoordinate = showCoordinate
                    }

                ConfigBoolItem(title: "Show pass", value: $showPass)
                    .onAppear {
                        showPass = gobanState.showPass
                    }
                    .onChange(of: showPass) {
                        gobanState.showPass = showPass
                    }

                ConfigBoolItem(title: "Vertical flip", value: $verticalFlip)
                    .onAppear {
                        verticalFlip = gobanState.verticalFlip
                    }
                    .onChange(of: verticalFlip) {
                        gobanState.verticalFlip = verticalFlip
                    }

                ConfigBoolItem(title: "Show chart/comments", value: $showCharts)
                    .onAppear {
                        showCharts = gobanState.showCharts
                    }
                    .onChange(of: showCharts) {
                        gobanState.showCharts = showCharts
                    }
            }

            Section("Analysis") {
                ConfigTextPicker(
                    title: "Analysis information",
                    texts: Config.analysisInformations,
                    selectedText: $analysisInformationText
                )
                .onAppear {
                    analysisInformationText = gobanState.analysisInformationText
                }
                .onChange(of: analysisInformationText) { _, newValue in
                    gobanState.analysisInformation = Config.analysisInformations.firstIndex(of: newValue) ?? Config.defaultAnalysisInformation
                }

                ConfigTextPicker(
                    title: "Analysis style",
                    texts: Config.analysisStyles,
                    selectedText: $analysisStyleText
                )
                .onAppear {
                    analysisStyleText = gobanState.analysisStyleText
                }
                .onChange(of: analysisStyleText) { _, newValue in
                    gobanState.analysisStyle = Config.analysisStyles.firstIndex(of: newValue) ?? Config.defaultAnalysisStyle
                }

                ConfigBoolItem(title: "Show ownership", value: $showOwnership)
                    .onAppear {
                        showOwnership = gobanState.showOwnership
                    }
                    .onChange(of: showOwnership) {
                        gobanState.showOwnership = showOwnership
                    }

                ConfigBoolItem(title: "Show win rate bar", value: $showWinrateBar)
                    .onAppear {
                        showWinrateBar = gobanState.showWinrateBar
                    }
                    .onChange(of: showWinrateBar) {
                        withAnimation {
                            gobanState.showWinrateBar = showWinrateBar
                        }
                    }
            }

            Section("Sound & Haptics") {
                ConfigBoolItem(title: "Sound effect", value: $soundEffect)
                    .onAppear {
                        soundEffect = gobanState.soundEffect
                    }
                    .onChange(of: soundEffect) {
                        gobanState.soundEffect = soundEffect
                    }

                ConfigBoolItem(title: "Haptic feedback", value: $hapticFeedback)
                    .onAppear {
                        hapticFeedback = gobanState.hapticFeedback
                    }
                    .onChange(of: hapticFeedback) {
                        gobanState.hapticFeedback = hapticFeedback
                    }

                ConfigBoolItem(title: "Show visits/s", value: $showVisitsPerSecond)
                    .onAppear {
                        showVisitsPerSecond = gobanState.showVisitsPerSecond
                    }
                    .onChange(of: showVisitsPerSecond) {
                        gobanState.showVisitsPerSecond = showVisitsPerSecond
                    }
            }
        }
        .navigationTitle("Global Settings")
    }
}

struct GameSettingsView: View {
    var gameRecord: GameRecord
    var maxBoardLength: Int

    var body: some View {
        ConfigItems(gameRecord: gameRecord, maxBoardLength: maxBoardLength)
            .navigationTitle("Game Settings")
    }
}

struct ConfigView: View {
    var gameRecord: GameRecord
    var maxBoardLength: Int
    @Environment(TopUIState.self) private var topUIState

    var body: some View {
        List {
            NavigationLink("Global Settings") {
                GlobalSettingsView()
            }

            NavigationLink("Game Settings") {
                GameSettingsView(gameRecord: gameRecord, maxBoardLength: maxBoardLength)
            }

            // Model name + engine version, surfaced here now that the launch
            // screen no longer pauses to show them. Both are populated during
            // engine initialization (ContentView) and ride TopUIState in via
            // the environment.
            if topUIState.modelName != nil || topUIState.engineVersionDisplay != nil {
                Section("Engine") {
                    if let modelName = topUIState.modelName {
                        LabeledContent("Model", value: modelName)
                    }

                    if let version = topUIState.engineVersionDisplay {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Version")
                            Text(version)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            // Kept at the bottom: secondary, rarely-visited reference content.
            NavigationLink("Open-Source Licenses") {
                AcknowledgmentsView()
            }
        }
        .navigationTitle("Configurations")
    }
}
