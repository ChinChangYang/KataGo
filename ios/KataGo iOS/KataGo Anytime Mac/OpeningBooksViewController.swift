//
//  OpeningBooksViewController.swift
//  KataGo Anytime Mac
//
//  The Opening Books window's content: an NSTableView of the opening-book
//  catalog plus the user's imported books on the left, an Import Book… button
//  under the list, and a per-book detail pane on the right. Mirrors
//  `ModelsViewController`'s download lifecycle (downloads belong to the
//  app-wide `DownloadCenter`; this controller mirrors one onto a row via a
//  self-rescheduling `withObservationTracking` observer) but with the
//  book-specific download/delete actions. When more than one book claims a
//  board size, the detail pane offers the per-size active-book choice.
//
//  `onBooksChanged` is invoked after a download finishes, an import lands, a
//  book is deleted, or the active-book choice changes, so
//  `MainWindowController` can re-evaluate the active game's book load + eye state.
//

import AppKit
import KataGoUICore

@MainActor
final class OpeningBooksViewController: NSViewController {

    private let onBooksChanged: () -> Void

    /// One list row: a catalog entry or a user-imported book.
    enum BookRow {
        case catalog(OpeningBook)
        case imported(CustomBookRecord)
    }

    private let catalogBooks: [OpeningBook] = OpeningBook.allCases.sorted { $0.boardSize < $1.boardSize }

    /// The table's rows: catalog first (by size), then imports (by size, then
    /// import date). Rebuilt after an import, a delete, or a selection change.
    private var rows: [BookRow] = []

    private func rebuildRows() {
        let imports = CustomBookStore().records
            .sorted { ($0.boardSize, $0.importedAt) < ($1.boardSize, $1.importedAt) }
        rows = catalogBooks.map(BookRow.catalog) + imports.map(BookRow.imported)
    }

    /// File names whose `Download` is currently mirrored onto a row. Emptied
    /// when the window closes, which DETACHES the mirror — it does not stop
    /// anything.
    private var observedFileNames: Set<String> = []

    /// Bumped by `detachDownloadObservation()`. `withObservationTracking`
    /// registers a ONE-SHOT observer with no way to unregister it early:
    /// closing the window only clears `observedFileNames`, so an already-armed
    /// observer chain stays armed until the `Download` next mutates. If the
    /// window is reopened before that mutation, `attachDownloadObservation()`
    /// arms a SECOND chain on top of the still-live first one. Each `rearm(...)`
    /// closure captures the generation it was armed under and bails if it no
    /// longer matches — severing the stale chain instead of letting it run
    /// forever alongside the fresh one.
    private var observationGeneration = 0

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let detailContainer = NSView()
    private var detailPane: OpeningBookDetailPaneView?
    private let splitView = NSSplitView()

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("OpeningBookRowCell")

    init(onBooksChanged: @escaping () -> Void) {
        self.onBooksChanged = onBooksChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - View setup

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("book"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
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

        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        // Left pane: the list with an Import Book… bar under it.
        let importButton = NSButton(title: "Import Book…", target: self,
                                    action: #selector(importBookClicked))
        importButton.bezelStyle = .rounded
        importButton.translatesAutoresizingMaskIntoConstraints = false

        let leftPane = NSView()
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        leftPane.addSubview(scrollView)
        leftPane.addSubview(importButton)

        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(leftPane)
        splitView.addArrangedSubview(detailContainer)

        let container = NSView()
        container.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: leftPane.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),

            importButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            importButton.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor, constant: 12),
            importButton.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor, constant: -8),

            leftPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            detailContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuildRows()
        tableView.reloadData()
        if !rows.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        rebuildDetailPane()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // `attachDownloadObservation()` reloads the table itself, so this does
        // not also call `reloadVisibleRows()` — one `reloadData()` per
        // appearance, not two.
        rebuildRows()
        rebuildDetailPane()
        attachDownloadObservation()
    }

    // MARK: - Helpers

    private func download(for book: OpeningBook) -> Download {
        DownloadCenter.shared.download(for: book.downloadedURL)
    }

    /// True while a transfer for this book is running or queued. A paused
    /// download is deliberately not "downloading" — its row offers to resume.
    private func isDownloading(_ book: OpeningBook) -> Bool {
        download(for: book).isBusy
    }

    private func reloadRow(for fileName: String) {
        guard let row = rows.firstIndex(where: { entry in
            if case .catalog(let book) = entry { return book.fileName == fileName }
            return false
        }) else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integer: 0))
    }

    private func reloadVisibleRows() {
        tableView.reloadData()
    }

    // MARK: - Download

    /// Starts, or resumes, the download for `book`. The center refuses a
    /// duplicate by construction (it keys downloads by destination), so the
    /// guard here is about not re-arming a second observer.
    private func startDownload(_ book: OpeningBook) {
        guard !isDownloading(book),
              let sourceURL = URL(string: book.url) else { return }

        let entry = download(for: book)
        DownloadCenter.shared.start(entry, from: sourceURL)
        track(entry, fileName: book.fileName)
        reloadRow(for: book.fileName)
    }

    /// Pauses a book's transfer. The partial survives; the row's download
    /// arrow resumes it.
    private func cancelDownload(_ book: OpeningBook) {
        let entry = download(for: book)
        DownloadCenter.shared.pause(entry)
        reloadRow(for: book.fileName)
    }

    /// Re-attaches the row mirror to every transfer not already finished.
    /// Called when the window appears, because the window can be closed and
    /// reopened while a download runs. Tracks anything short of `.succeeded`
    /// — not just `.transferring`/`.waiting` — so a download sitting in
    /// `.interrupted` behind a retry back-off (or even `.idle`) still gets an
    /// observer; `.idle` never mutates, so arming one costs nothing, but
    /// skipping `.interrupted` would leave a retrying download's row dead
    /// until the next close/reopen, since attach is the only re-entry point.
    func attachDownloadObservation() {
        for book in catalogBooks {
            let entry = download(for: book)
            guard entry.state != .succeeded else { continue }
            track(entry, fileName: book.fileName)
        }
        reloadVisibleRows()
    }

    /// Stops mirroring download state onto rows.
    ///
    /// This does NOT cancel anything. Downloads belong to the app-wide
    /// `DownloadCenter` now and keep running with the window shut; reopening
    /// it re-attaches and shows live progress. Cancelling on close used to be
    /// the promise, and it was the reason a long download could not survive
    /// tidying up your windows.
    func detachDownloadObservation() {
        observedFileNames.removeAll()
        observationGeneration += 1
    }

    private func track(_ entry: Download, fileName: String) {
        guard !observedFileNames.contains(fileName) else { return }
        observedFileNames.insert(fileName)
        rearm(entry, fileName: fileName, generation: observationGeneration)
    }

    /// Self-rescheduling observation of one `Download`. Same
    /// `withObservationTracking` contract as `MainWindowController`: the
    /// callback fires once per change BEFORE the value commits, so we hop to a
    /// `Task { @MainActor }` to read the committed value and RE-ARM tracking
    /// (otherwise observation stops after the first change). `generation` is
    /// the value `observationGeneration` held when this chain was armed; a
    /// closure that fires after a later `detachDownloadObservation()` bumped
    /// it belongs to a chain the window already left — bail rather than re-arm
    /// a second, permanently duplicate chain alongside whatever `attach`
    /// starts next.
    private func rearm(_ entry: Download, fileName: String, generation: Int) {
        withObservationTracking {
            _ = entry.receivedBytes
            _ = entry.state
        } onChange: { [weak self, weak entry] in
            Task { @MainActor in
                guard let self, let entry,
                      generation == self.observationGeneration,
                      self.observedFileNames.contains(fileName) else { return }

                self.reloadRow(for: fileName)
                if entry.state == .succeeded {
                    self.observedFileNames.remove(fileName)
                    self.reloadRow(for: fileName)
                    // Rebuild unconditionally: a finished download can make a
                    // DIFFERENT selected row's size contested, which grows the
                    // active-book popup on that row's pane.
                    self.rebuildDetailPane()
                    // A finished download may make the active game's book available.
                    self.onBooksChanged()
                    return
                }
                self.rearm(entry, fileName: fileName, generation: generation)
            }
        }
    }

    // MARK: - Delete

    private func deleteBook(_ book: OpeningBook) {
        guard book.isDownloaded else { return }

        let alert = NSAlert()
        alert.messageText = "Remove “\(book.title)”?"
        alert.informativeText =
            "This deletes the downloaded opening book. You can download it again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            book.deleteDownloaded()
            self.reloadRow(for: book.fileName)
            self.rebuildDetailPane()
            self.onBooksChanged()
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    // MARK: - Import

    private var importTask: Task<Void, Never>?
    private var importProgressController: ModelImportProgressViewController?

    @objc private func importBookClicked(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a KataGo opening book (.kbook or .kbook.gz)."
        panel.prompt = "Import"
        // Permissive on purpose, like the network importer: providers type
        // files inconsistently, and the importer's KBOK sniff is what actually
        // decides, with a specific reason when it says no.
        panel.allowedContentTypes = [.gzip, .data]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.startImport(from: url)
        }
    }

    /// Copies the chosen file in behind a determinate progress sheet. The copy
    /// itself runs off the main actor (`importBook` is nonisolated async).
    private func startImport(from url: URL) {
        let progress = ModelImportProgressViewController()
        progress.titleText = "Importing Book"
        progress.onCancel = { [weak self] in self?.importTask?.cancel() }
        importProgressController = progress
        presentAsSheet(progress)

        importTask = Task { [weak self] in
            defer {
                self?.dismissImportProgress()
                self?.importTask = nil
            }
            do {
                // Capture the sheet, NOT self — same @Sendable-closure
                // reasoning as ModelsViewController's import.
                let record = try await CustomBookImporter.importBook(from: url) { fraction in
                    Task { @MainActor in progress.update(fraction: fraction) }
                }
                guard let self else { return }
                self.rebuildRows()
                self.tableView.reloadData()
                if let row = self.rows.firstIndex(where: { entry in
                    if case .imported(let existing) = entry { return existing.id == record.id }
                    return false
                }) {
                    self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    self.tableView.scrollRowToVisible(row)
                }
                self.rebuildDetailPane()
                // An import may make the active game's book available, or
                // change what the resolver answers for its size.
                self.onBooksChanged()
            } catch is CancellationError {
                // The partial file is already gone; nothing was recorded.
            } catch {
                self?.presentImportFailure(error)
            }
        }
    }

    private func dismissImportProgress() {
        if let progress = importProgressController {
            dismiss(progress)
        }
        importProgressController = nil
    }

    private func presentImportFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't Import Book"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// Deletes an imported book: file, cache, selections, record — then lets
    /// `MainWindowController` reconcile the live book (the resolver's fallback
    /// makes the affected size fall back to the catalog or another import).
    private func deleteImportedBook(_ record: CustomBookRecord) {
        let alert = NSAlert()
        alert.messageText = "Remove \u{201C}\(record.displayName)\u{201D}?"
        alert.informativeText =
            "This deletes the imported opening book. The app keeps no copy of the original file."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            CustomBookImporter.delete(record)
            self.rebuildRows()
            self.tableView.reloadData()
            self.rebuildDetailPane()
            self.onBooksChanged()
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    // MARK: - Detail pane

    private var selectedBookRow: BookRow? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return nil }
        return rows[row]
    }

    private func rebuildDetailPane() {
        detailPane?.removeFromSuperview()
        detailPane = nil

        guard let bookRow = selectedBookRow else { return }

        let pane = OpeningBookDetailPaneView(
            row: bookRow,
            onActiveBookChanged: { [weak self] in
                guard let self else { return }
                self.rebuildDetailPane()
                self.onBooksChanged()
            }
        )
        pane.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            pane.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        detailPane = pane
    }
}

