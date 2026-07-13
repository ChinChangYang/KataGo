//
//  NewGameViewController.swift
//  KataGo Anytime Mac
//
//  The "New Game" setup sheet: lets the user choose Name, Board size, Komi, and
//  Rules before a game is created (File ▸ New Game / ⌘N and the toolbar New
//  button). A native AppKit `NSViewController` that reuses `ConfigFormBuilder`'s
//  rows (the same infrastructure as `ConfigEditorViewController`) and, on
//  Create, hands an SGF + name back to `MainWindowController.newGame` through the
//  `onCreate` closure — it does NOT touch the engine or the store itself.
//
//  Rules are offered two ways at once (per the product decision): a named-ruleset
//  popup that fills the granular controls, and the granular controls themselves,
//  which flip the popup to "Custom" when hand-edited. All rule handling goes
//  through `NewGameRules` (shared, unit-tested) so the dialog never re-implements
//  the engine's rule mapping. Board size is capped to `maxBoardLength` — the size
//  the running engine was launched with — because an oversized board fatally
//  aborts the engine on first analysis.
//

import AppKit
import KataGoUICore

@MainActor
final class NewGameViewController: NSViewController {
    /// The largest board the running engine can handle (its launched NN-buffer
    /// size). Board-size options never exceed this.
    private let maxBoardLength: Int
    /// Called once, on Create, with the SGF (encoding size/komi/rules) and name.
    private let onCreate: (_ sgf: String, _ name: String) -> Void

    // Collected values (kept in sync by the row callbacks).
    private var gameName = GameRecord.defaultName
    private var boardWidth: Int
    private var boardHeight: Int
    private var komi: Float = 7.5
    private var preset: NewGameRuleset = .chinese
    private var components: NewGameRuleComponents

    // Rows that need programmatic repopulation when preset ⇄ granular sync.
    private var rulesetRow: PopupRow!
    private var komiRow: NumericRow!
    private var koRow: PopupRow!
    private var scoringRow: PopupRow!
    private var taxRow: PopupRow!
    private var whbRow: PopupRow!
    private var suicideRow: CheckboxRow!
    private var buttonRow: CheckboxRow!
    private var widthRow: NumericRow!
    private var heightRow: NumericRow!

    /// Standard sizes offered as one-tap presets (only those that fit the engine).
    private let boardPresets: [Int]

    private let formStack = NSStackView()

    init(maxBoardLength: Int, onCreate: @escaping (_ sgf: String, _ name: String) -> Void) {
        self.maxBoardLength = max(2, maxBoardLength)
        self.onCreate = onCreate
        self.boardPresets = [9, 13, 19].filter { $0 <= max(2, maxBoardLength) }
        // Default board: 19 if it fits, else the largest fitting preset, else the cap.
        let defaultSize = boardPresets.last ?? max(2, maxBoardLength)
        self.boardWidth = defaultSize
        self.boardHeight = defaultSize
        self.components = NewGameRules.expand(.chinese)
            ?? NewGameRuleComponents(koRule: .simple, scoringRule: .area, taxRule: .none,
                                     multiStoneSuicideLegal: false, hasButton: false,
                                     whiteHandicapBonusRule: .n)
        super.init(nibName: nil, bundle: nil)
        self.komi = NewGameRules.suggestedKomi(components)
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

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(formStack)
        scrollView.documentView = documentView

        // Bottom bar: Cancel + Create (Create is the default, Cancel is Escape).
        let createButton = NSButton(title: "Create", target: self, action: #selector(create(_:)))
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(cancelButton)
        container.addSubview(createButton)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 460),

            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            createButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            createButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            createButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            cancelButton.centerYAnchor.constraint(equalTo: createButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: createButton.leadingAnchor, constant: -12),

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
        title = "New Game"
    }

    // MARK: - Form construction

    private func buildForm() {
        addGameSection()
        addSeparator()
        addBoardSection()
        addSeparator()
        addRuleSection()
    }

