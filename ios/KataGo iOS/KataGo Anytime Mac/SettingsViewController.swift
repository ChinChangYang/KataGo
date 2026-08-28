//
//  SettingsViewController.swift
//  KataGo Anytime Mac
//
//  P5-T11: the native macOS Settings (⌘,) content — an `NSTabViewController`
//  with `.toolbar` style (the standard macOS prefs look) over the app-wide
//  display/behavior settings. It is the AppKit analogue of the iOS
//  `GlobalSettingsView` (`KataGo iOS/ConfigView.swift`), split across seven
//  tabs: General · Board · Analysis · Sound & Feedback · Voice Control · Siri ·
//  Licenses.
//  The last two host shared SwiftUI screens from KataGoUICore rather than
//  AppKit rows.
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
import SwiftUI
import SwiftData
import KataGoUICore

@MainActor
final class SettingsViewController: NSTabViewController {
    private let gobanState: GobanState
    /// Live board size, read by the Voice Control pane so its spoken examples
    /// name intersections that exist on the board currently open. `@Observable`,
    /// so the pane follows a game switch made while Settings is up.
    private let board: BoardSize
    /// Read by the Siri pane to name the user's newest game inside the
    /// parameterized example phrases.
    private let modelContainer: ModelContainer

    // Each pane is retained so the live observer can reload its controls.
    private let generalPane: SettingsPaneViewController
    private let boardPane: SettingsPaneViewController
    private let analysisPane: SettingsPaneViewController
    private let soundPane: SettingsPaneViewController

    /// Armed while the window is on screen so the open Settings window reflects
    /// `gobanState` flags mutated elsewhere (View menu / board). Torn down in
    /// `viewWillDisappear` so a closed window stops observing.
    private var isObserving = false

    init(session: GameSession, modelContainer: ModelContainer) {
        self.gobanState = session.gobanState
        self.board = session.board
        self.modelContainer = modelContainer

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
        addTab(makeVoiceControlPane(), label: "Voice Control", symbol: "mic")
        addTab(makeSiriPane(), label: "Siri", symbol: "waveform")
        addTab(makeLicensesPane(), label: "Licenses", symbol: "doc.text")
    }

    /// Feedback 2026-07-30: with Voice Control on, "it is not clear what
    /// commands are available". Same hosting recipe as the Licenses tab below —
    /// the shared SwiftUI screen, which picks up the Mac phrasing ("Click",
    /// "Show commands") from `VoiceControlPhrasebook.current`.
    private func makeVoiceControlPane() -> NSViewController {
        let hosting = NSHostingController(rootView: NavigationStack {
            MacVoiceControlPane(board: board)
        })
        hosting.preferredContentSize = NSSize(width: 640, height: 560)
        return hosting
    }

    /// The shared screen shows only the four Mac shortcuts
    /// (`SiriPhrasebook.current == .macOS` — the Listen shortcuts are
    /// iOS-only). Unlike the Voice Control tab this one is not a bare
    /// hosting controller: the pane re-fetches the newest game's name in
    /// `viewWillAppear`, the sibling panes' hook.
    private func makeSiriPane() -> NSViewController {
        SiriPaneViewController(container: modelContainer)
    }

    /// The TestFlight EULA points users at "Settings > Open-Source
    /// Licenses" on every platform — this tab hosts the shared SwiftUI
    /// registry list (an NSHostingController is a plain NSViewController,
    /// so it slots into the tab controller; the .toolbar tab style resizes
    /// the window to each tab's preferred size).
    private func makeLicensesPane() -> NSViewController {
        let hosting = NSHostingController(rootView: NavigationStack {
            AcknowledgmentsView()
        })
        hosting.preferredContentSize = NSSize(width: 640, height: 520)
        return hosting
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
            // The library row's board. Off is the degenerate size, not a second
            // switch. iOS files this under a "Game List" section; the Mac
            // Settings window has no such tab, and General is the nearest home.
            .popup(title: "Thumbnails",
                   options: Config.thumbnailSizes,
                   get: { $0.thumbnailSize },
                   set: { $0.thumbnailSize = $1 },
                   fallback: Config.defaultThumbnailSize),
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

/// Thin SwiftUI wrapper that keeps the shared Voice Control help screen in step
/// with the live board: `BoardSize` is `@Observable`, so switching games while
/// the Settings window is open re-derives the spoken examples (a 37x37 names its
/// two-letter columns, a 9x9 names its own corners).
private struct MacVoiceControlPane: View {
    let board: BoardSize

    var body: some View {
        VoiceControlHelpView(boardWidth: Int(board.width),
                             boardHeight: Int(board.height))
    }
}

/// The Siri tab. The Settings window is created once and retained for the
/// app's lifetime, so a construction-time fetch of the newest game's name
/// would go stale; SwiftUI's `.onAppear` is not enough either, because it
/// does not re-fire when the ordered-out window is reopened on the same tab.
/// So the refresh rides `viewWillAppear` — the same hook the sibling
/// `SettingsPaneViewController`s use to reflect changes made while the
/// window was closed (it also fires on every tab switch back). When the
/// library is empty the shared view falls back to `GameRecord.defaultName`.
private final class SiriPaneViewController: NSViewController {
    private let container: ModelContainer
    private let model = MacSiriPaneModel()

    init(container: ModelContainer) {
        self.container = container
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let hosting = NSHostingController(rootView: NavigationStack {
            MacSiriPhrasesPane(model: model)
        })
        addChild(hosting)
        view = hosting.view
        preferredContentSize = NSSize(width: 640, height: 560)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        model.exampleGameName = try? GameRecord
            .fetchGameRecordsForPicker(container: container, fetchLimit: 1)
            .first?.name
    }
}

/// The bridge from the AppKit refresh above into SwiftUI: `@Observable`, so
/// assigning `exampleGameName` re-renders the mounted screen in place.
@Observable @MainActor
private final class MacSiriPaneModel {
    var exampleGameName: String?
}

private struct MacSiriPhrasesPane: View {
    let model: MacSiriPaneModel

    var body: some View {
        SiriPhrasesHelpView(exampleGameName: model.exampleGameName)
    }
}
