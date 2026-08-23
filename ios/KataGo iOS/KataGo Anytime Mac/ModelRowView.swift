//
//  ModelRowView.swift
//  KataGo Anytime Mac
//
//  Two AppKit views for the Models window (P5-T7 + P5-T8):
//
//    • `ModelRowView` — a view-based `NSTableCellView` for one catalog model:
//      bold title + secondary description, file size, a status area (Active
//      badge / Downloading… / Paused / Downloaded / Not downloaded), and the
//      trailing controls (a primary button whose label, glyph and routing all
//      come from the shared `DownloadButtonRole` — Play / Download / Resume
//      Download — an inline progress bar shown while downloading OR paused, a
//      cancel button shown only while actively downloading, and a trash button
//      for a downloaded non-built-in model). The button and the bar are
//      visible TOGETHER only in the Paused state, so a dedicated constraint
//      keeps the button from running under the bar (see
//      `primaryButtonTrailingConstraint`).
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
    private let descriptionField = NSTextField(wrappingLabelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    /// The primary trailing button. Its label, glyph and action all come from
    /// `DownloadButtonRole`: "Play" (downloaded — makes this the active net),
    /// "Download" (nothing on disk), or "Resume Download" (stopped with bytes
    /// already on disk — tapping it re-enters `startDownload`, which the
    /// center resumes from where it stopped). Download and Resume share a
    /// glyph and must NOT share a label; that difference is the whole reason
    /// the role lives in one place.
    /// Hidden only while actively downloading, when the cancel button +
    /// progress bar take over; visible ALONGSIDE the progress bar while
    /// paused (see `primaryButtonTrailingConstraint`).
    private let primaryButton = NSButton()
    private let cancelButton = NSButton()
    private let trashButton = NSButton()

    /// Caps `primaryButton`'s trailing edge at the progress bar's leading
    /// edge. Only ACTIVATED for the Paused state, the one state where both
    /// are visible at once (`configure(...)` toggles `isActive`); left
    /// inactive everywhere else, so it cannot change the width the button
    /// already shipped with when downloading/downloaded/active/not-downloaded
    /// hide the bar. Without it, `primaryButton` has no trailing constraint at
    /// all and its label runs directly under the bar — worse, since it is
    /// added to the view AFTER the bar, it then draws on top of it.
    private var primaryButtonTrailingConstraint: NSLayoutConstraint!

    /// The role `configure(...)` last rendered. `primaryTapped` dispatches on
    /// it rather than sniffing the button's own title, which stops the routing
    /// from depending on label text.
    private var primaryRole: DownloadButtonRole = .download

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
        // A wrapping label that grows to two lines then ellipsizes. The row is a
        // teaser; the full text lives in the detail pane (see `shortDescription`).
        // `wrappingLabelWithString` already sets `.byWordWrapping`; pairing that
        // with `truncatesLastVisibleLine` ellipsizes the second line. (A plain
        // `.byTruncatingTail` here would force a SINGLE truncated line — NSCell
        // tail-truncation is inherently single-line — which is why the row only
        // ever showed one line.)
        descriptionField.maximumNumberOfLines = 2
        descriptionField.cell?.truncatesLastVisibleLine = true
        descriptionField.isSelectable = false
        addSubview(descriptionField)

        // Reserve two lines for the teaser. `NSTableView` automatic row heights
        // measure a wrapping label at a single line (its wrapping width isn't
        // resolved until after the sizing pass), so without a fixed height the row
        // collapses to one line. Size the box to two line heights plus the cell's
        // vertical text insets: `truncatesLastVisibleLine` counts visible lines
        // from the bounds height, so a box of exactly 2×lineHeight (no inset
        // slack) would collapse back to one line. Display wrapping uses the
        // field's resolved frame width, so no `preferredMaxLayoutWidth` is needed.
        let descLineHeight = NSLayoutManager().defaultLineHeight(for: descriptionField.font!)
        descriptionField.heightAnchor.constraint(equalToConstant: ceil(descLineHeight * 2) + 8).isActive = true

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

        // Built but left INACTIVE here — `configure(...)` activates it only
        // for the Paused state. See the property doc.
        primaryButtonTrailingConstraint = primaryButton.trailingAnchor.constraint(
            lessThanOrEqualTo: progressIndicator.leadingAnchor, constant: -8)

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
    ///   - download: the download for this model, if it has a destination
    ///     (drives the progress bar and the Paused state).
    func configure(model: NeuralNetworkModel,
                   isActive: Bool,
                   isAvailable: Bool,
                   isReady: Bool,
                   download: Download?,
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

        let state = download?.state ?? .idle
        let isDownloading = download?.isBusy ?? false
        // One shared rule for what the button is, the same one iOS and
        // visionOS ask. Re-deriving it by hand here is what left the macOS
        // paused button telling VoiceOver "Download" where iOS says "Resume
        // Download" — the distinction `DownloadButtonRole` exists to keep.
        let role = DownloadButtonRole.role(isOnDisk: isAvailable,
                                           state: state,
                                           hasPartial: download?.hasPartial ?? false)
        // A paused download still has bytes on disk, and a bar frozen where it
        // stopped is the only thing that tells the user resuming is cheap.
        // That is exactly `.resume`, so read it off the role rather than
        // spelling the rule out a second time.
        let isPaused = (role == .resume)

        // Status text: Active > Downloading > Paused > Downloaded.
        if isActive {
            statusField.stringValue = "Active"
            statusField.textColor = .systemGreen
        } else if isDownloading {
            statusField.stringValue = "Downloading…"
            statusField.textColor = .secondaryLabelColor
        } else if isPaused {
            statusField.stringValue = "Paused"
            statusField.textColor = .secondaryLabelColor
        } else if isAvailable {
            statusField.stringValue = isReady ? "Ready" : "Downloaded"
            statusField.textColor = .secondaryLabelColor
        } else {
            statusField.stringValue = "Not downloaded"
            statusField.textColor = .secondaryLabelColor
        }

        // Controls: the bar shows while downloading AND while paused; only a
        // live transfer can be stopped.
        progressIndicator.isHidden = !(isDownloading || isPaused)
        cancelButton.isHidden = !isDownloading
        if isDownloading || isPaused {
            progressIndicator.doubleValue = download?.progress ?? 0
        }

        // Paused is the only state where the button and the bar are both
        // visible at once — cap the button's width only then, so every other
        // state's layout is byte-for-byte what it was before Paused existed.
        primaryButtonTrailingConstraint.isActive = isPaused

        primaryButton.isHidden = isDownloading
        primaryRole = role
        primaryButton.image = NSImage(systemSymbolName: role.systemImageName,
                                      accessibilityDescription: role.actionTitle)
        primaryButton.title = "  " + role.actionTitle
        primaryButton.imagePosition = .imageLeading
        // Disable the activate button for the already-active model; every
        // other role is always tappable.
        primaryButton.isEnabled = !(role == .play && isActive)

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
        // Dispatch on the role the cell rendered, not on its label text: two
        // of the four roles now say "Download" in their title.
        switch primaryRole {
        case .play:
            onSetActive?()
        case .download, .resume:
            onDownload?()
        case .pause:
            // Unreachable: the button is hidden while a transfer is running or
            // queued, and `cancelButton` takes over. Routed anyway so the
            // switch says what the role means rather than swallowing it.
            onCancel?()
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
/// mux (`EngineDeviceAssignments.platformMux`). The pane therefore shows only the
/// MLX/GPU-side controls (max board size + Winograd autotuning), which govern the
/// engine-wide NN buffer geometry and the GPU server thread.
@MainActor
final class ModelBackendPaneView: NSView {

    private let model: NeuralNetworkModel
    private var settings: BackendSettings
    /// Set only for a user-imported network, whose name the user owns. Called
    /// with the edited text when the field commits (Return, Tab or focus loss).
    private let onRename: ((String) -> Void)?

    init(model: NeuralNetworkModel, onRename: ((String) -> Void)? = nil) {
        self.model = model
        self.settings = BackendSettings(model: model)
        self.onRename = onRename
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func nameCommitted(_ sender: NSTextField) {
        onRename?(sender.stringValue)
    }

    private func build() {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        // Model title header. A catalog entry's title is fixed; a user-imported
        // network's is theirs to edit, so it becomes a live field. NSTextField
        // sends its action on Return, Tab and focus loss, which covers every way
        // a user finishes typing a name.
        if model.isCustom, onRename != nil {
            let nameField = NSTextField(string: model.title)
            nameField.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
            nameField.translatesAutoresizingMaskIntoConstraints = false
            nameField.target = self
            nameField.action = #selector(nameCommitted(_:))
            nameField.setAccessibilityLabel("Network name")
            stack.addArrangedSubview(nameField)
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                             constant: -28).isActive = true
        } else {
            let header = NSTextField(labelWithString: model.title)
            header.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
            header.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(header)
        }

        // Full model description — parity with the iOS `ModelDetailView`, which
        // shows the complete text (the table row only shows a one/two-line
        // teaser). It wraps to the pane width; the whole pane scrolls (see
        // `build()`'s scroll view) so even the longest multi-paragraph
        // description stays fully readable regardless of window height.
        if !model.description.isEmpty {
            let description = NSTextField(wrappingLabelWithString: model.description)
            description.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            description.textColor = .secondaryLabelColor
            description.isSelectable = true
            description.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(description)
            description.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                               constant: -28).isActive = true
        }

        // Engine summary: macOS always runs the fixed 1 GPU + 2 ANE mux, so
        // there is no backend picker. The controls below tune the MLX/GPU side
        // of that mux (board geometry + Winograd autotuning).
        stack.addArrangedSubview(ConfigFormBuilder.sectionHeader("Engine"))
        stack.addArrangedSubview(note(
            "Runs a fixed mux of 1 GPU + 2 Neural Engine threads for best throughput."))

        // Max board size — drives the engine-wide NN buffer geometry (both the
        // GPU and ANE server threads convert/allocate to this size) and the size
        // the Winograd tuner optimizes for.
        //
        // SPAWN-TIME ONLY on macOS, deliberately: changing it here writes the
        // per-model setting and nothing else, so the running engine keeps the
        // buffer it launched with until the next load (the "Changes apply when
        // this model is next loaded" note at the foot of this pane covers it).
        // visionOS/tvOS quit and respawn the engine on this setting; macOS does
        // not, because a relaunch here would tear down an engine the user is
        // mid-analysis on with no warning. Until the next load, a board bigger
        // than the LAUNCHED cap is reported as *Held* on the board's status
        // line — never as a lost board.
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

        // Host the stack in a vertical scroll view so the combined description +
        // config is always fully reachable, however long the description or short
        // the window. The document view's width tracks the clip view (no
        // horizontal scroll — content wraps), its height grows with the stack.
        // It is flipped (top-left origin) so the scroll view shows the content
        // from the TOP — a default bottom-left view would reveal the end of a
        // long description first.
        let documentView = FlippedView()
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

// MARK: - FlippedView

/// A top-left-origin container used as the backend pane's scroll document view so
/// content lays out and scrolls from the top (AppKit's default bottom-left origin
/// would otherwise reveal the end of a long description first).
@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
