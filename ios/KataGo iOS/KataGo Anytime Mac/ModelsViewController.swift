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
import UniformTypeIdentifiers

@MainActor
final class ModelsViewController: NSViewController {

    // MARK: - Inputs

    /// Title of the active model (for the "Active" badge). A closure so the badge
    /// re-reads the live selection on every reload (e.g. after a relaunch).
    private let currentModelTitle: () -> String

    /// Invoked when the user chooses a downloaded model as the active net.
    private let onSetActive: (NeuralNetworkModel) -> Void

    // MARK: - Data

    /// One line of the table. The catalog is a flat run of models followed by a
    /// "Custom Networks" group header and the user's imports. The header is
    /// shown even with no imports, so the +/- control below has something it
    /// visibly belongs to.
    private enum Row {
        case group(String)
        case model(NeuralNetworkModel)
    }

    private var rows: [Row] = []

    /// Every model currently listed, catalog and custom, for the availability
    /// bookkeeping that is keyed by fileName rather than by row.
    private var models: [NeuralNetworkModel] {
        rows.compactMap { if case .model(let model) = $0 { return model } else { return nil } }
    }

    /// Rebuilds `rows` from the catalog plus the current custom-network records.
    /// Unlike the catalog, that second list changes at runtime, so this runs on
    /// appear and after every add or delete.
    private func rebuildRows() {
        var next: [Row] = NeuralNetworkModel.allCases.filter { $0.visible }.map { Row.model($0) }
        next.append(.group("Custom Networks"))
        next.append(contentsOf: CustomModelStore().models.filter { $0.visible }.map { Row.model($0) })
        rows = next
    }

    /// The model on `row`, or nil for a group header / out-of-range index.
    private func model(atRow row: Int) -> NeuralNetworkModel? {
        guard rows.indices.contains(row), case .model(let model) = rows[row] else { return nil }
        return model
    }

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
    /// Add / remove for custom networks, under the table — the standard AppKit
    /// place for list-editing affordances.
    private let addRemoveControl = NSSegmentedControl()

    /// The in-flight import, so the progress sheet's Cancel can stop it.
    private var importTask: Task<Void, Never>?
    private var importProgressController: ModelImportProgressViewController?

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("ModelRowCell")
    private static let groupCellIdentifier = NSUserInterfaceItemIdentifier("ModelGroupCell")

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

        addRemoveControl.translatesAutoresizingMaskIntoConstraints = false
        addRemoveControl.segmentCount = 2
        addRemoveControl.segmentStyle = .smallSquare
        addRemoveControl.trackingMode = .momentary
        addRemoveControl.setImage(NSImage(systemSymbolName: "plus",
                                          accessibilityDescription: "Add custom network"),
                                  forSegment: 0)
        addRemoveControl.setImage(NSImage(systemSymbolName: "minus",
                                          accessibilityDescription: "Remove custom network"),
                                  forSegment: 1)
        addRemoveControl.target = self
        addRemoveControl.action = #selector(addRemoveClicked(_:))

