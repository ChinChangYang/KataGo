//
//  ModelsViewController.swift
//  KataGo Anytime Mac
//
//  P5-T7 + P5-T8: the Models window's content. A split-style layout with a
//  view-based `NSTableView` of the neural-net catalog on the left and a
//  per-model backend-config detail pane on the right.
//
//  Mirrors the iOS `ModelPickerView` / `ModelDetailView` (download/delete/
//  set-active tri-state) and `BackendConfigSheet` (backend/board-size/tuning),
//  reusing the SAME building blocks: `NeuralNetworkModel.allCases`, `Downloader`,
//  `BackendSettings`, and `ConfigFormBuilder`. No logic is reimplemented.
//
//  Download lifecycle
//  ------------------
//  One `Downloader` per in-flight row, tracked in `downloaders` keyed by
//  `fileName`. Progress is surfaced to the row via a self-rescheduling
//  `withObservationTracking` observer (the same pattern `MainWindowController`
//  uses), which reloads just the affected row on every `Downloader` mutation.
//  On completion the file lands at `downloadedURL`; the row flips to its
//  "Downloaded" state and the downloader is dropped. `cancelAllDownloads()`
//  (called from the window controller's `windowWillClose`) cancels everything so
//  a dismissed window never leaves a background download running.
//
//  Set active
//  ----------
//  Choosing a downloaded model (the row's "Set Active" button, or double-click)
//  calls `onSetActive`, which the window controller routes to
//  `MainWindowController.relaunch(model:)` (set active + in-process relaunch).
//
//  Ready badge seam (P5-T10)
//  -------------------------
//  The CoreML "Ready" badge depends on the readiness projection fix (P5-T10).
//  Until then `readyFileNames` is an empty hook; `ModelRowView` already consults
//  it, so wiring T10 is a one-line change here (populate `readyFileNames` +
//  `reloadVisibleRows()`).
//

import AppKit
import KataGoUICore

@MainActor
final class ModelsViewController: NSViewController {

    // MARK: - Inputs

    /// Title of the active model (for the "Active" badge). A closure so the badge
    /// re-reads the live selection on every reload (e.g. after a relaunch).
    private let currentModelTitle: () -> String

    /// Invoked when the user chooses a downloaded model as the active net.
    private let onSetActive: (NeuralNetworkModel) -> Void

    // MARK: - Data

    /// The visible catalog rows. Computed once at load (the catalog is static).
    private let models: [NeuralNetworkModel] = NeuralNetworkModel.allCases.filter { $0.visible }

    /// `fileName -> availability` (true == the model's file exists on disk, or it
    /// is the built-in net). Recomputed on appear and after every download/delete.
    private var availability: [String: Bool] = [:]

    /// In-flight downloads, keyed by `fileName`. Removed when the download
    /// finishes or is cancelled.
    private var downloaders: [String: Downloader] = [:]

    /// Seam for the P5-T10 CoreML "Ready" badge. Empty until T10 lands; the row
    /// view already reads it, so T10 just populates this + reloads.
    private var readyFileNames: Set<String> = []

    // MARK: - Views

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let detailContainer = NSView()
    private var backendPane: ModelBackendPaneView?
    private let splitView = NSSplitView()

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("ModelRowCell")

    // MARK: - Init

