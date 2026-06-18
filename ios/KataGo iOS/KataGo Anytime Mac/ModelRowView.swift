//
//  ModelRowView.swift
//  KataGo Anytime Mac
//
//  Two AppKit views for the Models window (P5-T7 + P5-T8):
//
//    • `ModelRowView` — a view-based `NSTableCellView` for one catalog model:
//      bold title + secondary description, file size, a status area (Active
//      badge / Downloaded / Not downloaded), and the trailing controls
//      (download or set-active button, an inline progress bar + cancel while
//      downloading, and a trash button for a downloaded non-built-in model).
//      Mirrors the iOS `ModelDetailView` tri-state + `ModelTrashButton`.
//
//    • `ModelBackendPaneView` — the per-model engine-config detail pane,
//      built from `ConfigFormBuilder` rows backed by `BackendSettings`. macOS
//      runs a fixed 1 GPU + 2 ANE mux (no backend picker), so the pane exposes
//      only the MLX/GPU-side controls (max board size + autotuning + re-tune),
//      using the SAME per-model UserDefaults keys as iOS. Each change persists
//      immediately via the `BackendSettings` setters; the pane shows a
//      "Changes apply when this model is next loaded." note rather than forcing
//      a relaunch on every tweak (see the type doc).
//

import AppKit
import KataGoUICore

// MARK: - ModelRowView

/// One catalog model row. The owning controller reconfigures it on every reload
/// with the model's live availability / download / active state and the action
/// closures; the cell wires those closures to its controls.
@MainActor
final class ModelRowView: NSTableCellView {

    private let titleField = NSTextField(labelWithString: "")
    private let descriptionField = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    /// The primary trailing button: "Set Active" (downloaded) or a download
    /// arrow (not downloaded). Hidden while downloading (the cancel button +
    /// progress bar take over).
    private let primaryButton = NSButton()
    private let cancelButton = NSButton()
    private let trashButton = NSButton()

    /// Byte-count formatter for the file size, matching the macOS convention
    /// (the iOS app rolls its own `humanFileSize`; `ByteCountFormatter` is the
    /// native equivalent and is what the spec calls for).
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    // Action closures (replaced on each `configure`).
    private var onDownload: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var onDelete: (() -> Void)?
    private var onSetActive: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setup() {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        addSubview(titleField)
        textField = titleField

        descriptionField.translatesAutoresizingMaskIntoConstraints = false
        descriptionField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptionField.textColor = .secondaryLabelColor
        descriptionField.lineBreakMode = .byTruncatingTail
        descriptionField.maximumNumberOfLines = 2
        descriptionField.cell?.wraps = true
        addSubview(descriptionField)

        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeField.textColor = .secondaryLabelColor
        addSubview(sizeField)

        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusField.alignment = .right
        addSubview(statusField)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.isHidden = true
        addSubview(progressIndicator)

        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.bezelStyle = .rounded
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        addSubview(primaryButton)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.image = NSImage(systemSymbolName: "stop.fill",
                                     accessibilityDescription: "Cancel download")
        cancelButton.imagePosition = .imageOnly
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.isHidden = true
        addSubview(cancelButton)

        trashButton.translatesAutoresizingMaskIntoConstraints = false
        trashButton.bezelStyle = .rounded
        trashButton.image = NSImage(systemSymbolName: "trash",
                                    accessibilityDescription: "Remove download")
        trashButton.imagePosition = .imageOnly
        trashButton.target = self
        trashButton.action = #selector(trashTapped)
        trashButton.isHidden = true
        addSubview(trashButton)

        // The text block hugs the leading edge; the controls dock trailing.
        primaryButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        trashButton.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            statusField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            statusField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor,
                                                 constant: 8),