        // Table above, +/- beneath. The scroll view takes all the vertical
        // slack so the control stays pinned to the bottom of the left pane.
        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(scrollView)
        listContainer.addSubview(addRemoveControl)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            addRemoveControl.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            addRemoveControl.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor,
                                                      constant: 8),
            addRemoveControl.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor,
                                                     constant: -8),
        ])

        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(listContainer)
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
        rebuildRows()
        recomputeAvailability()
        tableView.reloadData()
        // Select the active model on open so the detail pane shows something.
        let activeRow = rows.firstIndex { row in
            if case .model(let model) = row { return model.title == currentModelTitle() }
            return false
        }
        let firstModelRow = rows.firstIndex { if case .model = $0 { return true } else { return false } }
        if let target = activeRow ?? firstModelRow {
            tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        }
        rebuildDetailPane()
        updateAddRemoveEnablement()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Re-check the list and availability each time the window is shown (a
        // model may have been deleted/added since the last appearance).
        rebuildRows()
        recomputeAvailability()
        reloadVisibleRows()
        updateAddRemoveEnablement()
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
        let index = rows.firstIndex { row in
            if case .model(let model) = row { return model.fileName == fileName }
            return false
        }
        guard let index else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: index),
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
        guard let model = model(atRow: tableView.clickedRow) else { return }
        if availability[model.fileName] == true {
            setActive(model)
        }
    }

    // MARK: - Custom networks

    @objc private func addRemoveClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            presentImportPanel()
        } else {
            deleteSelectedCustomModel()
        }
    }

    /// Remove is meaningful only for a selected custom network — a catalog
    /// entry is deleted from its own row button, which says "download again"
    /// rather than "gone for good".
    private func updateAddRemoveEnablement() {
        addRemoveControl.setEnabled(true, forSegment: 0)
        addRemoveControl.setEnabled(selectedModel?.isCustom == true, forSegment: 1)
    }

    private func presentImportPanel() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a KataGo network file."
        panel.prompt = "Add"
        // Permissive on purpose: a network is `.gz` by convention but may be a
        // plain `.bin`/`.txt`, and a strict filter greys out files that would
        // have worked. The importer's header check is what actually decides,
        // and it explains itself when it says no.
        panel.allowedContentTypes = [.gzip, .data]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.startImport(from: url)
        }
    }

    /// Copies the chosen file in behind a determinate progress sheet. The copy
    /// itself runs off the main actor (`importModel` is nonisolated async).
    private func startImport(from url: URL) {
        let progress = ModelImportProgressViewController()
        progress.onCancel = { [weak self] in self?.importTask?.cancel() }
        importProgressController = progress
        presentAsSheet(progress)

        importTask = Task { [weak self] in
            defer {
                self?.dismissImportProgress()
                self?.importTask = nil
            }
            do {
                // Capture the sheet, NOT self. The progress handler is a
                // nonisolated @Sendable closure, so `self` inside it is
                // task-isolated and handing it to a @MainActor closure is a
                // race; the sheet controller is @MainActor and therefore
                // Sendable, so it crosses cleanly.
                _ = try await CustomModelImporter.importModel(from: url) { fraction in
                    Task { @MainActor in progress.update(fraction: fraction) }
                }
                guard let self else { return }
                self.rebuildRows()
                self.recomputeAvailability()
                self.reloadVisibleRows()
                self.updateAddRemoveEnablement()
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
        alert.messageText = "Couldn't Add Network"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// Deletes the selected custom network: file, record, per-model settings
    /// and compiled Core ML artifacts.
    ///
    /// Allowed even when it is the running engine's network, matching what
    /// `deleteModel` already does for a downloaded catalog entry. Unlinking a
    /// file the engine has open is harmless — the inode outlives the link — and
    /// the stale title simply fails to resolve at the next launch, which falls
    /// back to the built-in net.
    private func deleteSelectedCustomModel() {
        guard let model = selectedModel, model.isCustom,
              let record = CustomModelStore().records.first(where: { $0.fileName == model.fileName })
        else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete “\(record.displayName)”?"
        alert.informativeText =
            "This removes the network file from this Mac, along with its settings. "
            + "You would need to add the file again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                await CustomModelImporter.delete(record)
                self.rebuildRows()
                self.recomputeAvailability()
                self.reloadVisibleRows()
                self.rebuildDetailPane()
                self.updateAddRemoveEnablement()
            }
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    /// Applies an edited name from the detail pane, adopting whatever the store
    /// returns — a collision with a catalog title or another custom network
    /// comes back suffixed.
    private func renameCustomModel(_ model: NeuralNetworkModel, to newName: String) {
        let store = CustomModelStore()
        guard let record = store.records.first(where: { $0.fileName == model.fileName }),
              newName.trimmingCharacters(in: .whitespacesAndNewlines) != record.displayName
        else { return }
        store.rename(id: record.id, to: newName)
        rebuildRows()
        reloadVisibleRows()
        rebuildDetailPane()
    }

    // MARK: - Detail pane (P5-T8)

    /// The model whose detail pane is shown (the selected row).
    private var selectedModel: NeuralNetworkModel? {
        model(atRow: tableView.selectedRow)
    }

    /// Rebuilds the backend-config pane for the current selection. Called on
    /// selection change. (macOS has no backend picker — the engine runs a fixed
    /// GPU+ANE mux — so the pane no longer rebuilds on a backend flip.)
    private func rebuildDetailPane() {
        backendPane?.removeFromSuperview()
        backendPane = nil

        guard let model = selectedModel else { return }

        let pane = ModelBackendPaneView(model: model) { [weak self] newName in
            self?.renameCustomModel(model, to: newName)
        }
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
        rows.count
    }
}

// MARK: - NSTableViewDelegate

extension ModelsViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .group = rows[row] { return true }
        return false
    }

    /// Group headers are labels, not choices — selecting one would blank the
    /// detail pane and disable the remove button for no reason.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        model(atRow: row) != nil
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }

        if case .group(let title) = rows[row] {
            let label: NSTextField
            if let reused = tableView.makeView(withIdentifier: Self.groupCellIdentifier, owner: self)
                as? NSTextField {
                label = reused
            } else {
                label = NSTextField(labelWithString: "")
                label.identifier = Self.groupCellIdentifier
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                label.textColor = .secondaryLabelColor
            }
            label.stringValue = title
            return label
        }

        guard let model = model(atRow: row) else { return nil }

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
        updateAddRemoveEnablement()
    }
}

// MARK: - Import progress sheet

/// Determinate progress for a custom-network copy. Determinate because the file
/// can be hundreds of megabytes, where an indeterminate spinner is
/// indistinguishable from a hang.
@MainActor
final class ModelImportProgressViewController: NSViewController {

    var onCancel: (() -> Void)?

    private let progressIndicator = NSProgressIndicator()
    private let percentLabel = NSTextField(labelWithString: "0%")

    override func loadView() {
        let title = NSTextField(labelWithString: "Adding Network")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.doubleValue = 0

        percentLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                       weight: .regular)
        percentLabel.textColor = .secondaryLabelColor

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [title, progressIndicator, percentLabel, cancelButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 260),
        ])
        view = container
    }

    func update(fraction: Double) {
        progressIndicator.doubleValue = min(1, max(0, fraction)) * 100
        percentLabel.stringValue = "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}
