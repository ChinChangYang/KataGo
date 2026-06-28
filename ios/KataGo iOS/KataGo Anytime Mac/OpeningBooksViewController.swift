//
//  OpeningBooksViewController.swift
//  KataGo Anytime Mac
//
//  The Opening Books window's content: an NSTableView of the opening-book catalog
//  (6x6...9x9) on the left and a per-book detail pane (description + sizes) on the
//  right. Mirrors `ModelsViewController`'s download lifecycle (one `Downloader`
//  per in-flight row, tracked via a self-rescheduling `withObservationTracking`
//  observer) but with the book-specific download/delete actions. No set-active /
//  backend pane (books just apply to the matching board size when downloaded).
//
//  `onBooksChanged` is invoked after a download finishes or a book is deleted so
//  `MainWindowController` can re-evaluate the active game's book load + eye state.
//

import AppKit
import KataGoUICore

@MainActor
final class OpeningBooksViewController: NSViewController {

    private let onBooksChanged: () -> Void

    private let books: [OpeningBook] = OpeningBook.allCases.sorted { $0.boardSize < $1.boardSize }
    private var downloaders: [String: Downloader] = [:]

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

        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(scrollView)
        splitView.addArrangedSubview(detailContainer)

        let container = NSView()
        container.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            detailContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.reloadData()
        if !books.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        rebuildDetailPane()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadVisibleRows()
        rebuildDetailPane()
    }

    // MARK: - Helpers

    private func isDownloading(_ book: OpeningBook) -> Bool {
        downloaders[book.fileName]?.isDownloading ?? false
    }

    private func reloadRow(for fileName: String) {
        guard let row = books.firstIndex(where: { $0.fileName == fileName }) else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integer: 0))
    }

    private func reloadVisibleRows() {
        tableView.reloadData()
    }

    // MARK: - Download

    private func startDownload(_ book: OpeningBook) {
        guard !isDownloading(book),
              let sourceURL = URL(string: book.url) else { return }
        // Downloader does not create directories.
        try? OpeningBook.ensureBooksDirectory()

        let downloader = Downloader(destinationURL: book.downloadedURL)
        downloaders[book.fileName] = downloader
        trackDownloader(downloader, fileName: book.fileName)

        Task { @MainActor in
            try? await downloader.download(from: sourceURL)
        }
        reloadRow(for: book.fileName)
    }

    private func cancelDownload(_ book: OpeningBook) {
        guard let downloader = downloaders[book.fileName] else { return }
        downloader.cancel()
        downloaders.removeValue(forKey: book.fileName)
        reloadRow(for: book.fileName)
    }

    func cancelAllDownloads() {
        for downloader in downloaders.values {
            downloader.cancel()
        }
        downloaders.removeAll()
    }

    /// Self-rescheduling observation of one `Downloader` (same contract as
    /// `ModelsViewController.trackDownloader`).
    private func trackDownloader(_ downloader: Downloader, fileName: String) {
        withObservationTracking {
            _ = downloader.progress
            _ = downloader.isDownloading
        } onChange: { [weak self, weak downloader] in
            Task { @MainActor in
                guard let self, let downloader else { return }
                guard self.downloaders[fileName] === downloader else { return }

                if downloader.isDownloading {
                    self.reloadRow(for: fileName)
                    self.trackDownloader(downloader, fileName: fileName)
                } else {
                    self.downloaders.removeValue(forKey: fileName)
                    self.reloadRow(for: fileName)
                    if self.selectedBook?.fileName == fileName {
                        self.rebuildDetailPane()
                    }
                    // A finished download may make the active game's book available.
                    self.onBooksChanged()
                }
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
            if self.selectedBook?.fileName == book.fileName {
                self.rebuildDetailPane()
            }
            self.onBooksChanged()
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    // MARK: - Detail pane

    private var selectedBook: OpeningBook? {
        let row = tableView.selectedRow
        guard row >= 0, row < books.count else { return nil }
        return books[row]
    }

    private func rebuildDetailPane() {
        detailPane?.removeFromSuperview()
        detailPane = nil

        guard let book = selectedBook else { return }

        let pane = OpeningBookDetailPaneView(book: book)
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
        books.count
    }
}

// MARK: - NSTableViewDelegate

extension OpeningBooksViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row >= 0, row < books.count else { return nil }
        let book = books[row]

        let cell: OpeningBookRowView
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self)
            as? OpeningBookRowView {
            cell = reused
        } else {
            cell = OpeningBookRowView()
            cell.identifier = Self.cellIdentifier
        }

        cell.configure(
            book: book,
            isDownloaded: book.isDownloaded,
            downloader: downloaders[book.fileName],
            onDownload: { [weak self] in self?.startDownload(book) },
            onCancel: { [weak self] in self?.cancelDownload(book) },
            onDelete: { [weak self] in self?.deleteBook(book) }
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        rebuildDetailPane()
    }
}

// MARK: - Detail pane

/// Shows the selected book's description and sizes. Scrolls from the top so a
/// long description stays fully readable regardless of window height.
@MainActor
final class OpeningBookDetailPaneView: NSView {

    private let book: OpeningBook

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    init(book: OpeningBook) {
        self.book = book
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

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
}

@MainActor
private final class OpeningBookFlippedView: NSView {
    override var isFlipped: Bool { true }
}