            descriptionField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            descriptionField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),
            descriptionField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            sizeField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            sizeField.topAnchor.constraint(equalTo: descriptionField.bottomAnchor, constant: 4),

            progressIndicator.leadingAnchor.constraint(equalTo: sizeField.trailingAnchor, constant: 12),
            progressIndicator.centerYAnchor.constraint(equalTo: primaryButton.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 90),

            cancelButton.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 8),
            cancelButton.centerYAnchor.constraint(equalTo: primaryButton.centerYAnchor),

            trashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trashButton.centerYAnchor.constraint(equalTo: primaryButton.centerYAnchor),

            primaryButton.topAnchor.constraint(equalTo: sizeField.bottomAnchor, constant: 6),
            primaryButton.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            primaryButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    /// Reconfigures the cell from the model's live state + action closures.
    ///
    /// - Parameters:
    ///   - isActive: the model is the currently-active net (draws "Active").
    ///   - isAvailable: the file exists on disk (or is built-in).
    ///   - isReady: P5-T10 CoreML-cache-ready seam (unused until T10).
    ///   - downloader: the in-flight downloader, if any (drives the progress bar).
    func configure(model: NeuralNetworkModel,
                   isActive: Bool,
                   isAvailable: Bool,
                   isReady: Bool,
                   downloader: Downloader?,
                   onDownload: @escaping () -> Void,
                   onCancel: @escaping () -> Void,
                   onDelete: @escaping () -> Void,
                   onSetActive: @escaping () -> Void) {
        self.onDownload = onDownload
        self.onCancel = onCancel
        self.onDelete = onDelete
        self.onSetActive = onSetActive

        titleField.stringValue = model.title
        descriptionField.stringValue = Self.shortDescription(model.description)
        sizeField.stringValue = model.builtIn
            ? "Built-in"
            : Self.byteFormatter.string(fromByteCount: Int64(model.fileSize))

        let isDownloading = downloader?.isDownloading ?? false

        // Status text: Active > Downloaded > Not downloaded. (The P5-T10 "Ready"
        // badge will refine the Downloaded state.)
        if isActive {
            statusField.stringValue = "Active"
            statusField.textColor = .systemGreen
        } else if isDownloading {
            statusField.stringValue = "Downloading…"
            statusField.textColor = .secondaryLabelColor
        } else if isAvailable {
            statusField.stringValue = isReady ? "Ready" : "Downloaded"
            statusField.textColor = .secondaryLabelColor
        } else {
            statusField.stringValue = "Not downloaded"
            statusField.textColor = .secondaryLabelColor
        }

        // Controls: while downloading show the progress bar + cancel; otherwise
        // show "Set Active" (available) or a download arrow (not available).
        progressIndicator.isHidden = !isDownloading
        cancelButton.isHidden = !isDownloading
        if isDownloading {
            progressIndicator.doubleValue = downloader?.progress ?? 0
        }

        primaryButton.isHidden = isDownloading
        if isAvailable {
            primaryButton.image = NSImage(systemSymbolName: "play.fill",
                                          accessibilityDescription: "Set active")
            primaryButton.title = "  Set Active"
            primaryButton.imagePosition = .imageLeading
            // Disable the set-active button for the already-active model.
            primaryButton.isEnabled = !isActive
        } else {
            primaryButton.image = NSImage(systemSymbolName: "arrow.down",
                                          accessibilityDescription: "Download")
            primaryButton.title = "  Download"
            primaryButton.imagePosition = .imageLeading
            primaryButton.isEnabled = true
        }

        // Trash: only a downloaded, non-built-in model that isn't downloading.
        trashButton.isHidden = !(isAvailable && !model.builtIn && !isDownloading)
    }

    /// Trims the catalog description to a one/two-line teaser for the row (the
    /// full text is long; the detail pane / iOS picker shows it in full).
    private static func shortDescription(_ full: String) -> String {
        let firstLine = full.split(separator: "\n", maxSplits: 1,
                                   omittingEmptySubsequences: true).first.map(String.init) ?? full
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func primaryTapped() {
        // Primary acts as download (unavailable) or set-active (available); the
        // owning controller's closure already encodes which, keyed off the same
        // availability the cell rendered.
        if primaryButton.title.contains("Download") {
            onDownload?()
        } else {
            onSetActive?()
        }
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func trashTapped() { onDelete?() }
}

// MARK: - ModelBackendPaneView (P5-T8)

/// Per-model backend-config pane. Full parity with the iOS `BackendConfigSheet`,
/// built from `ConfigFormBuilder` rows backed by a `BackendSettings`. Every
/// control's `onChange` writes straight through the matching `BackendSettings`
/// setter, which persists to the SAME per-model UserDefaults keys iOS uses.
///
/// Apply policy: changes persist immediately and take effect the next time this
/// model is loaded (the engine reads `BackendSettings` at launch in
/// `MainWindowController.startEngineAndSession`). The pane shows a
/// "Changes apply when this model is next loaded." note rather than forcing a
/// relaunch on every tweak. (Selecting the model as Active from the table is the
/// explicit relaunch path.)
///
/// macOS has no backend picker: the engine always runs the fixed 1 GPU + 2 ANE
/// mux (`MainWindowController.engineDeviceAssignments`). The pane therefore shows
/// only the MLX/GPU-side controls (max board size + Winograd autotuning), which
/// govern the engine-wide NN buffer geometry and the GPU server thread.
@MainActor
final class ModelBackendPaneView: NSView {

    private let model: NeuralNetworkModel
    private var settings: BackendSettings

    init(model: NeuralNetworkModel) {
        self.model = model
        self.settings = BackendSettings(model: model)
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

        // Model title header.
        let header = NSTextField(labelWithString: model.title)
        header.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        header.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(header)

        // Engine summary: macOS always runs the fixed 1 GPU + 2 ANE mux, so
        // there is no backend picker. The controls below tune the MLX/GPU side
        // of that mux (board geometry + Winograd autotuning).
        stack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Engine"))
        stack.addArrangedSubview(note(
            "Runs a fixed mux of 1 GPU + 2 Neural Engine threads for best throughput."))

        // Max board size — drives the engine-wide NN buffer geometry (both the
        // GPU and ANE server threads convert/allocate to this size) and the size
        // the Winograd tuner optimizes for.
        let sizeOptions = BoardSizeChoice.allCases.map { $0.label }
        stack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Max Board Size"))
        let sizeIndex = BoardSizeChoice.allCases.firstIndex(of: settings.mlxBoardSize) ?? 0
        let sizeRow = ConfigFormBuilder.popupRow(
            title: "Board Size",
            options: sizeOptions,
            selectedIndex: sizeIndex
        ) { [weak self] idx in
            guard let self, BoardSizeChoice.allCases.indices.contains(idx) else { return }
            self.settings.mlxBoardSize = BoardSizeChoice.allCases[idx]
        }
        stack.addArrangedSubview(sizeRow)
        stack.addArrangedSubview(note(
            "Largest board the engine can play and the size the GPU tuner optimizes for."))

        // Autotuning (drives the MLX/GPU server thread).
        stack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Performance Tuning"))
        let autotuneRow = ConfigFormBuilder.popupRow(
            title: "Autotuning",
            options: ["Fast", "Full"],
            selectedIndex: settings.tunerFull ? 1 : 0
        ) { [weak self] idx in
            self?.settings.tunerFull = (idx == 1)
        }
        stack.addArrangedSubview(autotuneRow)

        let reTuneRow = ConfigFormBuilder.checkboxRow(
            title: "Re-tune on next load",
            isOn: settings.reTune
        ) { [weak self] isOn in
            self?.settings.reTune = isOn
        }
        stack.addArrangedSubview(reTuneRow)
        stack.addArrangedSubview(note(
            "Fast tunes a coarse grid in seconds; Full is more thorough but much "
            + "slower on device. Re-tune discards the cached tuning once, the next "
            + "time this model loads."))

        // Apply-on-next-load note.
        let applyNote = note("Changes apply when this model is next loaded.")
        applyNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        stack.addArrangedSubview(applyNote)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    /// A small wrapped secondary-text note label.
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        return label
    }
}
