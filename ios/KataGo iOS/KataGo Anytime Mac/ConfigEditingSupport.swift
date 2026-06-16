//
//  ConfigEditingSupport.swift
//  KataGo Anytime Mac
//
//  Phase 4 Task 5: reusable infrastructure for the native AppKit config editors.
//  Two pieces, both designed so P4-T6 (the full "Edit…" sheet) can reuse them
//  verbatim:
//
//    1. `ConfigEngineSync` — a `@MainActor enum` of static funcs that, given a
//       changed `Config` field, replays the SAME GTP command(s) the iOS
//       `ConfigView` sends, so the engine and on-disk SGF stay in sync. The map
//       is verified against `KataGo iOS/ConfigView.swift` +
//       `KataGoUICore/.../ConfigModel.swift` (the exact iOS lines are quoted at
//       each func).
//
//    2. `ConfigFormBuilder` — native form-row builders (`NSTextField`+`NSStepper`
//       numeric rows, `NSPopUpButton` enum rows, `NSButton` checkbox rows) that
//       return ready-to-stack labeled rows. The Info tab and T6's sheet both
//       build their forms from these.
//
//  No SwiftData @Model schema change: every accessor used here already exists on
//  `Config` (stored props + computed accessors). Board size is intentionally NOT
//  handled by `ConfigEngineSync` — changing it mid-game replays a destructive
//  command sequence (`rectangular_boardsize` + showboard + printsgf) that the
//  Info tab defers to T6; the Info tab shows board size read-only.
//

import AppKit
import KataGoUICore

// MARK: - ConfigEngineSync

/// Replays the GTP command(s) iOS's `ConfigView` sends for each editable
/// `Config` field. Callers mutate the `Config` property FIRST (or pass the new
/// value to the helper, which mutates it), then call the matching static func so
/// the engine receives the same command(s) the iOS `.onChange` handlers send.
///
/// All funcs are `@MainActor` (they touch `MessageList`/`GobanState`, both
/// main-actor-isolated through `GameSession`). Each func is a thin, named wrapper
/// over a single `Config` accessor + `appendAndSend`, so T6 can reuse them.
@MainActor
enum ConfigEngineSync {

    // MARK: Komi
    //
    // iOS `ConfigView.swift` lines 291-294 (`RuleConfigView`):
    //   config.komi = min(1_000, max(-1_000, ((Float(newValue) ?? defaultKomi) * 2).rounded() / 2))
    //   messageList.appendAndSend(command: config.getKataKomiCommand())
    // We clamp + half-point-round the same way, write `config.komi`, then send.

    /// Sets `config.komi` (clamped to ±1000, rounded to the nearest 0.5 exactly
    /// as iOS) and replays `komi <value>`.
    static func setKomi(_ newValue: Float, config: Config, messageList: MessageList) {
        config.komi = min(1_000, max(-1_000, (newValue * 2).rounded() / 2))
        messageList.appendAndSend(command: config.getKataKomiCommand())
    }

    // MARK: Ko rule
    //
    // iOS `ConfigView.swift` lines 211-215:
    //   config.koRule = KoRule(rawValue: rawValue) ?? .simple
    //   messageList.appendAndSend(command: config.koRuleCommand)

    /// Sets `config.koRule` and replays `kata-set-rule ko <TEXT>`.
    static func setKoRule(_ koRule: KoRule, config: Config, messageList: MessageList) {
        config.koRule = koRule
        messageList.appendAndSend(command: config.koRuleCommand)
    }

    // MARK: Scoring rule
    //
    // iOS `ConfigView.swift` lines 226-229:
    //   config.scoringRule = ScoringRule(rawValue: rawValue) ?? .area
    //   messageList.appendAndSend(command: config.scoringRuleCommand)

    /// Sets `config.scoringRule` and replays `kata-set-rule scoring <TEXT>`.
    static func setScoringRule(_ scoringRule: ScoringRule, config: Config, messageList: MessageList) {
        config.scoringRule = scoringRule
        messageList.appendAndSend(command: config.scoringRuleCommand)
    }

    // MARK: Tax rule
    //
    // iOS `ConfigView.swift` lines 241-244:
    //   config.taxRule = TaxRule(rawValue: rawValue) ?? .none
    //   messageList.appendAndSend(command: config.taxRuleCommand)

    /// Sets `config.taxRule` and replays `kata-set-rule tax <TEXT>`.
    static func setTaxRule(_ taxRule: TaxRule, config: Config, messageList: MessageList) {
        config.taxRule = taxRule
        messageList.appendAndSend(command: config.taxRuleCommand)
    }

