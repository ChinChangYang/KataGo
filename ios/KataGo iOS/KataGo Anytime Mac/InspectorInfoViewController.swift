//
//  InspectorInfoViewController.swift
//  KataGo Anytime Mac
//
//  Phase 4 Task 5: the Inspector "Info" tab as a NATIVE AppKit
//  `NSViewController`. Replaces the `PlaceholderViewController(labelText:
//  "Info (Phase 4)")` the `InspectorViewController` used to host.
//
//  Two regions, top to bottom inside a scroll view:
//
//    • SUMMARY (read-only): game name, last-modified date, board W×H, komi +
//      ko/scoring/tax rule text, and the SGF-parsed player names (PB / PW),
//      result (RE) and handicap (HA). The player/result/handicap fields are NOT
//      first-class `GameRecord` properties, so they are extracted from
//      `gameRecord.sgf` with a small regex (`SgfHelper` has no PB/PW/RE getters).
//
//    • COMMON SETTINGS (editable inline, native controls): komi, ko/scoring/tax
//      rule, per-color human-SL profile + per-color max time, and the analysis
//      params (max analysis moves / interval / analysis-for-whom). Each edit
//      writes the `Config` prop AND replays the same GTP command(s) iOS sends —
//      routed through `ConfigEngineSync` so the engine + SGF stay in sync.
//      Board size is shown READ-ONLY (mid-game board-size changes are deferred
//      to T6's full editor).
//
//    • An "Edit…" button at the bottom is a stubbed `@objc` no-op for now;
//      P4-T6 will present the full native config editor from it.
//
//  The form rebuilds from the live `concreteConfig` in `viewWillAppear` and
//  whenever `navigationContext.selectedGameRecord` changes (observed via the
//  same self-rescheduling `withObservationTracking` pattern
//  `MainWindowController` uses).
//
//  Reuses `ConfigEditingSupport.swift`'s `ConfigEngineSync` + `ConfigFormBuilder`
//  — the same infrastructure P4-T6 will build its sheet from.
//

import AppKit
import KataGoUICore

@MainActor
final class InspectorInfoViewController: NSViewController {
    private let session: GameSession
    private let navigationContext: NavigationContext

    // Engine collaborators borrowed from the session (mirrors how the other
    // tabs/observers reach them). `messageList` carries the replayed GTP;
    // `gobanState`/`player` are needed to re-arm analysis after an analysis-param
    // edit and to gate the per-color human-profile sends.
    private var messageList: MessageList { session.messageList }
    private var gobanState: GobanState { session.gobanState }
    private var player: Turn { session.player }

    /// Vertical stack that holds every row; rebuilt by `rebuildForm()`.
    private let formStack = NSStackView()

    /// Snapshot of the selected game's identity so the
    /// `withObservationTracking` callback can tell when it actually changed
    /// (the observer is property-agnostic). Seeded in `viewDidLoad`.
    private var lastSelectedGame: GameRecord?