    init(currentModelTitle: @escaping () -> String,
         onSetActive: @escaping (NeuralNetworkModel) -> Void) {
        self.currentModelTitle = currentModelTitle
        self.onSetActive = onSetActive
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - View setup

    override func loadView() {
        // Left: the model table. Right: the backend-config detail pane.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
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
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)

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
            // The table list keeps a reasonable minimum width; the detail pane
            // takes the remainder.
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            detailContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        recomputeAvailability()
        tableView.reloadData()
        // Select the active model on open so the detail pane shows something.
        if let activeRow = models.firstIndex(where: { $0.title == currentModelTitle() }) {
            tableView.selectRowIndexes(IndexSet(integer: activeRow), byExtendingSelection: false)
        } else if !models.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        rebuildDetailPane()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Re-check availability each time the window is shown (a model may have
        // been deleted/added since the last appearance).
        recomputeAvailability()
        reloadVisibleRows()
    }

    // MARK: - Availability

    /// Recomputes `availability` for every visible model. The built-in net is
    /// always available; others exist iff their downloaded file is present.
    /// Mirrors the iOS `ModelDetailView.onAppear` availability check.
    private func recomputeAvailability() {
        for model in models {
            availability[model.fileName] = isAvailable(model)
        }
    }

    private func isAvailable(_ model: NeuralNetworkModel) -> Bool {
        if model.builtIn { return true }
        guard let url = model.downloadedURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// True while a `Downloader` is registered AND actively downloading for the
    /// model (a finished/cancelled download removes the entry).
    private func isDownloading(_ model: NeuralNetworkModel) -> Bool {
        downloaders[model.fileName]?.isDownloading ?? false
    }

    // MARK: - Row reload helpers

    /// Reloads the cell for one model without disturbing selection.
    private func reloadRow(for fileName: String) {
        guard let row = models.firstIndex(where: { $0.fileName == fileName }) else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integer: 0))
    }

    /// Reloads all rows (used after availability changes / on appear).
    private func reloadVisibleRows() {
        tableView.reloadData()
    }

    // MARK: - Download

    /// Starts (or no-ops if already running) a download for `model`, wiring a
    /// progress observer that reloads the model's row on every `Downloader`
    /// mutation, and a completion that pre-hashes the file (mirrors iOS) so the
    /// first launch can build the CoreML cache key without re-hashing.
    private func startDownload(_ model: NeuralNetworkModel) {
        guard !model.builtIn,
              !isDownloading(model),
              let destinationURL = model.downloadedURL,
              let sourceURL = URL(string: model.url) else { return }

        let downloader = Downloader(destinationURL: destinationURL)
        downloader.onDownloadComplete = { url in
            // Pre-hash off the main thread so the first engine launch that selects
            // this model can construct its CoreML cache key without re-hashing on
            // the hot path (mirrors `ModelDetailView.onAppear`).
            Task.detached(priority: .userInitiated) {
                _ = try? await BinFileHasher.shared.identityForDownloadedFile(url)
            }
        }
        downloaders[model.fileName] = downloader

        // Observe progress / completion and reflect it on the row.
        trackDownloader(downloader, fileName: model.fileName)

        Task { @MainActor in
            try? await downloader.download(from: sourceURL)
        }
        reloadRow(for: model.fileName)
    }

    /// Cancels and drops a model's in-flight download.
    private func cancelDownload(_ model: NeuralNetworkModel) {
        guard let downloader = downloaders[model.fileName] else { return }
        downloader.cancel()
        downloaders.removeValue(forKey: model.fileName)
        reloadRow(for: model.fileName)
    }

    /// Cancels every in-flight download (called on window close).
    func cancelAllDownloads() {
        for downloader in downloaders.values {
            downloader.cancel()
        }
        downloaders.removeAll()
    }

