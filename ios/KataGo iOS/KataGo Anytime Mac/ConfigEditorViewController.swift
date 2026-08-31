//
//  ConfigEditorViewController.swift
//  KataGo Anytime Mac
//
//  Phase 4 Task 6: the full per-game config "Edit…" sheet as a NATIVE AppKit
//  `NSViewController`, presented from the Info tab's bottom "Edit…" button
//  (`InspectorInfoViewController.presentFullEditor`).
//
//  It mirrors iOS's `ConfigView` sub-screens (Rule / Analysis / AI / Comment),
//  grouped here into one scrollable form:
//
//    • Game    — Name (editable, prop-only) + Board size (READ-ONLY: mid-game
//                resize is destructive and deferred).
//    • Rules   — Komi, Ko, Scoring, Tax (reused from the Info tab) PLUS
//                Multi-stone suicide, Has button, White handicap bonus.
//    • Analysis— Max analysis moves, Analysis interval, Analysis for whom
//                (reused) PLUS Analysis wide root noise and Hidden analysis
//                visit ratio (prop-only).
//    • AI      — per-color human profile + time/move (reused) PLUS Playout
//                doubling advantage and Human-SL root explore prob (prop-only).
//    • Comment — Tone, Temperature, Apple Intelligence (all prop-only).
//
//  Every row commits LIVE through `ConfigEngineSync` (the same infrastructure the
//  Info tab uses), so there is no separate "apply" step — "Done" just closes.
//  Edits write the `Config` property (persisted by SwiftData) and, where the iOS
//  `ConfigView` sends a GTP command, replay the SAME command so the engine and
//  on-disk SGF stay in sync. Fields marked "prop-only" below send NO GTP (their
//  value is read on the next analysis/gen-move request, or only by the on-device
//  commentary path) — exactly as iOS handles them.
//
//  Reuses `ConfigEditingSupport.swift`'s `ConfigEngineSync` + `ConfigFormBuilder`
//  + the `NumericRow`/`PopupRow`/`CheckboxRow`/`readOnlyRow`/`sectionHeader`
//  helpers verbatim — no row/replay logic is duplicated here. The one editor-only
//  control is `EditorTextFieldRow` (a labeled free-text `NSTextField` for the
//  game name); the shared builder has no text row because the Info tab needs none.
//
//  No SwiftData @Model schema change: every accessor used here already exists on
//  `Config`/`GameRecord` (stored props + computed accessors). Board size is shown
//  read-only.
//

import AppKit
import KataGoUICore

@MainActor
final class ConfigEditorViewController: NSViewController {
    private let session: GameSession
    private let gameRecord: GameRecord

    // Engine collaborators, reached the same way `InspectorInfoViewController`
    // does: `messageList` carries the replayed GTP; `gobanState`/`player` are
    // needed to re-arm analysis after an analysis-param edit and to gate the
    // per-color human-profile sends.
    private var messageList: MessageList { session.messageList }
    private var gobanState: GobanState { session.gobanState }
    private var player: Turn { session.player }

    /// Live config for the edited game (SwiftData-persisted; source of truth).
    private var config: Config { gameRecord.concreteConfig }

    /// Vertical stack holding every row; built once in `loadView`.
    private let formStack = NSStackView()

    // Rules rows kept for programmatic repopulation when a Ruleset preset is
    // picked (mirrors NewGameViewController's preset <-> granular sync).
    // `reload(...)` never re-fires `onChange`, so there is no feedback loop.
    private var rulesetRow: PopupRow!
    private var komiRow: NumericRow!
    private var koRow: PopupRow!
    private var scoringRow: PopupRow!
    private var taxRow: PopupRow!
    private var suicideRow: CheckboxRow!
    private var buttonRow: CheckboxRow!
    private var whbRow: PopupRow!