    // MARK: Multi-stone suicide
    //
    // iOS `ConfigView.swift` lines 252-254 (`RuleConfigView`):
    //   config.multiStoneSuicideLegal = newValue
    //   messageList.appendAndSend(command: config.multiStoneSuicideLegalCommand)

    /// Sets `config.multiStoneSuicideLegal` and replays
    /// `kata-set-rule suicide <bool>`.
    static func setMultiStoneSuicideLegal(_ isOn: Bool, config: Config, messageList: MessageList) {
        config.multiStoneSuicideLegal = isOn
        messageList.appendAndSend(command: config.multiStoneSuicideLegalCommand)
    }

    // MARK: Has button
    //
    // iOS `ConfigView.swift` lines 262-264 (`RuleConfigView`):
    //   config.hasButton = newValue
    //   messageList.appendAndSend(command: config.hasButtonCommand)

    /// Sets `config.hasButton` and replays `kata-set-rule hasButton <bool>`.
    static func setHasButton(_ isOn: Bool, config: Config, messageList: MessageList) {
        config.hasButton = isOn
        messageList.appendAndSend(command: config.hasButtonCommand)
    }

    // MARK: White handicap bonus
    //
    // iOS `ConfigView.swift` lines 276-280 (`RuleConfigView`):
    //   config.whiteHandicapBonusRule = WhiteHandicapBonusRule(rawValue: rawValue) ?? .zero
    //   messageList.appendAndSend(command: config.whiteHandicapBonusRuleCommand)
    // The picker index maps 1:1 onto `WhiteHandicapBonusRule.rawValue`
    // (both index `Config.whiteHandicapBonusRules`).

    /// Sets `config.whiteHandicapBonusRule` and replays
    /// `kata-set-rule whiteHandicapBonus <TEXT>`.
    static func setWhiteHandicapBonusRule(_ rule: WhiteHandicapBonusRule,
                                          config: Config,
                                          messageList: MessageList) {
        config.whiteHandicapBonusRule = rule
        messageList.appendAndSend(command: config.whiteHandicapBonusRuleCommand)
    }

    // MARK: Playout doubling advantage (White advantage)
    //
    // iOS `ConfigView.swift` lines 427-429 (`AIConfigView`):
    //   config.playoutDoublingAdvantage = newValue
    //   messageList.appendAndSend(command: config.getKataPlayoutDoublingAdvantageCommand())

    /// Sets `config.playoutDoublingAdvantage` and replays
    /// `kata-set-param playoutDoublingAdvantage <value>`.
    static func setPlayoutDoublingAdvantage(_ newValue: Float, config: Config, messageList: MessageList) {
        config.playoutDoublingAdvantage = newValue
        messageList.appendAndSend(command: config.getKataPlayoutDoublingAdvantageCommand())
    }

    // MARK: Analysis wide root noise
    //
    // iOS `ConfigView.swift` lines 380-382 (`AnalysisConfigView`):
    //   config.analysisWideRootNoise = min(1, max(0, Float(newValue) ?? default))
    //   messageList.appendAndSend(command: config.getKataAnalysisWideRootNoiseCommand())

    /// Sets `config.analysisWideRootNoise` (clamped 0...1 as iOS) and replays
    /// `kata-set-param analysisWideRootNoise <value>`.
    static func setAnalysisWideRootNoise(_ newValue: Float, config: Config, messageList: MessageList) {
        config.analysisWideRootNoise = min(1, max(0, newValue))
        messageList.appendAndSend(command: config.getKataAnalysisWideRootNoiseCommand())
    }

    // MARK: Human-SL profiles (per color)
    //
    // iOS `ConfigView.swift` lines 442-447 (Black) and 474-479 (White):
    //   Black: config.humanSLProfile = newValue; blackHumanSLModel.profile = newValue
    //          if player.nextColorForPlayCommand != .white {
    //              messageList.appendAndSend(commands: blackHumanSLModel.commands) }
    //   White: config.humanProfileForWhite = newValue; whiteHumanSLModel.profile = newValue
    //          if player.nextColorForPlayCommand != .black {
    //              messageList.appendAndSend(commands: whiteHumanSLModel.commands) }
    // The per-color GTP send is gated on whose turn is NOT next (so the running
    // engine isn't reconfigured mid-think for the color about to move), exactly
    // as iOS does.

