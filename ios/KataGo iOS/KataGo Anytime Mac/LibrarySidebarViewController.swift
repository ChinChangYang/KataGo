import AppKit
import UniformTypeIdentifiers
import KataGoUICore

/// Receives the sidebar's right-click context-menu actions, acting on an
/// explicit `GameRecord` (the clicked row — not necessarily the loaded game).
/// Implemented by `MainWindowController` via its `LibraryActions` extension.
@MainActor
protocol LibraryActionsDelegate: AnyObject {
    func cloneGame(_ game: GameRecord)
    func cloneCurrentPosition(of game: GameRecord)
    func renameGame(_ game: GameRecord)
    func deleteGame(_ game: GameRecord)
    /// Presents the system share sheet for `game`'s SGF, anchored to `rect`
    /// within `view` (the clicked table row). `view` may be `nil` for menu-bar
    /// invocations, in which case the implementation falls back to a sensible
    /// window-relative anchor.
    func shareGame(_ game: GameRecord, from view: NSView?, rect: NSRect)
    /// Imports the SGF files at `urls` and switches the board to the last one.
    /// Used by the sidebar's drag-and-drop drop handler.
    func importAndSelect(from urls: [URL])
}

/// The native Library sidebar: a search field over a view-based `NSTableView`
/// of the persisted games (driven by `LibraryStore`). Selecting a row reports
/// the chosen `GameRecord` through `onSelect`, which the window controller
/// routes to `GobanState.loadGame` to switch the board. A right-click context
/// menu (Clone / Clone Current Position / Rename / Delete) acts on the clicked
/// row through `actionsDelegate`.
final class LibrarySidebarViewController: NSViewController {
    private let store: LibraryStore
    private let navigationContext: NavigationContext
    private let onSelect: (GameRecord?) -> Void

    /// Weak to avoid a retain cycle: the delegate is the window controller, which
    /// owns the split VC that owns this sidebar VC (window controller → split VC →
    /// sidebar VC). A strong reference back would close that loop.
    weak var actionsDelegate: LibraryActionsDelegate?

    private let searchField = NSSearchField()
    private let tableView = LibraryTableView()
    private let scrollView = NSScrollView()

    /// Set while we drive the selection ourselves (initial launch reflection and
    /// `reloadPreservingSelection`) so `tableViewSelectionDidChange` doesn't
    /// mistake a programmatic change for a user click and trigger a reload.
    private var isProgrammaticSelection = false

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("GameRowCell")

    init(store: LibraryStore,
         navigationContext: NavigationContext,
         onSelect: @escaping (GameRecord?) -> Void) {
        self.store = store
        self.navigationContext = navigationContext
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView()

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search Games"
        searchField.delegate = self
        container.addSubview(searchField)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("game"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.usesAutomaticRowHeights = true
        tableView.rowSizeStyle = .custom
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menu = makeContextMenu()
        // Finder-style bare keys, active only while the table is first responder
        // (so they never clash with the search field / rename dialog): ⏎ renames
        // and ⌫ deletes the selected game, via the same `actionsDelegate` path as
        // the context menu. `contextTargetGame` resolves to the selected row here
        // because there is no clicked row during a key press.
        tableView.onReturnKey = { [weak self] in
            guard let self, let game = self.contextTargetGame else { return }
            self.actionsDelegate?.renameGame(game)
        }
        tableView.onDeleteKey = { [weak self] in
            guard let self, let game = self.contextTargetGame else { return }
            self.actionsDelegate?.deleteGame(game)
        }
        // Dropping `.sgf`/`.txt` files onto the list imports them, mirroring the
        // iOS `onDrop` handler. The table reads/filters the dropped URLs and
        // forwards them here; we route to the window controller's shared import.
        tableView.onDropFiles = { [weak self] urls in
            self?.actionsDelegate?.importAndSelect(from: urls)
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        store.onChange = { [weak self] in
            self?.reloadPreservingSelection()
        }
        // Reflect the launch-selected game without re-loading it.
        reloadPreservingSelection()
    }

    // MARK: - Selection sync

    /// Reloads the table, then re-selects the row for the currently-loaded game
    /// (from `navigationContext`) without firing `onSelect` — this keeps the
    /// sidebar's highlight in sync with the launch/already-loaded game and with
    /// store refetches, instead of being treated as a fresh user selection.
    func reloadPreservingSelection() {
        tableView.reloadData()

        let targetRow = store.games.firstIndex { $0 === navigationContext.selectedGameRecord }

        isProgrammaticSelection = true
        defer { isProgrammaticSelection = false }
        if let targetRow {
            tableView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(targetRow)
        } else {
            tableView.deselectAll(nil)
        }
    }
}

// MARK: - Context menu

extension LibrarySidebarViewController {
    /// Builds the right-click menu for the table. Items target this VC; AppKit
    /// drives enablement through `validateMenuItem` (auto-enable).
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Clone",
                     action: #selector(cloneClickedGame(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Clone Current Position",
                     action: #selector(cloneCurrentPositionOfClickedGame(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Rename",
                     action: #selector(renameClickedGame(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Share",
                     action: #selector(shareClickedGame(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete",
                     action: #selector(deleteClickedGame(_:)),
                     keyEquivalent: "")
        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    /// Resolves the record the context menu should act on: the right-clicked row
    /// when there is one, otherwise the selected row.
    private var contextTargetGame: GameRecord? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < store.games.count else { return nil }
        return store.games[row]
    }

