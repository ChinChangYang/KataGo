//
//  SettingsViewController.swift
//  KataGo Anytime Mac
//
//  P5-T11: the native macOS Settings (⌘,) content — an `NSTabViewController`
//  with `.toolbar` style (the standard macOS prefs look) over the app-wide
//  display/behavior settings. It is the AppKit analogue of the iOS
//  `GlobalSettingsView` (`KataGo iOS/ConfigView.swift` lines 648-796), split
//  across four tabs: General · Board · Analysis · Sound & Feedback.
//
//  SINGLE WRITER. The shared `GobanState` is the only thing these controls
//  read/write — never `UserDefaults` directly. `MacGlobalPreferenceSync`
//  (Phase 3) already persists every `gobanState.*` change to the matching
//  `GlobalSettings.*` UserDefaults key, so writing `gobanState.*` here both
//  updates the live board AND persists, with no double-write.
//
//  Int pickers map index↔value DIRECTLY: each `Config.<array>` is indexed by
//  the stored Int (`Config.stoneStyles[gobanState.stoneStyle]`, etc., confirmed
//  in `GobanState`/`ConfigModel`), so the popup's `selectedIndex` IS the
//  `gobanState` Int and `onChange(index)` writes `gobanState.<prop> = index`.
//  Out-of-range indices fall back to the matching `Config.default*` constant.
//
//  Reflecting EXTERNAL changes (the View-menu toggles + the board mutate the
//  same `gobanState` flags):
//    • `viewWillAppear` on each tab repopulates its controls from the live
//      `gobanState` (reflects changes made while the window was closed).
//    • While the window is open, a self-rescheduling `withObservationTracking`
//      observer (the same pattern `MainWindowController`/`MacGlobalPreferenceSync`
//      use) reloads the row controls' values on any tracked-property change.
//
//  Reuses `ConfigFormBuilder` (`popupRow`/`checkboxRow`) and its `PopupRow`/
//  `CheckboxRow` row types from `ConfigEditingSupport.swift` — no new row types.
//  `hapticFeedback` is intentionally DROPPED on macOS (no haptics).
//

import AppKit
import KataGoUICore

@MainActor
final class SettingsViewController: NSTabViewController {
    private let gobanState: GobanState

    // Each pane is retained so the live observer can reload its controls.
    private let generalPane: SettingsPaneViewController
    private let boardPane: SettingsPaneViewController
    private let analysisPane: SettingsPaneViewController
    private let soundPane: SettingsPaneViewController

    /// Armed while the window is on screen so the open Settings window reflects
    /// `gobanState` flags mutated elsewhere (View menu / board). Torn down in
    /// `viewWillDisappear` so a closed window stops observing.
    private var isObserving = false

    init(session: GameSession) {
        self.gobanState = session.gobanState

        generalPane = SettingsPaneViewController(gobanState: gobanState, rows: Self.generalRows)
        boardPane = SettingsPaneViewController(gobanState: gobanState, rows: Self.boardRows)
        analysisPane = SettingsPaneViewController(gobanState: gobanState, rows: Self.analysisRows)
        soundPane = SettingsPaneViewController(gobanState: gobanState, rows: Self.soundRows)

        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()

        addTab(generalPane, label: "General", symbol: "gearshape")
        addTab(boardPane, label: "Board", symbol: "squareshape.split.3x3")
        addTab(analysisPane, label: "Analysis", symbol: "chart.xyaxis.line")
        addTab(soundPane, label: "Sound & Feedback", symbol: "speaker.wave.2")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Reflect any change made while the window was closed (each pane also
        // repopulates from the live `gobanState` in its own `viewWillAppear`).
        startObserving()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        isObserving = false
    }

    private func addTab(_ controller: NSViewController, label: String, symbol: String) {
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        addTabViewItem(item)
    }

    // MARK: - Live external-change observation
    //
    // Same self-rescheduling `withObservationTracking` bridge `MainWindowController`
    // uses. The apply closure touches every tracked property so a change to ANY
    // fires `onChange`; `onChange` runs before the mutation commits, so we hop to
    // `Task { @MainActor }` to read committed values, reload the panes, then
    // re-arm (tracking is one-shot). Reloading the rows does NOT mutate
    // `gobanState`, so there is no feedback loop. Gated by `isObserving` so the
    // observer effectively stops when the window is closed.

    private func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        track()
    }