    init(session: GameSession, gameRecord: GameRecord) {
        self.session = session
        self.gameRecord = gameRecord
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - View

    override func loadView() {
        let container = NSView()

        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 8
        formStack.translatesAutoresizingMaskIntoConstraints = false

        // Document-scrolling NSScrollView so the long form fits the sheet; the
        // form stack is the document view, pinned to the clip view's width so
        // rows lay out across the full width (mirrors InspectorInfoViewController).
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(formStack)
        scrollView.documentView = documentView

        // A bottom "Done" bar pinned beneath the scroll view.
        let doneButton = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"  // Return triggers Done.
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(doneButton)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 560),

            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            doneButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            doneButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            doneButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            // Document view tracks the scroll view's content (clip) width so the
            // form is not horizontally scrollable and rows fill the width.
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            formStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 16),
            formStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            formStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            formStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -16),
        ])

        view = container
        buildForm()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        title = "Edit Game"
    }

    // MARK: - Form construction

    private func rebuildForm() {
        for subview in formStack.arrangedSubviews {
            formStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        buildForm()
    }

    private func buildForm() {
        addGameSection()
        ConfigFormBuilder.addSeparator(to: formStack)
        addRuleSection()
        ConfigFormBuilder.addSeparator(to: formStack)
        addAnalysisSection()
        ConfigFormBuilder.addSeparator(to: formStack)
        addAISection()
        ConfigFormBuilder.addSeparator(to: formStack)
        addCommentSection()
    }

    // MARK: Game (Name editable; board size read-only)

    private func addGameSection() {
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Game"))

        formStack.addArrangedSubview(
            EditorTextFieldRow(
                title: "Name",
                value: gameRecord.name,
                onChange: { [weak self] newValue in
                    // Prop-only: no GTP. Persisted by SwiftData.
                    self?.gameRecord.name = newValue
                }))

        // Board size is READ-ONLY here: a mid-game resize replays a destructive
        // command sequence (deferred). Mirrors the Info tab's read-only display.
        formStack.addArrangedSubview(
            ConfigFormBuilder.readOnlyRow(
                title: "Board size",
                value: "\(config.boardWidth) × \(config.boardHeight)"))
    }

    // MARK: Rules

    private func addRuleSection() {
        let config = self.config
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Rules"))

        rulesetRow = ConfigFormBuilder.popupRow(
            title: "Ruleset",
            options: NewGameRuleset.pickerCases.map(\.displayName),
            selectedIndex: NewGameRuleset.pickerCases.firstIndex(of: matchedRuleset()) ?? 0,
            onChange: { [weak self] index in self?.rulesetChanged(index) })
        formStack.addArrangedSubview(rulesetRow)

        komiRow = ConfigFormBuilder.numericRow(
            title: "Komi",
            value: Double(config.komi),
            minValue: -1_000,
            maxValue: 1_000,
            step: 0.5,
            format: { Config.komiText(Float($0)) },
            onChange: { [weak self] newValue in
                guard let self else { return }
                ConfigEngineSync.setKomi(Float(newValue), config: config, messageList: self.messageList)
            })
        formStack.addArrangedSubview(komiRow)

        koRow = ConfigFormBuilder.popupRow(
            title: "Ko rule",
            options: Config.koRules,
            selectedIndex: config.koRule.rawValue,
            onChange: { [weak self] index in
                guard let self else { return }
                let koRule = KoRule(rawValue: index) ?? .simple
                ConfigEngineSync.setKoRule(koRule, config: config, messageList: self.messageList)
                self.granularRuleChanged()
            })
        formStack.addArrangedSubview(koRow)

        scoringRow = ConfigFormBuilder.popupRow(
            title: "Scoring rule",
            options: Config.scoringRules,
            selectedIndex: config.scoringRule.rawValue,
            onChange: { [weak self] index in
                guard let self else { return }
                let scoringRule = ScoringRule(rawValue: index) ?? .area
                ConfigEngineSync.setScoringRule(scoringRule, config: config, messageList: self.messageList)
                self.granularRuleChanged()
            })
        formStack.addArrangedSubview(scoringRow)

        taxRow = ConfigFormBuilder.popupRow(
            title: "Tax rule",
            options: Config.taxRules,
            selectedIndex: config.taxRule.rawValue,
            onChange: { [weak self] index in
                guard let self else { return }
                let taxRule = TaxRule(rawValue: index) ?? .none
                ConfigEngineSync.setTaxRule(taxRule, config: config, messageList: self.messageList)
                self.granularRuleChanged()
            })
        formStack.addArrangedSubview(taxRow)

        suicideRow = ConfigFormBuilder.checkboxRow(
            title: "Multi-stone suicide",
            isOn: config.multiStoneSuicideLegal,
            onChange: { [weak self] isOn in
                guard let self else { return }
                ConfigEngineSync.setMultiStoneSuicideLegal(isOn, config: config, messageList: self.messageList)
                self.granularRuleChanged()
            })
        formStack.addArrangedSubview(suicideRow)

        buttonRow = ConfigFormBuilder.checkboxRow(
            title: "Has button",
            isOn: config.hasButton,
            onChange: { [weak self] isOn in
                guard let self else { return }
                ConfigEngineSync.setHasButton(isOn, config: config, messageList: self.messageList)
                self.granularRuleChanged()
            })
        formStack.addArrangedSubview(buttonRow)

        whbRow = ConfigFormBuilder.popupRow(
            title: "White handicap bonus",
            options: Config.whiteHandicapBonusRules,
            selectedIndex: config.whiteHandicapBonusRule.rawValue,
            onChange: { [weak self] index in
                guard let self else { return }
                let rule = WhiteHandicapBonusRule(rawValue: index) ?? .zero
                ConfigEngineSync.setWhiteHandicapBonusRule(rule, config: config, messageList: self.messageList)
                self.granularRuleChanged()
            })
        formStack.addArrangedSubview(whbRow)
    }

    // MARK: Ruleset preset <-> granular sync

    /// The six granular rule components currently persisted in the config.
    private func currentComponents() -> NewGameRuleComponents {
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
    private func matchedRuleset() -> NewGameRuleset {
        NewGameRules.match(currentComponents(),
                           preferring: NewGameRuleset.preset(fromConfigRule: config.rule))
    }

    /// A named preset was chosen: apply it live (six kata-set-rule + komi via
    /// ConfigEngineSync.applyRuleset) and repopulate the granular rows.
    /// Selecting "Custom" is a display-state no-op, matching the New Game
    /// dialog and the iOS sheet. Relabeling engine-identical rules
    /// (Japanese -> Korean) persists the label without touching the engine or
    /// a hand-edited komi; an explicit re-pick of the already-matching preset
    /// — which AppKit reports, unlike SwiftUI — falls through to a full apply
    /// so it restores the preset's default komi.
    private func rulesetChanged(_ index: Int) {
        guard NewGameRuleset.pickerCases.indices.contains(index) else { return }
        let chosen = NewGameRuleset.pickerCases[index]
        guard chosen != .custom else { return }
        if chosen != matchedRuleset(), NewGameRules.expand(chosen) == currentComponents() {
            if config.rule != chosen.configRuleIndex {
                config.rule = chosen.configRuleIndex
            }
            return
        }
        ConfigEngineSync.applyRuleset(chosen, config: config, messageList: messageList)
        koRow.reload(selectedIndex: config.koRule.rawValue)
        scoringRow.reload(selectedIndex: config.scoringRule.rawValue)
        taxRow.reload(selectedIndex: config.taxRule.rawValue)
        suicideRow.reload(isOn: config.multiStoneSuicideLegal)
        buttonRow.reload(isOn: config.hasButton)
        whbRow.reload(selectedIndex: config.whiteHandicapBonusRule.rawValue)
        komiRow.reload(value: Double(config.komi))
    }

    /// A granular rule was hand-edited: re-derive the matching preset, snap
    /// the Ruleset popup, and persist the label (Custom sentinel when none
    /// match).
    private func granularRuleChanged() {
        let matched = matchedRuleset()
        config.rule = matched.configRuleIndex
        rulesetRow.reload(selectedIndex: NewGameRuleset.pickerCases.firstIndex(of: matched) ?? 0)
    }

    // MARK: Analysis

    private func addAnalysisSection() {
        let config = self.config
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Analysis"))

        formStack.addArrangedSubview(
            ConfigFormBuilder.numericRow(
                title: "Max analysis moves",
                value: Double(config.maxAnalysisMoves),
                minValue: 1,
                maxValue: 1_000,
                step: 1,
                format: { String(Int($0)) },
                onChange: { [weak self] newValue in
                    guard let self else { return }
                    ConfigEngineSync.setMaxAnalysisMoves(Int(newValue), config: config,
                                                         gobanState: self.gobanState,
                                                         player: self.player,
                                                         messageList: self.messageList)
                }))

        formStack.addArrangedSubview(
            ConfigFormBuilder.numericRow(
                title: "Analysis interval",
                value: Double(config.analysisInterval),
                minValue: 10,
                maxValue: 300,
                step: 10,
                format: { String(Int($0)) },
                onChange: { [weak self] newValue in
                    guard let self else { return }
                    ConfigEngineSync.setAnalysisInterval(Int(newValue), config: config,
                                                         gobanState: self.gobanState,
                                                         player: self.player,
                                                         messageList: self.messageList)
                }))

        formStack.addArrangedSubview(
            ConfigFormBuilder.popupRow(
                title: "Analysis for",
                options: Config.analysisForWhoms,
                selectedIndex: config.analysisForWhom,
                onChange: { index in
                    ConfigEngineSync.setAnalysisForWhom(index, config: config)
                }))

        formStack.addArrangedSubview(
            ConfigFormBuilder.numericRow(
                title: "Wide root noise",
                value: Double(config.analysisWideRootNoise),
                minValue: 0,
                maxValue: 1,
                step: 0.01,
                format: { Self.ratioText(Float($0)) },
                onChange: { [weak self] newValue in
                    guard let self else { return }
                    ConfigEngineSync.setAnalysisWideRootNoise(Float(newValue), config: config,
                                                              messageList: self.messageList)
                }))

        // Prop-only (no GTP): read by AnalysisView when filtering hidden moves.
        formStack.addArrangedSubview(
            ConfigFormBuilder.numericRow(
                title: "Hidden visit ratio",
                value: Double(config.hiddenAnalysisVisitRatio),
                minValue: 0,
                maxValue: 1,
                step: 0.01,
                format: { Self.ratioText(Float($0)) },
                onChange: { newValue in
                    config.hiddenAnalysisVisitRatio = min(1, max(0, Float(newValue)))
                }))
    }

    // MARK: AI

    private func addAISection() {
        let config = self.config
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("AI"))

        // Playout doubling advantage ("White advantage" on iOS).
        formStack.addArrangedSubview(
            ConfigFormBuilder.numericRow(
                title: "White advantage",
                value: Double(config.playoutDoublingAdvantage),
                minValue: -3,
                maxValue: 3,
                step: 0.25,
                format: { String(format: "%g", $0) },
                onChange: { [weak self] newValue in
                    guard let self else { return }
                    ConfigEngineSync.setPlayoutDoublingAdvantage(Float(newValue), config: config,
                                                                 messageList: self.messageList)
                }))

        // Prop-only (no GTP): the per-color human-SL ratio is NOT part of
        // `HumanSLModel.commands` (that sends `humanSLRootExploreProbWeightLESS`).
        // iOS keeps it config-only; surface it for parity. Mirrors black/white.
        formStack.addArrangedSubview(
            ConfigFormBuilder.numericRow(
                title: "Human SL root ratio",
                value: Double(config.humanSLRootExploreProbWeightful),
                minValue: 0,
                maxValue: 1,
                step: 0.01,
                format: { Self.ratioText(Float($0)) },
                onChange: { newValue in
                    config.humanSLRootExploreProbWeightful = min(1, max(0, Float(newValue)))
                }))

        // Black
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Black AI"))

        formStack.addArrangedSubview(
            ConfigFormBuilder.rankMenuRow(
                title: "Human profile",
                current: HumanSLModel.canonicalProfile(config.humanProfileForBlack),
                onChange: { [weak self] profile in
                    guard let self else { return }
                    ConfigEngineSync.setBlackHumanProfile(profile, config: config,
                                                          player: self.player, messageList: self.messageList)
                    // Defer the rebuild so the popup's own action completes before
                    // its row is torn down.
                    DispatchQueue.main.async { [weak self] in self?.rebuildForm() }
                }))

        if HumanSLModel.canonicalProfile(config.humanProfileForBlack) == "AI" {
            formStack.addArrangedSubview(
                ConfigFormBuilder.numericRow(
                    title: "Time per move",
                    value: Double(config.blackMaxTime),
                    minValue: 0,
                    maxValue: 60,
                    step: 0.5,
                    format: { Config.secondsText(Float($0)) },
                    onChange: { [weak self] newValue in
                        guard let self else { return }
                        ConfigEngineSync.setBlackMaxTime(Float(newValue), config: config,
                                                         gobanState: self.gobanState,
                                                         player: self.player,
                                                         messageList: self.messageList)
                    }))
        } else {
            formStack.addArrangedSubview(
                ConfigFormBuilder.checkboxRow(
                    title: "Engine plays this side",
                    isOn: config.blackMaxTime > 0,
                    onChange: { [weak self] isOn in
                        guard let self else { return }
                        let newTime: Float = isOn ? Config.toggleAIThinkingTime : 0
                        ConfigEngineSync.setBlackMaxTime(newTime, config: config,
                                                         gobanState: self.gobanState,
                                                         player: self.player,
                                                         messageList: self.messageList)
                    }))
        }

        // White
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("White AI"))

        formStack.addArrangedSubview(
            ConfigFormBuilder.rankMenuRow(
                title: "Human profile",
                current: HumanSLModel.canonicalProfile(config.humanProfileForWhite),
                onChange: { [weak self] profile in
                    guard let self else { return }
                    ConfigEngineSync.setWhiteHumanProfile(profile, config: config,
                                                          player: self.player, messageList: self.messageList)
                    // Defer the rebuild so the popup's own action completes before
                    // its row is torn down.
                    DispatchQueue.main.async { [weak self] in self?.rebuildForm() }
                }))

        if HumanSLModel.canonicalProfile(config.humanProfileForWhite) == "AI" {
            formStack.addArrangedSubview(
                ConfigFormBuilder.numericRow(
                    title: "Time per move",
                    value: Double(config.whiteMaxTime),
                    minValue: 0,
                    maxValue: 60,
                    step: 0.5,
                    format: { Config.secondsText(Float($0)) },
                    onChange: { [weak self] newValue in
                        guard let self else { return }
                        ConfigEngineSync.setWhiteMaxTime(Float(newValue), config: config,
                                                         gobanState: self.gobanState,
                                                         player: self.player,
                                                         messageList: self.messageList)
                    }))
        } else {
            formStack.addArrangedSubview(
                ConfigFormBuilder.checkboxRow(
                    title: "Engine plays this side",
                    isOn: config.whiteMaxTime > 0,
                    onChange: { [weak self] isOn in
                        guard let self else { return }
                        let newTime: Float = isOn ? Config.toggleAIThinkingTime : 0
                        ConfigEngineSync.setWhiteMaxTime(newTime, config: config,
                                                         gobanState: self.gobanState,
                                                         player: self.player,
                                                         messageList: self.messageList)
                    }))
        }
    }

    // MARK: Comment (all prop-only — no GTP)

    private func addCommentSection() {
        let config = self.config
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Comment"))

        formStack.addArrangedSubview(
            ConfigFormBuilder.popupRow(
                title: "Tone",
                options: Config.tones,
                selectedIndex: config.tone.rawValue,
                onChange: { index in
                    // Prop-only: read by the on-device commentary path.
                    config.tone = CommentTone(rawValue: index) ?? .technical
                }))

        formStack.addArrangedSubview(
            ConfigFormBuilder.numericRow(
                title: "Temperature",
                value: Double(config.temperature),
                minValue: 0,
                maxValue: 1,
                step: 0.1,
                format: { String(format: "%g", (($0 * 10).rounded() / 10)) },
                onChange: { newValue in
                    // Prop-only: rounded to 0.1 exactly as iOS.
                    config.temperature = (Float(newValue) * 10).rounded() / 10
                }))

        formStack.addArrangedSubview(
            ConfigFormBuilder.checkboxRow(
                title: "Apple Intelligence",
                isOn: config.useLLM,
                onChange: { isOn in
                    // Prop-only: gates whether commentary is generated.
                    config.useLLM = isOn
                }))
    }

    // MARK: - Done

    @objc private func done(_ sender: Any?) {
        if let presenting = presentingViewController {
            presenting.dismiss(self)
        } else {
            dismiss(self)
        }
    }

    // MARK: - Helpers

    /// Renders a 0...1 ratio compactly (trailing zeros trimmed).
    private static func ratioText(_ value: Float) -> String {
        String(format: "%g", value)
    }
}

// MARK: - EditorTextFieldRow
//
// A labeled free-text row (leading label + trailing editable `NSTextField`) used
// only by the editor for the game name. The shared `ConfigFormBuilder` has no
// text-field row because the Info tab needs none; this keeps that builder lean
// while still matching its row layout/label width so the form stays aligned.

@MainActor
final class EditorTextFieldRow: NSStackView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let onChange: (String) -> Void

    init(title: String, value: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: ConfigFormBuilder.labelWidth).isActive = true

        field.stringValue = value
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.target = self
        field.action = #selector(commit)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        addArrangedSubview(titleLabel)
        addArrangedSubview(field)
        // Let the field expand to fill the trailing space.
        field.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // Commit on each keystroke so the name persists live (consistent with the
    // editor's "every row commits live" model — Done just closes).
    func controlTextDidChange(_ obj: Notification) {
        onChange(field.stringValue)
    }

    @objc private func commit() {
        onChange(field.stringValue)
    }
}