    /// Self-rescheduling observation of one `Downloader`'s `progress` /
    /// `isDownloading`. On each mutation it reloads the row; when a download stops
    /// it recomputes availability, drops the finished downloader, and (if the
    /// finished model is the one shown in the detail pane) refreshes that pane.
    ///
    /// Same `withObservationTracking` contract as `MainWindowController`: the
    /// callback fires once per change BEFORE the value commits, so we hop to a
    /// `Task { @MainActor }` to read the committed value and RE-ARM tracking
    /// (otherwise observation stops after the first change). Tracking ends
    /// naturally once the downloader is removed from `downloaders` (a stale entry
    /// no longer reloads any row and is GC'd when the closure releases it).
    private func trackDownloader(_ downloader: Downloader, fileName: String) {
        withObservationTracking {
            _ = downloader.progress
            _ = downloader.isDownloading
        } onChange: { [weak self, weak downloader] in
            Task { @MainActor in
                guard let self, let downloader else { return }
                // Only keep observing while this is still the registered downloader
                // for the file (a cancel/replace drops it).
                guard self.downloaders[fileName] === downloader else { return }

                if downloader.isDownloading {
                    // Mid-download progress tick: refresh the row's progress bar.
                    self.reloadRow(for: fileName)
                    self.trackDownloader(downloader, fileName: fileName)
                } else {
                    // Finished or cancelled. If the file landed, the model is now
                    // available. Drop the downloader, recompute, and refresh.
                    self.downloaders.removeValue(forKey: fileName)
                    self.recomputeAvailability()
                    self.reloadRow(for: fileName)
                    // Keep the detail pane's set-active button in sync if it shows
                    // this model.
                    if self.selectedModel?.fileName == fileName {
                        self.rebuildDetailPane()
                    }
                }
            }
        }
    }

    // MARK: - Delete

    /// Confirms, then removes a downloaded (non-built-in) model's file, mirroring
    /// the iOS `ModelTrashButton`. On success, recomputes availability and
    /// refreshes the row + detail pane.
    private func deleteModel(_ model: NeuralNetworkModel) {
        guard !model.builtIn, let url = model.downloadedURL else { return }

        let alert = NSAlert()
        alert.messageText = "Remove “\(model.title)”?"
        alert.informativeText =
            "This deletes the downloaded network file. You can download it again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            try? FileManager.default.removeItem(at: url)
            self.recomputeAvailability()
            self.reloadRow(for: model.fileName)
            if self.selectedModel?.fileName == model.fileName {
                self.rebuildDetailPane()
            }
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    // MARK: - Set active

    /// Sets a downloaded model as the active net (routes to `relaunch(model:)`).
    /// No-op for an unavailable model.
    private func setActive(_ model: NeuralNetworkModel) {
        guard availability[model.fileName] == true else { return }
        onSetActive(model)
        // Re-draw the table so the "Active" badge moves to this row.
        reloadVisibleRows()
        rebuildDetailPane()
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < models.count else { return }
        let model = models[row]
        if availability[model.fileName] == true {
            setActive(model)
        }
    }

    // MARK: - Detail pane (P5-T8)

    /// The model whose detail pane is shown (the selected row).
    private var selectedModel: NeuralNetworkModel? {
        let row = tableView.selectedRow
        guard row >= 0, row < models.count else { return nil }
        return models[row]
    }

    /// Rebuilds the backend-config pane for the current selection. Called on
    /// selection change. (macOS has no backend picker — the engine runs a fixed
    /// GPU+ANE mux — so the pane no longer rebuilds on a backend flip.)
    private func rebuildDetailPane() {
        backendPane?.removeFromSuperview()
        backendPane = nil

        guard let model = selectedModel else { return }

        let pane = ModelBackendPaneView(model: model)
        pane.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            pane.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        backendPane = pane
    }
}

// MARK: - NSTableViewDataSource

extension ModelsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        models.count
    }
}

// MARK: - NSTableViewDelegate

extension ModelsViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row >= 0, row < models.count else { return nil }
        let model = models[row]

        let cell: ModelRowView
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self)
            as? ModelRowView {
            cell = reused
        } else {
            cell = ModelRowView()
            cell.identifier = Self.cellIdentifier
        }

        cell.configure(
            model: model,
            isActive: model.title == currentModelTitle(),
            isAvailable: availability[model.fileName] ?? false,
            isReady: readyFileNames.contains(model.fileName),
            downloader: downloaders[model.fileName],
            onDownload: { [weak self] in self?.startDownload(model) },
            onCancel: { [weak self] in self?.cancelDownload(model) },
            onDelete: { [weak self] in self?.deleteModel(model) },
            onSetActive: { [weak self] in self?.setActive(model) }
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        rebuildDetailPane()
    }
}