    /// Sets Black's human-SL profile (`config.humanProfileForBlack`) and, when
    /// the next color to play is NOT white, replays that profile's
    /// `HumanSLModel.commands` (mirrors iOS `ConfigView` lines 442-447).
    static func setBlackHumanProfile(_ profile: String,
                                     config: Config,
                                     player: Turn,
                                     messageList: MessageList) {
        config.humanProfileForBlack = profile
        if player.nextColorForPlayCommand != .white,
           let model = HumanSLModel(profile: profile) {
            messageList.appendAndSend(commands: model.commands)
        }
    }

    /// Sets White's human-SL profile (`config.humanProfileForWhite`) and, when
    /// the next color to play is NOT black, replays that profile's
    /// `HumanSLModel.commands` (mirrors iOS `ConfigView` lines 474-479).
    static func setWhiteHumanProfile(_ profile: String,
                                     config: Config,
                                     player: Turn,
                                     messageList: MessageList) {
        config.humanProfileForWhite = profile
        if player.nextColorForPlayCommand != .black,
           let model = HumanSLModel(profile: profile) {
            messageList.appendAndSend(commands: model.commands)
        }
    }

    // MARK: Per-color max time
    //
    // iOS `ConfigView.swift` lines 460-461 (Black) / 492-493 (White): no GTP
    // command — the property alone is read when `getKataGenMoveAnalyzeCommands`
    // runs (`GobanState.getRequestAnalysisCommands`). So these only write the
    // `Config` prop.
    //
    // On iOS the change takes effect on the next color toggle (the hosted
    // `BoardView.onChange(of: player.nextColorForPlayCommand)` re-evaluates
    // `getRequestAnalysisCommands` → issues the gen-move). But ENABLING an AI
    // color MID-GAME (`maxTime` 0 → >0 with no color change) doesn't toggle the
    // color, so nothing re-evaluates and no gen-move is issued until the next
    // move. We therefore RE-ARM analysis after writing the value (same as
    // `setMaxAnalysisMoves`/`setAnalysisInterval`): if it's now that color's
    // turn, `getRequestAnalysisCommands` returns the gen-move set and the engine
    // generates immediately. `rearmAnalysis` no-ops when analysis is cleared /
    // not for the current player, so disabling (>0 → 0) is harmless.

    /// Sets Black's per-move max time (`config.blackMaxTime` →
    /// `optionalBlackMaxTime`) and re-arms analysis so enabling Black mid-game
    /// (0 → >0) issues the gen-move now when it's Black's turn.
    static func setBlackMaxTime(_ seconds: Float,
                                config: Config,
                                gobanState: GobanState,
                                player: Turn,
                                messageList: MessageList) {
        config.blackMaxTime = seconds
        rearmAnalysis(config: config, gobanState: gobanState, player: player, messageList: messageList)
    }

    /// Sets White's per-move max time (`config.whiteMaxTime` →
    /// `optionalWhiteMaxTime`) and re-arms analysis so enabling White mid-game
    /// (0 → >0) issues the gen-move now when it's White's turn.
    static func setWhiteMaxTime(_ seconds: Float,
                                config: Config,
                                gobanState: GobanState,
                                player: Turn,
                                messageList: MessageList) {
        config.whiteMaxTime = seconds
        rearmAnalysis(config: config, gobanState: gobanState, player: player, messageList: messageList)
    }

    // MARK: Analysis params (no dedicated GTP command)
    //
    // iOS `ConfigView.swift` lines 356-358 (`analysisForWhom`), 389-391
    // (`maxAnalysisMoves`), 397-399 (`analysisInterval`): each only sets the
    // `Config` property — there is NO dedicated GTP command; they are read when
    // analysis is next requested (`getKataAnalyzeCommand`/`getKataFastAnalyzeCommand`
    // embed `analysisInterval` + `maxAnalysisMoves`). After changing
    // `maxAnalysisMoves`/`analysisInterval` we MAY re-arm so the change takes
    // effect immediately, mirroring how iOS re-requests analysis downstream.

    /// Sets `config.analysisForWhom`. No GTP command (gates which player's
    /// positions get analyzed on the next request).
    static func setAnalysisForWhom(_ index: Int, config: Config) {
        config.analysisForWhom = index
    }

    /// Sets `config.maxAnalysisMoves` and re-arms analysis so the new `maxmoves`
    /// is sent immediately (the value is embedded in the next `kata-analyze`).
    static func setMaxAnalysisMoves(_ value: Int,
                                    config: Config,
                                    gobanState: GobanState,
                                    player: Turn,
                                    messageList: MessageList) {
        config.maxAnalysisMoves = value
        rearmAnalysis(config: config, gobanState: gobanState, player: player, messageList: messageList)
    }