    private func addGameSection() {
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Game"))
        formStack.addArrangedSubview(
            EditorTextFieldRow(title: "Name", value: gameName, onChange: { [weak self] newValue in
                self?.gameName = newValue
            }))
    }

    private func addBoardSection() {
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Board"))

        let options = boardPresets.map { "\($0) × \($0)" } + ["Custom…"]
        let selectedIndex = boardPresets.firstIndex(of: boardWidth) ?? boardPresets.count
        formStack.addArrangedSubview(
            ConfigFormBuilder.popupRow(title: "Board size", options: options, selectedIndex: selectedIndex,
                                       onChange: { [weak self] index in self?.boardSizeChanged(index) }))

        widthRow = ConfigFormBuilder.numericRow(
            title: "Width", value: Double(boardWidth), minValue: 2, maxValue: Double(maxBoardLength),
            step: 1, format: { String(Int($0)) },
            onChange: { [weak self] value in self?.boardWidth = Int(value) })
        heightRow = ConfigFormBuilder.numericRow(
            title: "Height", value: Double(boardHeight), minValue: 2, maxValue: Double(maxBoardLength),
            step: 1, format: { String(Int($0)) },
            onChange: { [weak self] value in self?.boardHeight = Int(value) })
        formStack.addArrangedSubview(widthRow)
        formStack.addArrangedSubview(heightRow)

        // Custom rows are visible only when "Custom…" is the selection.
        let isCustom = selectedIndex == boardPresets.count
        widthRow.isHidden = !isCustom
        heightRow.isHidden = !isCustom
    }

    private func addRuleSection() {
        formStack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Rules"))

        rulesetRow = ConfigFormBuilder.popupRow(
            title: "Ruleset",
            options: NewGameRuleset.pickerCases.map(\.displayName),
            selectedIndex: NewGameRuleset.pickerCases.firstIndex(of: preset) ?? 0,
            onChange: { [weak self] index in self?.rulesetChanged(index) })
        formStack.addArrangedSubview(rulesetRow)

        komiRow = ConfigFormBuilder.numericRow(
            title: "Komi", value: Double(komi), minValue: -1_000, maxValue: 1_000, step: 0.5,
            format: { Self.komiText(Float($0)) },
            onChange: { [weak self] value in self?.komi = Float(value) })
        formStack.addArrangedSubview(komiRow)

        koRow = ConfigFormBuilder.popupRow(
            title: "Ko rule", options: Config.koRules, selectedIndex: components.koRule.rawValue,
            onChange: { [weak self] index in
                self?.components.koRule = KoRule(rawValue: index) ?? .simple
                self?.granularChanged()
            })
        formStack.addArrangedSubview(koRow)

        scoringRow = ConfigFormBuilder.popupRow(
            title: "Scoring rule", options: Config.scoringRules, selectedIndex: components.scoringRule.rawValue,
            onChange: { [weak self] index in
                self?.components.scoringRule = ScoringRule(rawValue: index) ?? .area
                self?.granularChanged()
            })
        formStack.addArrangedSubview(scoringRow)

        taxRow = ConfigFormBuilder.popupRow(
            title: "Tax rule", options: Config.taxRules, selectedIndex: components.taxRule.rawValue,
            onChange: { [weak self] index in
                self?.components.taxRule = TaxRule(rawValue: index) ?? .none
                self?.granularChanged()
            })
        formStack.addArrangedSubview(taxRow)

        whbRow = ConfigFormBuilder.popupRow(
            title: "White handicap bonus", options: NewGameRules.whiteHandicapBonusLabels,
            selectedIndex: components.whiteHandicapBonusRule.rawValue,
            onChange: { [weak self] index in
                self?.components.whiteHandicapBonusRule = WhiteHandicapBonusRule(rawValue: index) ?? .zero
                self?.granularChanged()
            })
        formStack.addArrangedSubview(whbRow)

        suicideRow = ConfigFormBuilder.checkboxRow(
            title: "Multi-stone suicide", isOn: components.multiStoneSuicideLegal,
            onChange: { [weak self] isOn in
                self?.components.multiStoneSuicideLegal = isOn
                self?.granularChanged()
            })
        formStack.addArrangedSubview(suicideRow)

        buttonRow = ConfigFormBuilder.checkboxRow(
            title: "Has button", isOn: components.hasButton,
            onChange: { [weak self] isOn in
                self?.components.hasButton = isOn
                self?.granularChanged()
            })
        formStack.addArrangedSubview(buttonRow)
    }