    private func track() {
        withObservationTracking {
            // Touch every property any pane displays so a change to any fires.
            _ = gobanState.stoneStyle
            _ = gobanState.moveNumberStyle
            _ = gobanState.analysisStyle
            _ = gobanState.analysisInformation
            _ = gobanState.showCoordinate
            _ = gobanState.showPass
            _ = gobanState.verticalFlip
            _ = gobanState.showCharts
            _ = gobanState.showOwnership
            _ = gobanState.showWinrateBar
            _ = gobanState.showVisitsPerSecond
            _ = gobanState.soundEffect
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isObserving else { return }
                self.reloadAllPanes()
                self.track()
            }
        }
    }

    private func reloadAllPanes() {
        generalPane.reloadControls()
        boardPane.reloadControls()
        analysisPane.reloadControls()
        soundPane.reloadControls()
    }

    // MARK: - Tab → field mapping
    //
    // Each entry describes one row built by `SettingsPaneViewController` from a
    // `GobanState` accessor. Mirrors iOS `GlobalSettingsView` field-by-field
    // (haptics dropped). Int pickers use the `Config.<array>` index == the
    // stored Int directly; checkboxes are plain bools.

    private static var generalRows: [SettingRow] {
        [
            .checkbox(title: "Show chart/comments",
                      get: { $0.showCharts },
                      set: { $0.showCharts = $1 }),
        ]
    }

    private static var boardRows: [SettingRow] {
        [
            .popup(title: "Stone style",
                   options: Config.stoneStyles,
                   get: { $0.stoneStyle },
                   set: { $0.stoneStyle = $1 },
                   fallback: Config.defaultStoneStyle),
            .popup(title: "Move numbers",
                   options: Config.moveNumberStyles,
                   get: { $0.moveNumberStyle },
                   set: { $0.moveNumberStyle = $1 },
                   fallback: Config.defaultMoveNumberStyle),
            .checkbox(title: "Show coordinate",
                      get: { $0.showCoordinate },
                      set: { $0.showCoordinate = $1 }),
            .checkbox(title: "Show pass",
                      get: { $0.showPass },
                      set: { $0.showPass = $1 }),
            .checkbox(title: "Vertical flip",
                      get: { $0.verticalFlip },
                      set: { $0.verticalFlip = $1 }),
        ]
    }

    private static var analysisRows: [SettingRow] {
        [
            .popup(title: "Analysis information",
                   options: Config.analysisInformations,
                   get: { $0.analysisInformation },
                   set: { $0.analysisInformation = $1 },
                   fallback: Config.defaultAnalysisInformation),
            .popup(title: "Analysis style",
                   options: Config.analysisStyles,
                   get: { $0.analysisStyle },
                   set: { $0.analysisStyle = $1 },
                   fallback: Config.defaultAnalysisStyle),
            .checkbox(title: "Show ownership",
                      get: { $0.showOwnership },
                      set: { $0.showOwnership = $1 }),
            .checkbox(title: "Show win rate bar",
                      get: { $0.showWinrateBar },
                      set: { $0.showWinrateBar = $1 }),
            .checkbox(title: "Show visits/s",
                      get: { $0.showVisitsPerSecond },
                      set: { $0.showVisitsPerSecond = $1 }),
        ]
    }

    private static var soundRows: [SettingRow] {
        [
            .checkbox(title: "Sound effect",
                      get: { $0.soundEffect },
                      set: { $0.soundEffect = $1 }),
        ]
    }
}