    init(session: GameSession, navigationContext: NavigationContext) {
        self.session = session
        self.navigationContext = navigationContext
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

        // A document-scrolling NSScrollView so long forms fit the narrow
        // inspector. The form stack is the document view, pinned to the clip
        // view's width so rows lay out across the full inspector width.
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(formStack)
        scrollView.documentView = documentView

        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // Document view tracks the scroll view's content (clip) width so the
            // form is not horizontally scrollable and rows fill the width.
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            formStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 16),
            formStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            formStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            formStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -16),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        lastSelectedGame = navigationContext.selectedGameRecord
        trackSelectedGame()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Always rebuild from the live config when the tab is shown: cheap, and
        // guarantees the form reflects any change made while the tab was hidden.
        rebuildForm()
    }

    // MARK: - Selected-game observation
    //
    // The selected game can switch from the Library sidebar (or a new/import).
    // Rebuild the whole form on the `selectedGameRecord` identity change, using
    // the same one-shot self-rescheduling `withObservationTracking` bridge
    // `MainWindowController` uses: the apply closure touches the tracked
    // property; `onChange` hops to `Task { @MainActor }`, reacts, and re-arms.

    private func trackSelectedGame() {
        withObservationTracking {
            _ = navigationContext.selectedGameRecord
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleSelectedGameChange()
                self.trackSelectedGame()
            }
        }
    }

    private func handleSelectedGameChange() {
        let current = navigationContext.selectedGameRecord
        guard current !== lastSelectedGame else { return }
        lastSelectedGame = current
        rebuildForm()
    }

    // MARK: - Form construction

    private func rebuildForm() {
        // Tear down the previous rows.
        for subview in formStack.arrangedSubviews {
            formStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        guard let gameRecord = navigationContext.selectedGameRecord else {
            formStack.addArrangedSubview(
                ConfigFormBuilder.readOnlyRow(title: "", value: "No game selected"))
            return
        }

        let config = gameRecord.concreteConfig
        let parsed = SgfGameInfo(sgf: gameRecord.sgf)

        addSummarySection(gameRecord: gameRecord, config: config, parsed: parsed)
        addSeparator()
        addRuleSection(config: config)
        addSeparator()
        addAISection(config: config)
        addSeparator()
        addAnalysisSection(config: config)
        addSeparator()
        addEditButton()
    }

    // MARK: Summary (read-only)

    private func addSummarySection(gameRecord: GameRecord, config: Config, parsed: SgfGameInfo) {
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Summary"))

        formStack.addArrangedSubview(
            ConfigFormBuilder.readOnlyRow(title: "Name", value: gameRecord.name))

        formStack.addArrangedSubview(
            ConfigFormBuilder.readOnlyRow(title: "Modified", value: Self.dateText(gameRecord.lastModificationDate)))

        formStack.addArrangedSubview(
            ConfigFormBuilder.readOnlyRow(title: "Board size",
                                          value: "\(config.boardWidth) × \(config.boardHeight)"))

        formStack.addArrangedSubview(
            ConfigFormBuilder.readOnlyRow(title: "Komi", value: Self.komiText(config.komi)))

        formStack.addArrangedSubview(
            ConfigFormBuilder.readOnlyRow(
                title: "Rules",
                value: "\(config.koRuleText) · \(config.scoringRuleText) · \(config.taxRuleText)"))

        if let black = parsed.blackPlayer, !black.isEmpty {
            formStack.addArrangedSubview(
                ConfigFormBuilder.readOnlyRow(title: "Black (PB)", value: black))
        }
        if let white = parsed.whitePlayer, !white.isEmpty {
            formStack.addArrangedSubview(
                ConfigFormBuilder.readOnlyRow(title: "White (PW)", value: white))
        }
        if let result = parsed.result, !result.isEmpty {
            formStack.addArrangedSubview(
                ConfigFormBuilder.readOnlyRow(title: "Result (RE)", value: result))
        }
        if let handicap = parsed.handicap, !handicap.isEmpty {
            formStack.addArrangedSubview(
                ConfigFormBuilder.readOnlyRow(title: "Handicap (HA)", value: handicap))
        }
    }

    // MARK: Rule (editable: komi + ko/scoring/tax)

    private func addRuleSection(config: Config) {
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Rules"))

        formStack.addArrangedSubview(
            ConfigFormBuilder.numericRow(
                title: "Komi",
                value: Double(config.komi),
                minValue: -1_000,
                maxValue: 1_000,
                step: 0.5,
                format: { Self.komiText(Float($0)) },
                onChange: { [weak self] newValue in
                    guard let self else { return }
                    ConfigEngineSync.setKomi(Float(newValue), config: config, messageList: self.messageList)
                }))

        formStack.addArrangedSubview(
            ConfigFormBuilder.popupRow(
                title: "Ko rule",
                options: Config.koRules,
                selectedIndex: config.koRule.rawValue,
                onChange: { [weak self] index in
                    guard let self else { return }
                    let koRule = KoRule(rawValue: index) ?? .simple
                    ConfigEngineSync.setKoRule(koRule, config: config, messageList: self.messageList)
                }))

        formStack.addArrangedSubview(
            ConfigFormBuilder.popupRow(
                title: "Scoring rule",
                options: Config.scoringRules,
                selectedIndex: config.scoringRule.rawValue,
                onChange: { [weak self] index in
                    guard let self else { return }
                    let scoringRule = ScoringRule(rawValue: index) ?? .area
                    ConfigEngineSync.setScoringRule(scoringRule, config: config, messageList: self.messageList)
                }))

        formStack.addArrangedSubview(
            ConfigFormBuilder.popupRow(
                title: "Tax rule",
                options: Config.taxRules,
                selectedIndex: config.taxRule.rawValue,
                onChange: { [weak self] index in
                    guard let self else { return }
                    let taxRule = TaxRule(rawValue: index) ?? .none
                    ConfigEngineSync.setTaxRule(taxRule, config: config, messageList: self.messageList)
                }))
    }

    // MARK: AI opponents (editable: per-color human profile + max time)

    private func addAISection(config: Config) {
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("AI Opponents"))

        // Black
        formStack.addArrangedSubview(
            ConfigFormBuilder.popupRow(
                title: "Black profile",
                options: HumanSLModel.allProfiles,
                selectedIndex: HumanSLModel.allProfiles.firstIndex(of: config.humanProfileForBlack) ?? 0,
                onChange: { [weak self] index in
                    guard let self else { return }
                    let profile = HumanSLModel.allProfiles[index]
                    ConfigEngineSync.setBlackHumanProfile(profile, config: config,
                                                          player: self.player, messageList: self.messageList)
                }))

        formStack.addArrangedSubview(
            ConfigFormBuilder.numericRow(
                title: "Black time/move",
                value: Double(config.blackMaxTime),
                minValue: 0,
                maxValue: 60,
                step: 0.5,
                format: { Self.secondsText(Float($0)) },
                onChange: { newValue in
                    ConfigEngineSync.setBlackMaxTime(Float(newValue), config: config)
                }))

        // White
        formStack.addArrangedSubview(
            ConfigFormBuilder.popupRow(
                title: "White profile",
                options: HumanSLModel.allProfiles,
                selectedIndex: HumanSLModel.allProfiles.firstIndex(of: config.humanProfileForWhite) ?? 0,
                onChange: { [weak self] index in
                    guard let self else { return }
                    let profile = HumanSLModel.allProfiles[index]
                    ConfigEngineSync.setWhiteHumanProfile(profile, config: config,
                                                          player: self.player, messageList: self.messageList)
                }))

        formStack.addArrangedSubview(
            ConfigFormBuilder.numericRow(
                title: "White time/move",
                value: Double(config.whiteMaxTime),
                minValue: 0,
                maxValue: 60,
                step: 0.5,
                format: { Self.secondsText(Float($0)) },
                onChange: { newValue in
                    ConfigEngineSync.setWhiteMaxTime(Float(newValue), config: config)
                }))
    }

    // MARK: Analysis (editable: max moves / interval / for-whom)

    private func addAnalysisSection(config: Config) {
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
    }

    // MARK: Edit button (stub for P4-T6)

    private func addEditButton() {
        let button = NSButton(title: "Edit…", target: self, action: #selector(presentFullEditor(_:)))
        button.bezelStyle = .rounded
        formStack.addArrangedSubview(button)
    }

    /// Stub: P4-T6 fills this in with the full native config editor sheet.
    // TODO(P4-T6): present full native config editor
    @objc private func presentFullEditor(_ sender: Any?) {
        // Intentionally a no-op until P4-T6.
    }

    // MARK: - Helpers

    private func addSeparator() {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        formStack.addArrangedSubview(separator)
        // The separator should span the form width.
        separator.leadingAnchor.constraint(equalTo: formStack.leadingAnchor).isActive = true
        separator.trailingAnchor.constraint(equalTo: formStack.trailingAnchor).isActive = true
    }

    private static func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Renders komi as iOS does (`Float` shown without trailing noise).
    private static func komiText(_ komi: Float) -> String {
        // Half-point values are common (7.5); show one decimal when fractional,
        // else an integer, mirroring the way iOS surfaces komi.
        if komi == komi.rounded() {
            return String(Int(komi))
        }
        return String(format: "%g", komi)
    }

    private static func secondsText(_ seconds: Float) -> String {
        if seconds == seconds.rounded() {
            return "\(Int(seconds))s"
        }
        return String(format: "%gs", seconds)
    }
}