    /// Sets `config.analysisInterval` and re-arms analysis so the new `interval`
    /// is sent immediately (the value is embedded in the next `kata-analyze`).
    static func setAnalysisInterval(_ value: Int,
                                    config: Config,
                                    gobanState: GobanState,
                                    player: Turn,
                                    messageList: MessageList) {
        config.analysisInterval = value
        rearmAnalysis(config: config, gobanState: gobanState, player: player, messageList: messageList)
    }

    /// Re-issues a continuous-analysis (or gen-move) request for the current
    /// position so a just-changed parameter (interval / maxmoves / per-color
    /// maxTime) is applied now. `getRequestAnalysisCommands` re-reads the config,
    /// so when a color was just enabled and it's that color's turn this issues
    /// the gen-move set (`kata-search_analyze_cancellable`); otherwise it
    /// re-issues `kata-analyze`. Uses the same gate iOS relies on downstream
    /// (`maybeRequestAnalysis`): it no-ops when analysis is cleared or not for
    /// the current player.
    private static func rearmAnalysis(config: Config,
                                      gobanState: GobanState,
                                      player: Turn,
                                      messageList: MessageList) {
        gobanState.maybeRequestAnalysis(
            config: config,
            nextColorForPlayCommand: player.nextColorForPlayCommand,
            messageList: messageList
        )
    }
}

// MARK: - ConfigFormBuilder

/// Builds native AppKit form rows (a leading label + a trailing editable
/// control) for the config editors. Each builder returns an `NSView` row whose
/// control already has its target/action wired to the supplied closure; the
/// closure performs the `Config` write + `ConfigEngineSync` call.
///
/// Rows are plain `NSStackView`s laid out leading-label / trailing-control; a
/// caller stacks them vertically (the Info tab uses a vertical `NSStackView`).
/// The builders retain their action closures via small `NSObject` "target"
/// boxes stored on the control through associated handlers — implemented here
/// with a dedicated `ActionTarget` so Swift 6 strict concurrency stays clean
/// (no escaping `@Sendable` requirements; everything is `@MainActor`).
@MainActor
enum ConfigFormBuilder {

    /// Standard leading label width so every row's controls align.
    static let labelWidth: CGFloat = 150

    // MARK: Numeric row (NSTextField + NSStepper)

    /// A labeled numeric row: an editable `NSTextField` mirrored by an
    /// `NSStepper`. Both commit through `onChange(newValue)`. `format` renders
    /// the field text; `decimals` controls the stepper's increment precision.
    ///
    /// Returns the row view; the live value is owned by the caller's `Config`,
    /// so the builder seeds the controls from `value` and reports edits via
    /// `onChange`. The returned `NumericRow` exposes `reload(value:)` so the
    /// owner can repopulate it when the selected game changes.
    static func numericRow(title: String,
                           value: Double,
                           minValue: Double,
                           maxValue: Double,
                           step: Double,
                           format: @escaping (Double) -> String,
                           onChange: @escaping (Double) -> Void) -> NumericRow {
        NumericRow(title: title,
                   value: value,
                   minValue: minValue,
                   maxValue: maxValue,
                   step: step,
                   format: format,
                   onChange: onChange)
    }

    // MARK: Popup row (NSPopUpButton)

    /// A labeled enumeration row backed by an `NSPopUpButton`. `options` are the
    /// human-readable titles; `selectedIndex` is the initially-selected item;
    /// `onChange(index)` fires with the newly-selected index.
    static func popupRow(title: String,
                         options: [String],
                         selectedIndex: Int,
                         onChange: @escaping (Int) -> Void) -> PopupRow {
        PopupRow(title: title,
                 options: options,
                 selectedIndex: selectedIndex,
                 onChange: onChange)
    }

    // MARK: Checkbox row (NSButton .switch)

    /// A labeled boolean row backed by a checkbox `NSButton`. `onChange(isOn)`
    /// fires with the new state. (Not used by the Info tab's common settings,
    /// which have no booleans, but provided for T6's full editor — multi-stone
    /// suicide, has-button, use-LLM, etc.)
    static func checkboxRow(title: String,
                            isOn: Bool,
                            onChange: @escaping (Bool) -> Void) -> CheckboxRow {
        CheckboxRow(title: title, isOn: isOn, onChange: onChange)
    }

    // MARK: Read-only row