    // MARK: - Sync

    private func boardSizeChanged(_ index: Int) {
        if boardPresets.indices.contains(index) {
            let size = boardPresets[index]
            boardWidth = size
            boardHeight = size
            widthRow.isHidden = true
            heightRow.isHidden = true
        } else {
            // "Custom…": reveal width/height, seeded from the current size.
            widthRow.reload(value: Double(boardWidth))
            heightRow.reload(value: Double(boardHeight))
            widthRow.isHidden = false
            heightRow.isHidden = false
        }
    }

    /// A named preset was chosen: fill the granular controls + suggest its komi.
    /// (Row `reload(...)` never re-fires `onChange`, so there is no feedback loop.)
    private func rulesetChanged(_ index: Int) {
        guard NewGameRuleset.pickerCases.indices.contains(index) else { return }
        let chosen = NewGameRuleset.pickerCases[index]
        preset = chosen
        guard chosen != .custom, let expanded = NewGameRules.expand(chosen) else { return }
        components = expanded
        komi = NewGameRules.suggestedKomi(expanded)
        koRow.reload(selectedIndex: components.koRule.rawValue)
        scoringRow.reload(selectedIndex: components.scoringRule.rawValue)
        taxRow.reload(selectedIndex: components.taxRule.rawValue)
        whbRow.reload(selectedIndex: components.whiteHandicapBonusRule.rawValue)
        suicideRow.reload(isOn: components.multiStoneSuicideLegal)
        buttonRow.reload(isOn: components.hasButton)
        komiRow.reload(value: Double(komi))
    }

    /// A granular control changed: re-derive which preset (if any) matches, and
    /// update the Ruleset popup to it (or "Custom"). Komi is left untouched.
    private func granularChanged() {
        preset = NewGameRules.match(components, preferring: preset)
        rulesetRow.reload(selectedIndex: NewGameRuleset.pickerCases.firstIndex(of: preset) ?? 0)
    }

    // MARK: - Actions

    @objc private func create(_ sender: Any?) {
        // Force any field still being edited (e.g. a just-typed Width) to end
        // editing and commit through its `onChange` before we read the values.
        view.window?.makeFirstResponder(nil)
        let trimmed = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? GameRecord.defaultName : trimmed
        let width = min(max(2, boardWidth), maxBoardLength)
        let height = min(max(2, boardHeight), maxBoardLength)
        let ruleString = NewGameRules.ruleString(preset: preset, components: components)
        let sgf = GameRecord.makeSgf(width: width, height: height, komi: komi, ruleString: ruleString)
        onCreate(sgf, name)
        dismissSelf()
    }

    @objc private func cancel(_ sender: Any?) {
        dismissSelf()
    }

    private func dismissSelf() {
        if let presenting = presentingViewController {
            presenting.dismiss(self)
        } else {
            dismiss(self)
        }
    }

    // MARK: - Helpers

    private func addSeparator() {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        formStack.addArrangedSubview(separator)
        separator.leadingAnchor.constraint(equalTo: formStack.leadingAnchor).isActive = true
        separator.trailingAnchor.constraint(equalTo: formStack.trailingAnchor).isActive = true
    }

    /// Renders komi as the config editor does (integer when whole, else trimmed).
    private static func komiText(_ komi: Float) -> String {
        if komi == komi.rounded() { return String(Int(komi)) }
        return String(format: "%g", komi)
    }
}