// MARK: - SgfGameInfo
//
// `SgfHelper` exposes board size + rules + moves/comments, but NOT the PB / PW /
// RE / HA header properties the summary wants. Rather than touch the C++ bridge,
// pull them straight from the SGF root node with a tiny regex over `PROP[VALUE]`
// pairs. SGF properties are uppercase letters followed by one or more
// bracketed values; we read the FIRST value of each requested property in the
// root node (good enough for these single-value headers).
private struct SgfGameInfo {
    let blackPlayer: String?
    let whitePlayer: String?
    let result: String?
    let handicap: String?

    init(sgf: String) {
        blackPlayer = Self.firstProperty("PB", in: sgf)
        whitePlayer = Self.firstProperty("PW", in: sgf)
        result = Self.firstProperty("RE", in: sgf)
        // Only surface a handicap when it's a positive count (HA[0] means none).
        if let ha = Self.firstProperty("HA", in: sgf), let count = Int(ha), count > 0 {
            handicap = String(count)
        } else {
            handicap = nil
        }
    }

    /// Returns the first bracketed value of `property` (e.g. `PB`) in `sgf`, or
    /// nil if absent. Matches `PROP` only when it is NOT preceded by another
    /// uppercase letter, so `PB` doesn't accidentally match inside a longer
    /// token. The value capture stops at the first unescaped `]`.
    private static func firstProperty(_ property: String, in sgf: String) -> String? {
        // (?<![A-Z]) — not preceded by an uppercase letter (property boundary).
        // \[([^\]]*)\] — the first bracketed value (no nested ']').
        let pattern = "(?<![A-Z])" + property + "\\[([^\\]]*)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(sgf.startIndex..<sgf.endIndex, in: sgf)
        guard let match = regex.firstMatch(in: sgf, range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: sgf) else {
            return nil
        }
        let value = String(sgf[valueRange])
        return value.isEmpty ? nil : value
    }
}