    @objc private func cloneClickedGame(_ sender: Any?) {
        guard let game = contextTargetGame else { return }
        actionsDelegate?.cloneGame(game)
    }

    @objc private func cloneCurrentPositionOfClickedGame(_ sender: Any?) {
        guard let game = contextTargetGame else { return }
        actionsDelegate?.cloneCurrentPosition(of: game)
    }

    @objc private func renameClickedGame(_ sender: Any?) {
        guard let game = contextTargetGame else { return }
        actionsDelegate?.renameGame(game)
    }

    /// Shares the clicked (or selected) row's SGF, anchoring the share popover to
    /// that row's rect in the table so it points at the game being shared.
    @objc private func shareClickedGame(_ sender: Any?) {
        guard let game = contextTargetGame else { return }
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        let rowRect = row >= 0 ? tableView.rect(ofRow: row) : tableView.bounds
        actionsDelegate?.shareGame(game, from: tableView, rect: rowRect)
    }

    @objc private func deleteClickedGame(_ sender: Any?) {
        guard let game = contextTargetGame else { return }
        actionsDelegate?.deleteGame(game)
    }
}

// MARK: - NSMenuItemValidation

extension LibrarySidebarViewController: NSMenuItemValidation {
    /// Disables every context-menu item when there's no target row; enables
    /// "Clone Current Position" only for the currently-loaded game, since it
    /// clones the live board position.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let game = contextTargetGame else { return false }
        if menuItem.action == #selector(cloneCurrentPositionOfClickedGame(_:)) {
            return game === navigationContext.selectedGameRecord
        }
        return true
    }
}

// MARK: - NSTableViewDataSource

extension LibrarySidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        store.games.count
    }
}

// MARK: - NSTableViewDelegate

extension LibrarySidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row >= 0, row < store.games.count else { return nil }

        let cell: GameRowView
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self)
            as? GameRowView {
            cell = reused
        } else {
            cell = GameRowView()
            cell.identifier = Self.cellIdentifier
        }
        cell.configure(with: store.games[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Ignore selection changes we made ourselves (launch reflection / reload).
        guard !isProgrammaticSelection else { return }

        let row = tableView.selectedRow
        let selected: GameRecord? = (row >= 0 && row < store.games.count) ? store.games[row] : nil

        // Re-entrancy guard: only act when the selection actually differs from
        // the currently-loaded game, so re-selecting the same row is a no-op.
        guard selected !== navigationContext.selectedGameRecord else { return }

        onSelect(selected)
    }
}

// MARK: - NSSearchFieldDelegate

extension LibrarySidebarViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        store.searchText = field.stringValue
    }
}

// MARK: - LibraryTableView

/// `NSTableView` that adds Finder-style bare-key handling for the library list:
/// Return renames the selected game and Delete (Backspace) removes it. These
/// fire only while the table is first responder — so, unlike a global menu key
/// equivalent, they never swallow Return/Delete in the search field or the
/// rename dialog. The owning controller supplies the actual behavior via the
/// closures; type-select and arrow-key navigation fall through to `super`.
///
/// It also accepts dropped `.sgf`/`.txt` file URLs (Finder, other apps) and
/// forwards them to `onDropFiles` for import — the AppKit analogue of the iOS
/// `.onDrop` handler.
final class LibraryTableView: NSTableView {
    var onReturnKey: (() -> Void)?
    var onDeleteKey: (() -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    /// Hardware virtual key codes (layout-independent): Return, keypad Enter,
    /// and Delete (Backspace).
    private static let returnKeyCodes: Set<UInt16> = [36, 76]
    private static let deleteKeyCode: UInt16 = 51

    /// File extensions we accept on a drop (matches the open panel / iOS drop).
    private static let acceptedExtensions: Set<String> = ["sgf", "txt"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func keyDown(with event: NSEvent) {
        if selectedRow >= 0, Self.returnKeyCodes.contains(event.keyCode) {
            onReturnKey?()
            return
        }
        if selectedRow >= 0, event.keyCode == Self.deleteKeyCode {
            onDeleteKey?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Drag-and-drop

    /// Reads `.sgf`/`.txt` file URLs from a dragging pasteboard, filtered by
    /// extension. Returns an empty array when the drag carries none (so callers
    /// can reject the operation).
    private func sgfURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        return urls.filter { Self.acceptedExtensions.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sgfURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sgfURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sgfURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}
