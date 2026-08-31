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
    @State var rulesetText: String = NewGameRuleset.custom.displayName

    @Environment(MessageList.self) var messageList
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    @Environment(BoardSize.self) var board
    @Environment(Stones.self) var stones
    @Environment(BookLookup.self) var bookLookup

    var body: some View {
        List {
            // Board size is locked while a branch is active: the boardsize
            // command resets the engine to an empty board and the follow-up
            // printsgf would overwrite the branch with it, while the saved SGF
            // keeps the old size — destroying the branch and desyncing the
            // config from the record.
            //
            // It is also locked until the engine is in sync (`stones.isReady`).
            // The board itself never waits for the engine, but resizing does:
            // this editor's onDisappear sends `boardsize` + `printsgf`, and a
            // printsgf answered by an engine that has not been fed this game
            // would overwrite the record with the engine's idea of it.
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
                .disabled(gobanState.isBranchActive || !stones.isReady)

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
                .disabled(gobanState.isBranchActive || !stones.isReady)

            if gobanState.isBranchActive {
                Text("Board size can't be changed while a branch is active.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !stones.isReady {
                Text("Board size can't be changed until the engine is ready.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ConfigTextPicker(
                title: "Ruleset",
                texts: NewGameRuleset.pickerCases.map(\.displayName),
                selectedText: $rulesetText
            )
            .onAppear {
                rulesetText = matchedRuleset.displayName
            }
            .onChange(of: rulesetText) { _, newValue in
                guard let preset = NewGameRuleset.pickerCases.first(where: { $0.displayName == newValue }),
                      preset != .custom else { return }
                if NewGameRules.expand(preset) == currentComponents {
                    // The picker snapped here programmatically, or the user
                    // relabeled engine-identical rules (Japanese -> Korean):
                    // persist the label, leave knobs/komi/engine untouched.
                    // The equal-value guard keeps a plain sheet-open (the
                    // onAppear snap) from re-dirtying the synced record; a
                    // DIFFERING stale label is deliberately healed to match
                    // the actual knobs.
                    if config.rule != preset.configRuleIndex {
                        config.rule = preset.configRuleIndex
                    }
                    return
                }
                ConfigEngineSync.applyRuleset(preset, config: config, messageList: messageList)
                koRuleText = config.koRuleText
                scoringRuleText = config.scoringRuleText
                taxRuleText = config.taxRuleText
                multiStoneSuicideLegal = config.multiStoneSuicideLegal
                hasButton = config.hasButton
                whiteHandicapBonusRuleText = config.whiteHandicapBonusRuleText
                komi = config.komi
                komiText = String(config.komi)
                isRuleChanged = true
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
                // Equal to the config means this is the echo of a programmatic
                // @State refresh (preset apply / onAppear seeding), not an edit.
                guard koRule != config.koRule else { return }
                ConfigEngineSync.setKoRule(koRule, config: config, messageList: messageList)
                isRuleChanged = true
                refreshRulesetSelection()
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
                guard scoringRule != config.scoringRule else { return }
                ConfigEngineSync.setScoringRule(scoringRule, config: config, messageList: messageList)
                isRuleChanged = true
                refreshRulesetSelection()
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
                guard taxRule != config.taxRule else { return }
                ConfigEngineSync.setTaxRule(taxRule, config: config, messageList: messageList)
                isRuleChanged = true
                refreshRulesetSelection()
            }

            ConfigBoolItem(title: "Multi-stone suicide", value: $multiStoneSuicideLegal)
                .onAppear {
                    multiStoneSuicideLegal = config.multiStoneSuicideLegal
                }
                .onChange(of: multiStoneSuicideLegal) { _, newValue in
                    guard newValue != config.multiStoneSuicideLegal else { return }
                    ConfigEngineSync.setMultiStoneSuicideLegal(newValue, config: config, messageList: messageList)
                    isRuleChanged = true
                    refreshRulesetSelection()
                }

            ConfigBoolItem(title: "Has button", value: $hasButton)
                .onAppear {
                    hasButton = config.hasButton
                }
                .onChange(of: hasButton) { _, newValue in
                    guard newValue != config.hasButton else { return }
                    ConfigEngineSync.setHasButton(newValue, config: config, messageList: messageList)
                    isRuleChanged = true
                    refreshRulesetSelection()
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
                guard rule != config.whiteHandicapBonusRule else { return }
                ConfigEngineSync.setWhiteHandicapBonusRule(rule, config: config, messageList: messageList)
                isRuleChanged = true
                refreshRulesetSelection()
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
                // Clamp + half-point-round exactly as setKomi will, so the
                // echo of a programmatic refresh compares equal and is skipped.
                let newKomi = min(1_000, max(-1_000, ((Float(newValue) ?? Config.defaultKomi) * 2).rounded() / 2))
                guard newKomi != config.komi else { return }
                ConfigEngineSync.setKomi(newKomi, config: config, messageList: messageList)
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

                let bookAvailable = config.isBookEligible
                    && bookLookup.isAvailable(forBoardSize: config.boardWidth)

                if bookAvailable && gobanState.eyeStatus == .opened {
                    bookLookup.loadIfNeeded(boardSize: config.boardWidth)
                    gobanState.eyeStatus = .book
                }

                if !bookAvailable && gobanState.eyeStatus == .book {
                    gobanState.eyeStatus = .opened
                }
            }
        }
    }

    /// The six granular rule components currently persisted in the config.
    private var currentComponents: NewGameRuleComponents {
        NewGameRuleComponents(koRule: config.koRule,
                              scoringRule: config.scoringRule,
                              taxRule: config.taxRule,
                              multiStoneSuicideLegal: config.multiStoneSuicideLegal,
                              hasButton: config.hasButton,
                              whiteHandicapBonusRule: config.whiteHandicapBonusRule)
    }

    /// The named preset the current knobs correspond to (Custom when none).
    /// The persisted `config.rule` label only breaks ties between
    /// engine-identical presets (Japanese/Korean, AGA/BGA).
    private var matchedRuleset: NewGameRuleset {
        NewGameRules.match(currentComponents,
                           preferring: NewGameRuleset.preset(fromConfigRule: config.rule))
    }

    /// After a hand-edit of one granular knob: snap the Ruleset picker to the
    /// matching named preset (or Custom) and persist that label.
    private func refreshRulesetSelection() {
        let matched = matchedRuleset
        config.rule = matched.configRuleIndex
        rulesetText = matched.displayName
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
                    blackMaxTime = config.blackMaxTime   // seed for both stepper and toggle
                }
                .onChange(of: humanProfileForBlack) { _, newValue in
                    blackHumanSLModel.profile = newValue
                    ConfigEngineSync.setBlackHumanProfile(newValue, config: config, player: player, messageList: messageList)
                }

            if humanProfileForBlack == "AI" {
                ConfigFloatItem(title: "Time per move",
                                value: $blackMaxTime,
                                step: 0.5,
                                minValue: 0,
                                maxValue: 60,
                                format: .number,
                                postFix: "s",
                                stepperAccessibilityID: "blackTimePerMove")
                .onChange(of: blackMaxTime) { _, newValue in
                    ConfigEngineSync.setBlackMaxTime(newValue, config: config, gobanState: gobanState,
                                                     player: player, messageList: messageList)
                }
            } else {
                Toggle("Engine plays this side", isOn: Binding(
                    get: { blackMaxTime > 0 },
                    set: { isOn in
                        let newTime: Float = isOn ? Config.toggleAIThinkingTime : 0
                        blackMaxTime = newTime
                        ConfigEngineSync.setBlackMaxTime(newTime, config: config, gobanState: gobanState,
                                                         player: player, messageList: messageList)
                    }))
                .accessibilityIdentifier("blackEnginePlays")
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
                    whiteMaxTime = config.whiteMaxTime
                }
                .onChange(of: humanProfileForWhite) { _, newValue in
                    whiteHumanSLModel.profile = newValue
                    ConfigEngineSync.setWhiteHumanProfile(newValue, config: config, player: player, messageList: messageList)
                }

            if humanProfileForWhite == "AI" {
                ConfigFloatItem(title: "Time per move",
                                value: $whiteMaxTime,
                                step: 0.5,
                                minValue: 0,
                                maxValue: 60,
                                format: .number,
                                postFix: "s",
                                stepperAccessibilityID: "whiteTimePerMove")
                .onChange(of: whiteMaxTime) { _, newValue in
                    ConfigEngineSync.setWhiteMaxTime(newValue, config: config, gobanState: gobanState,
                                                     player: player, messageList: messageList)
                }
            } else {
                Toggle("Engine plays this side", isOn: Binding(
                    get: { whiteMaxTime > 0 },
                    set: { isOn in
                        let newTime: Float = isOn ? Config.toggleAIThinkingTime : 0
                        whiteMaxTime = newTime
                        ConfigEngineSync.setWhiteMaxTime(newTime, config: config, gobanState: gobanState,
                                                         player: player, messageList: messageList)
                    }))
                .accessibilityIdentifier("whiteEnginePlays")
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
    @Environment(GameSession.self) var session
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    @Environment(MessageList.self) var messageList
    @Environment(BoardSize.self) var board
    @Environment(Stones.self) var stones
    @Environment(Analysis.self) var analysis
    @Environment(BookLookup.self) var bookLookup

    var body: some View {
        List {
            // Read-only while a branch is active: onDisappear would write the
            // pasted SGF into the record and reload it, but the reload is
            // branch-aware and would put the BRANCH back on the board instead
            // of the pasted game, desyncing the board from the record until the
            // branch is deactivated.
            if gobanState.isBranchActive {
                Text("Deactivate the branch to edit the SGF.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            TextField("Paste your SGF text", text: $sgf, axis: .vertical)
                .disableAutocorrection(true)
#if !os(macOS)
                .textInputAutocapitalization(.never)
#endif
                .disabled(gobanState.isBranchActive)
                .onAppear {
                    sgf = gameRecord.sgf
                }
                .onDisappear {
                    if sgf != gameRecord.sgf {
                        // The pasted SGF becomes the record, and `loadGame`
                        // does the rest: it projects the new position onto the
                        // board at once and feeds the engine the whole opening
                        // bundle — board size, rules, komi, setup stones and
                        // one `play` per move. The hand-rolled loadsgf + rules
                        // + showboard + printsgf sequence that used to live
                        // here was a second, drifting copy of exactly that.
                        let config = gameRecord.concreteConfig
                        let sgfHelper = SgfOperations(sgf: sgf)
                        config.boardWidth = sgfHelper.xSize
                        config.boardHeight = sgfHelper.ySize
                        gameRecord.sgf = sgf
                        // Land on the pasted game's last move: a cursor left
                        // over from the previous SGF means nothing here.
                        gameRecord.currentIndex = sgfHelper.moveSize ?? 0
                        player.nextColorForPlayCommand = .unknown

                        gobanState.loadGame(gameRecord: gameRecord,
                                            player: player,
                                            bookLookup: bookLookup,
                                            messageList: messageList,
                                            board: board,
                                            stones: stones,
                                            analysis: analysis,
                                            projector: session.recordPosition)
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
    /// The board in front of the user, passed through to `VoiceControlHelpView`
    /// so its spoken examples name points that actually exist on it. Defaults
    /// cover the no-game-selected case (this screen is reachable from the game
    /// list with nothing open).
    var boardWidth: Int = Config.defaultBoardWidth
    var boardHeight: Int = Config.defaultBoardHeight
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
    @State private var thumbnailSizeText = Config.defaultThumbnailSizeText
    // Read straight from UserDefaults: the hold (`ScreenWakeHold`) reads the
    // same key, so there is no GobanState mirror to keep in step.
    @AppStorage(GlobalSettingsKeys.keepScreenAwake) private var keepScreenAwake = ScreenWakePolicy.defaultEnabled
    @Environment(GobanState.self) private var gobanState
    @Environment(TopUIState.self) private var topUIState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The newest saved game's name, shown inside the Siri phrases that take
    /// one. Fetched here, not in the shared view, so the screen stays
    /// injected data only; the picker fetch is newest-first and property-bounded.
    private var newestGameName: String? {
        try? GameRecord.fetchGameRecordsForPicker(container: modelContext.container,
                                                  fetchLimit: 1).first?.name
    }

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

            // Feedback 2026-08-31: "prevent the screen from turning off when a
            // stone is just played by AI for a few seconds". The hold itself
            // is `ScreenWakeHold` (iOS only, attached in GameSplitView); this
            // is its switch. Its own section rather than Analysis or Board:
            // those are about what is drawn, and a battery-affecting toggle
            // has to be findable by someone looking for a screen setting.
            Section {
                ConfigBoolItem(title: "Keep Screen Awake for AI Moves", value: $keepScreenAwake)
            } header: {
                Text("Power")
            } footer: {
                Text("While KataGo thinks, for a few seconds after it plays, and during auto-play.")
            }

            // Feedback 2026-07-30: with Voice Control on, "it is not clear
            // what commands are available". Sits here rather than under About
            // (described below as rarely-visited reference content) because the
            // complaint is discoverability — a Voice Control user has to be
            // able to find this, and "Tap Voice Control" has to reach it.
            Section("Accessibility") {
                NavigationLink {
                    VoiceControlHelpView(boardWidth: boardWidth,
                                         boardHeight: boardHeight)
                } label: {
                    Label("Voice Control", systemImage: "mic")
                }
                .accessibilityInputLabels(["Voice Control", "Voice Commands", "Voice Control Help"])
            }

            // The registered Siri phrases are invisible until spoken
            // correctly, so list them beside the other "how do I drive this
            // app by voice" screen above.
            Section("Siri") {
                NavigationLink {
                    SiriPhrasesHelpView(exampleGameName: newestGameName)
                } label: {
                    Label("Siri Phrases", systemImage: "waveform")
                }
                .accessibilityInputLabels(["Siri Phrases", "Siri"])
            }

            Section("Game List") {
                // Off is the degenerate size, not a second switch — one control
                // decides both whether the row draws a board and how big it is.
                // Off also stops the row RESOLVING one: the picture is replayed
                // from the game's SGF, so hiding it is what makes the list
                // cheap. It retires the row's `square.grid.3x3` unreadable-record
                // signal with it (ADR 0014), which lived in the picture slot.
                ConfigTextPicker(
                    title: "Thumbnails",
                    texts: Config.thumbnailSizes,
                    selectedText: $thumbnailSizeText
                )
                .onAppear {
                    thumbnailSizeText = gobanState.thumbnailSizeText
                }
                .onChange(of: thumbnailSizeText) { _, newValue in
                    withAnimation {
                        gobanState.thumbnailSize = Config.thumbnailSizes.firstIndex(of: newValue) ?? Config.defaultThumbnailSize
                    }
                }
            }

            // Model name + engine version, surfaced app-wide here (relocated
            // from the per-game Settings screen — they never depended on the
            // selected game). Both are mirrored from the engine handshake onto
            // TopUIState, which rides in via the environment.
            //
            // Tapping either row used to QUIT the engine, behind a destructive
            // confirmation, because returning to the model picker meant tearing
            // the board down. The picker is a sheet over a board that never
            // goes away, so the action is simply "Change model": no dialog, and
            // nothing is destroyed. The Model row renders even when no engine
            // is running (Absent) — that is precisely when the user most needs
            // a way into the picker.
            Section("Engine") {
                LabeledContent("Model", value: topUIState.modelName ?? "None")
                    .contentShape(Rectangle())
                    .onTapGesture { requestModelPicker() }
                    // Stable handle the UI suites tap to reach the picker.
                    .accessibilityIdentifier("GlobalSettingsView.changeModelRow")
                    // The tap gesture is invisible to Voice Control/VoiceOver;
                    // expose the row as a button with a speakable name.
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { requestModelPicker() }
                    .accessibilityInputLabels(["Change Model", "Model"])

                if let version = topUIState.engineVersionDisplay {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version")
                        Text(version)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { requestModelPicker() }
                    // See the Model row above.
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { requestModelPicker() }
                    .accessibilityInputLabels(["Change Model", "Version"])
                }

                NavigationLink {
                    CommandView()
                        .navigationTitle("Developer Mode")
                } label: {
                    Label("Developer Mode", systemImage: "doc.plaintext")
                }
            }

            // Secondary, rarely-visited reference content.
            Section("About") {
                NavigationLink("Open-Source Licenses") {
                    AcknowledgmentsView()
                }
            }
        }
        .navigationTitle("Global Settings")
    }

    /// Ask for the model picker, then get out of its way.
    ///
    /// The picker is presented by the app root, above this sheet — and
    /// presenting a sheet in the same transaction that dismisses another one
    /// gets DROPPED. So this only flags intent; the settings sheet's own
    /// `onDismiss` (in `PlusMenuView`) raises the picker once this screen has
    /// actually gone. Same present-after-dismiss hop `GameSplitView` uses
    /// between the camera cover and the photo-import sheet.
    private func requestModelPicker() {
        topUIState.requestingModelPicker = true
        dismiss()
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