// MARK: - SettingRow
//
// A declarative description of one Settings row, bound to a `GobanState`
// accessor. `get`/`set` close over the typed property so the pane controller
// never special-cases a field. Both closures run on the main actor (the
// pane is `@MainActor`).

@MainActor
enum SettingRow {
    /// An Int picker: `options` index == the stored `GobanState` Int. `fallback`
    /// is used when the stored value is out of range (mirrors iOS's
    /// `firstIndex(of:) ?? Config.default*`).
    case popup(title: String,
               options: [String],
               get: (GobanState) -> Int,
               set: (GobanState, Int) -> Void,
               fallback: Int)
    /// A bool checkbox.
    case checkbox(title: String,
                  get: (GobanState) -> Bool,
                  set: (GobanState, Bool) -> Void)
}

// MARK: - SettingsPaneViewController
//
// One Settings tab: a vertical stack of `ConfigFormBuilder` rows built from a
// `[SettingRow]`. Each control seeds from `gobanState` and writes back on
// change; `reloadControls()` re-syncs the controls from the live `gobanState`
// WITHOUT firing the change closures (used by `viewWillAppear` for changes made
// while closed, and by the parent's live observer while open).

@MainActor
final class SettingsPaneViewController: NSViewController {
    private let gobanState: GobanState
    private let rows: [SettingRow]

    /// The built row views paired with their model, so `reloadControls()` can
    /// repopulate each control from the current `gobanState` value.
    private var popupBindings: [(row: PopupRow, options: [String], get: (GobanState) -> Int, fallback: Int)] = []
    private var checkboxBindings: [(row: CheckboxRow, get: (GobanState) -> Bool)] = []

    init(gobanState: GobanState, rows: [SettingRow]) {
        self.gobanState = gobanState
        self.rows = rows
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView()

        let formStack = NSStackView()
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 12
        formStack.translatesAutoresizingMaskIntoConstraints = false

        buildRows(into: formStack)

        container.addSubview(formStack)
        NSLayoutConstraint.activate([
            formStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            formStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            formStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            // Pin the bottom so the pane sizes to its content (prefs panes hug).
            formStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])

        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Reflect changes made while this tab (or the whole window) was hidden.
        reloadControls()
    }

    private func buildRows(into stack: NSStackView) {
        for row in rows {
            switch row {
            case let .popup(title, options, get, set, fallback):
                let current = get(gobanState)
                let index = options.indices.contains(current) ? current : fallback
                let popupRow = ConfigFormBuilder.popupRow(
                    title: title,
                    options: options,
                    selectedIndex: index,
                    onChange: { [weak self] newIndex in
                        guard let self else { return }
                        set(self.gobanState, newIndex)
                    })
                popupBindings.append((popupRow, options, get, fallback))
                stack.addArrangedSubview(popupRow)

            case let .checkbox(title, get, set):
                let checkboxRow = ConfigFormBuilder.checkboxRow(
                    title: title,
                    isOn: get(gobanState),
                    onChange: { [weak self] isOn in
                        guard let self else { return }
                        set(self.gobanState, isOn)
                    })
                checkboxBindings.append((checkboxRow, get))
                stack.addArrangedSubview(checkboxRow)
            }
        }
    }

    /// Re-syncs every control from the live `gobanState` without firing the
    /// `onChange` closures (the `reload(...)` methods are silent). Out-of-range
    /// picker values fall back to the row's compiled default, exactly as the
    /// initial seed does.
    func reloadControls() {
        for binding in popupBindings {
            let current = binding.get(gobanState)
            let index = binding.options.indices.contains(current) ? current : binding.fallback
            binding.row.reload(selectedIndex: index)
        }
        for binding in checkboxBindings {
            binding.row.reload(isOn: binding.get(gobanState))
        }
    }
}
