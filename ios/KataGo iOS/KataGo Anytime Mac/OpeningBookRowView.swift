//
//  OpeningBookRowView.swift
//  KataGo Anytime Mac
//
//  A view-based NSTableCellView for one downloadable opening book: bold title,
//  file size, a status area (Downloaded / Downloading… / Not downloaded), and
//  trailing controls (a download button, an inline progress bar + cancel while
//  downloading, and a trash button for a downloaded book). The AppKit analogue
//  of the iOS `OpeningBookDetailView` tri-state + `OpeningBookTrashButton`.
//

import AppKit
import KataGoUICore

@MainActor
final class OpeningBookRowView: NSTableCellView {

    private let titleField = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let primaryButton = NSButton()
    private let cancelButton = NSButton()
    private let trashButton = NSButton()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var onDownload: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var onDelete: (() -> Void)?

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

        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusField.alignment = .right
        statusField.textColor = .secondaryLabelColor
        addSubview(statusField)

        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeField.textColor = .secondaryLabelColor
        addSubview(sizeField)

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

        primaryButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        trashButton.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            statusField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            statusField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 8),

            sizeField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            sizeField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),

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

    func configure(book: OpeningBook,
                   isDownloaded: Bool,
                   downloader: Downloader?,
                   onDownload: @escaping () -> Void,
                   onCancel: @escaping () -> Void,
                   onDelete: @escaping () -> Void) {
        self.onDownload = onDownload
        self.onCancel = onCancel
        self.onDelete = onDelete

        titleField.stringValue = book.title

        let isDownloading = downloader?.isDownloading ?? false

        if isDownloading {
            statusField.stringValue = "Downloading…"
        } else if isDownloaded {
            statusField.stringValue = "Downloaded"
        } else {
            statusField.stringValue = "Not downloaded"
        }

        // Show the on-disk size once downloaded, otherwise the expected download size.
        let bytes = isDownloaded ? (book.onDiskSize ?? book.fileSize) : book.fileSize
        sizeField.stringValue = Self.byteFormatter.string(fromByteCount: Int64(bytes))

        progressIndicator.isHidden = !isDownloading
        cancelButton.isHidden = !isDownloading
        if isDownloading {
            progressIndicator.doubleValue = downloader?.progress ?? 0
        }

        // Download button only when not downloaded and not downloading.
        primaryButton.isHidden = isDownloading || isDownloaded
        primaryButton.image = NSImage(systemSymbolName: "arrow.down",
                                      accessibilityDescription: "Download")
        primaryButton.title = "  Download"
        primaryButton.imagePosition = .imageLeading

        trashButton.isHidden = !(isDownloaded && !isDownloading)
    }

    @objc private func primaryTapped() { onDownload?() }
    @objc private func cancelTapped() { onCancel?() }
    @objc private func trashTapped() { onDelete?() }
}