// MARK: - NSTableViewDataSource

extension OpeningBooksViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }
}

// MARK: - NSTableViewDelegate

extension OpeningBooksViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row >= 0, row < rows.count else { return nil }

        let cell: OpeningBookRowView
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self)
            as? OpeningBookRowView {
            cell = reused
        } else {
            cell = OpeningBookRowView()
            cell.identifier = Self.cellIdentifier
        }

        switch rows[row] {
        case .catalog(let book):
            cell.configure(
                book: book,
                isDownloaded: book.isDownloaded,
                download: download(for: book),
                onDownload: { [weak self] in self?.startDownload(book) },
                onCancel: { [weak self] in self?.cancelDownload(book) },
                onDelete: { [weak self] in self?.deleteBook(book) }
            )
        case .imported(let record):
            cell.configure(
                imported: record,
                onDelete: { [weak self] in self?.deleteImportedBook(record) }
            )
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        rebuildDetailPane()
    }
}

// MARK: - Detail pane

/// Shows the selected book's description and sizes — and, when more than one
/// book claims the row's board size, the per-size active-book choice. Scrolls
/// from the top so a long description stays fully readable regardless of
/// window height.
@MainActor
final class OpeningBookDetailPaneView: NSView {

    private let row: OpeningBooksViewController.BookRow
    private let onActiveBookChanged: () -> Void

