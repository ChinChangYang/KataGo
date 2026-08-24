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
//  reusing the SAME building blocks: `NeuralNetworkModel.allCases`,
//  `DownloadCenter`, `BackendSettings`, and `ConfigFormBuilder`. No logic is
//  reimplemented.
//
//  Download lifecycle
//  ------------------
//  Downloads belong to the app-wide `DownloadCenter`, keyed by destination
//  URL; this controller only mirrors one onto a row. Progress reaches the row
//  through a self-rescheduling `withObservationTracking` observer (the same
//  pattern `MainWindowController` uses), which reloads just the affected row.
//  On completion the verified file lands at `downloadedURL` and the row flips
//  to its "Downloaded" state. Closing the window calls
//  `detachDownloadObservation()`, which stops the mirror and nothing else —
//  the transfer keeps running and reopening the window picks it back up.
//
//  Set active
//  ----------
//  Choosing a downloaded model (the row's Play button, or double-click)
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
        // `attachDownloadObservation()` reloads the table itself, so this does
        // not also call `reloadVisibleRows()` — one `reloadData()` per
        // appearance, not two.
        rebuildRows()
        recomputeAvailability()
        updateAddRemoveEnablement()
        attachDownloadObservation()
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

    private func download(for model: NeuralNetworkModel) -> Download? {
        model.downloadedURL.map { DownloadCenter.shared.download(for: $0) }
    }

    /// True while a transfer for this model is running or queued. A paused
    /// download is deliberately not "downloading" — its row offers to resume.
    private func isDownloading(_ model: NeuralNetworkModel) -> Bool {
        download(for: model)?.isBusy ?? false
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

    /// Starts, or resumes, the download for `model`. The center refuses a
    /// duplicate by construction (it keys downloads by destination), so the
    /// guard here is about not re-arming a second observer.
    private func startDownload(_ model: NeuralNetworkModel) {
        guard !model.builtIn,
              !isDownloading(model),
              let entry = download(for: model),
              let sourceURL = URL(string: model.url) else { return }

        DownloadCenter.shared.start(entry, from: sourceURL)
        track(entry, fileName: model.fileName)
        reloadRow(for: model.fileName)
    }

    /// Pauses a model's transfer. The partial survives; the row's download
    /// arrow resumes it.
    private func cancelDownload(_ model: NeuralNetworkModel) {
        guard let entry = download(for: model) else { return }
        DownloadCenter.shared.pause(entry)
        reloadRow(for: model.fileName)
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
        for model in models {
            guard let entry = download(for: model), entry.state != .succeeded else { continue }
            track(entry, fileName: model.fileName)
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
                    self.recomputeAvailability()
                    self.reloadRow(for: fileName)
                    if self.selectedModel?.fileName == fileName {
                        self.rebuildDetailPane()
                    }
                    return
                }
                self.rearm(entry, fileName: fileName, generation: generation)
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
                let record = try await CustomModelImporter.importModel(from: url) { fraction in
                    Task { @MainActor in progress.update(fraction: fraction) }
                }
                guard let self else { return }
                self.rebuildRows()
                self.recomputeAvailability()
                self.reloadVisibleRows()
                // Reveal what was just added: the catalog is long enough that
                // the reloaded table lands back at the top with the new row
                // well below the fold, which reads as nothing having happened.
                self.selectRow(forFileName: record.fileName)
                self.rebuildDetailPane()
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
        // Keep the renamed network selected. `reloadData()` drops the
        // selection, which would empty the detail pane the user is editing in
        // and leave the remove button enabled with nothing selected.
        selectRow(forFileName: model.fileName)
        rebuildDetailPane()
        updateAddRemoveEnablement()
    }

    /// Re-selects the row for `fileName` and scrolls it into view. Needed after
    /// any `reloadData()`, which clears selection, and after an import, where
    /// the table otherwise returns to the top with the new row out of sight.
    private func selectRow(forFileName fileName: String) {
        let index = rows.firstIndex { row in
            if case .model(let model) = row { return model.fileName == fileName }
            return false
        }
        guard let index else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
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
            download: download(for: model),
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

    /// The sheet's headline. Networks say "Adding Network" (the default);
    /// the opening-books window passes "Importing Book".
    var titleText = "Adding Network"

    private let progressIndicator = NSProgressIndicator()
    private let percentLabel = NSTextField(labelWithString: "0%")

    override func loadView() {
        let title = NSTextField(labelWithString: titleText)
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