    /// A labeled read-only row: a leading label and a trailing static value
    /// label. Used for the summary fields and for board size (read-only here).
    static func readOnlyRow(title: String, value: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [titleLabel, valueLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    /// A section header label (small, secondary, uppercased) for grouping rows.
    static func sectionHeader(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = NSFont.preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        return label
    }
}

// MARK: - Row types
//
// Each row is an `NSStackView` subclass that OWNS its controls + action closure
// (so the closure outlives the builder call) and exposes `reload(...)` so the
// Info tab can repopulate the row when the selected game changes WITHOUT
// rebuilding the whole form. All are `@MainActor` (they only touch AppKit).

/// Labeled numeric row: `NSTextField` ⟷ `NSStepper`, both committing the same
/// value through `onChange`.
@MainActor
final class NumericRow: NSStackView {
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let format: (Double) -> String
    private let onChange: (Double) -> Void
    private let step: Double

    init(title: String,
         value: Double,
         minValue: Double,
         maxValue: Double,
         step: Double,
         format: @escaping (Double) -> String,
         onChange: @escaping (Double) -> Void) {
        self.format = format
        self.onChange = onChange
        self.step = step
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: ConfigFormBuilder.labelWidth).isActive = true

        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        field.target = self
        field.action = #selector(fieldChanged)

        stepper.minValue = minValue
        stepper.maxValue = maxValue
        stepper.increment = step
        stepper.valueWraps = false
        stepper.translatesAutoresizingMaskIntoConstraints = false
        stepper.target = self
        stepper.action = #selector(stepperChanged)

        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        addArrangedSubview(titleLabel)
        addArrangedSubview(NSView())  // flexible spacer
        addArrangedSubview(field)
        addArrangedSubview(stepper)

        reload(value: value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Repopulates both controls from `value` without firing `onChange`.
    func reload(value: Double) {
        stepper.doubleValue = value
        field.stringValue = format(value)
    }

    private func commit(_ value: Double) {
        let clamped = min(stepper.maxValue, max(stepper.minValue, value))
        stepper.doubleValue = clamped
        field.stringValue = format(clamped)
        onChange(clamped)
    }

    @objc private func stepperChanged() {
        commit(stepper.doubleValue)
    }

    @objc private func fieldChanged() {
        // Parse the typed text; fall back to the stepper's current value if the
        // text isn't a number (mirrors iOS's `Float(newValue) ?? default` guard,
        // here keeping the prior value rather than a compiled default).
        let parsed = Double(field.stringValue) ?? stepper.doubleValue
        commit(parsed)
    }
}

/// Labeled enumeration row backed by an `NSPopUpButton`.
@MainActor
final class PopupRow: NSStackView {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let onChange: (Int) -> Void

    init(title: String,
         options: [String],
         selectedIndex: Int,
         onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: ConfigFormBuilder.labelWidth).isActive = true

        popup.addItems(withTitles: options)
        popup.target = self
        popup.action = #selector(popupChanged)
        popup.translatesAutoresizingMaskIntoConstraints = false

        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        addArrangedSubview(titleLabel)
        addArrangedSubview(NSView())  // flexible spacer
        addArrangedSubview(popup)

        reload(options: options, selectedIndex: selectedIndex)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Repopulates the menu + selection without firing `onChange`. Re-adding the
    /// items keeps the popup correct even if the option list ever changes.
    func reload(options: [String], selectedIndex: Int) {
        popup.removeAllItems()
        popup.addItems(withTitles: options)
        if options.indices.contains(selectedIndex) {
            popup.selectItem(at: selectedIndex)
        }
    }

    /// Convenience reload when only the selection changed.
    func reload(selectedIndex: Int) {
        if popup.itemArray.indices.contains(selectedIndex) {
            popup.selectItem(at: selectedIndex)
        }
    }

    @objc private func popupChanged() {
        onChange(popup.indexOfSelectedItem)
    }
}

/// Labeled boolean row backed by a checkbox `NSButton`.
@MainActor
final class CheckboxRow: NSStackView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let onChange: (Bool) -> Void

    init(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: ConfigFormBuilder.labelWidth).isActive = true

        checkbox.title = ""
        checkbox.target = self
        checkbox.action = #selector(checkboxChanged)
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        addArrangedSubview(titleLabel)
        addArrangedSubview(NSView())  // flexible spacer
        addArrangedSubview(checkbox)

        reload(isOn: isOn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Repopulates the checkbox state without firing `onChange`.
    func reload(isOn: Bool) {
        checkbox.state = isOn ? .on : .off
    }

    @objc private func checkboxChanged() {
        onChange(checkbox.state == .on)
    }
}
