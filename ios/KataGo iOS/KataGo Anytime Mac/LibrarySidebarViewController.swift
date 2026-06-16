import AppKit
import KataGoUICore

/// The native Library sidebar: a search field over a view-based `NSTableView`
/// of the persisted games (driven by `LibraryStore`). Selecting a row reports
/// the chosen `GameRecord` through `onSelect`, which the window controller
/// routes to `GobanState.loadGame` to switch the board.
final class LibrarySidebarViewController: NSViewController {
    private let store: LibraryStore
    private let navigationContext: NavigationContext
    private let onSelect: (GameRecord?) -> Void

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
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