    /// Identities behind the active-book popup's items, in item order.
    private var popupIdentities: [String] = []

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    init(row: OpeningBooksViewController.BookRow,
         onActiveBookChanged: @escaping () -> Void) {
        self.row = row
        self.onActiveBookChanged = onActiveBookChanged
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var boardSize: Int {
        switch row {
        case .catalog(let book): return book.boardSize
        case .imported(let record): return record.boardSize
        }
    }

    private func build() {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        switch row {
        case .catalog(let book):
            let header = NSTextField(labelWithString: book.title)
            header.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
            header.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(header)

            let sizeText = book.isDownloaded
                ? "Downloaded · \(Self.byteFormatter.string(fromByteCount: Int64(book.onDiskSize ?? book.fileSize)))"
                : "Download size: \(Self.byteFormatter.string(fromByteCount: Int64(book.fileSize)))"
            let size = NSTextField(labelWithString: sizeText)
            size.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            size.textColor = .secondaryLabelColor
            stack.addArrangedSubview(size)

            if !book.description.isEmpty {
                let description = NSTextField(wrappingLabelWithString: book.description)
                description.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                description.textColor = .secondaryLabelColor
                description.isSelectable = true
                description.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(description)
                description.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
            }

        case .imported(let record):
            let header = NSTextField(labelWithString: record.displayName)
            header.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
            header.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(header)

            let bytes = record.onDiskSize ?? record.fileSize
            let sizeText = "Imported · \(record.boardSize)x\(record.boardSize) · " +
                Self.byteFormatter.string(fromByteCount: Int64(bytes))
            let size = NSTextField(labelWithString: sizeText)
            size.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            size.textColor = .secondaryLabelColor
            stack.addArrangedSubview(size)

            let dateText = "Imported \(record.importedAt.formatted(date: .abbreviated, time: .shortened))"
            let date = NSTextField(labelWithString: dateText)
            date.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            date.textColor = .secondaryLabelColor
            stack.addArrangedSubview(date)

            let note = NSTextField(wrappingLabelWithString:
                "An imported book stays on this Mac only. The app read its board size from the file itself.")
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            note.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }

        // Per-size active-book choice — only when the size is contested.
        let candidates = BookResolver.candidates(forBoardSize: boardSize)
        if candidates.count >= 2 {
            let label = NSTextField(labelWithString: "Active book for \(boardSize)x\(boardSize):")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            stack.addArrangedSubview(label)

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popupIdentities = candidates.map(\.identity)
            for candidate in candidates {
                popup.addItem(withTitle: candidate.displayName)
            }
            let resolved = BookResolver.resolvedBook(forBoardSize: boardSize)?.identity
            if let resolved, let index = popupIdentities.firstIndex(of: resolved) {
                popup.selectItem(at: index)
            }
            popup.target = self
            popup.action = #selector(activeBookPicked(_:))
            stack.addArrangedSubview(popup)
        }

        let documentView = OpeningBookFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = documentView

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    @objc private func activeBookPicked(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < popupIdentities.count else { return }
        CustomBookStore().setActiveBookIdentity(popupIdentities[index], forBoardSize: boardSize)
        onActiveBookChanged()
    }
}

@MainActor
private final class OpeningBookFlippedView: NSView {
    override var isFlipped: Bool { true }
}
