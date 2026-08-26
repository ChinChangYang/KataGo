import AppKit
import SwiftUI
import KataGoUICore

/// Hosts the row's board without taking any of the row's clicks.
///
/// `NSHostingView` is hit-testable, and SwiftUI's `allowsHitTesting(false)`
/// only silences the SwiftUI side — AppKit would still route the click here
/// and the row would stop selecting and stop opening its context menu. Refusing
/// the hit outright hands every click back to the table.
private final class BoardHostView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A view-based table cell for one library game: a board on the leading edge,
/// with a bold name, a short modification date, and the root comment (the
/// comment at move 0, secondary and truncated) stacked on the trailing side.
/// Mirrors the iOS `GameLinkView` row layout in AppKit.
final class GameRowView: NSTableCellView {
    private let boardHost = BoardHostView<AnyView>(rootView: AnyView(Color.clear))
    private let nameField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")
    private let commentField = NSTextField(labelWithString: "")

    /// Short date used for the secondary line (e.g. "Jun 16, 2026 at 3:04 PM").
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Shown when a record's SGF cannot be read. Under live rendering there is
    /// no "no board yet" state — a readable record always has a position — so
    /// this is a diagnostic, not a waiting state.
    private static let unreadableImage: NSImage? =
        NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "Unreadable game record")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setup() {
        boardHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(boardHost)
        // `NSTableCellView.imageView` is deliberately left nil: it expects an
        // `NSImageView`, and the board is a hosted SwiftUI view.

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        addSubview(nameField)
        textField = nameField

        dateField.translatesAutoresizingMaskIntoConstraints = false
        dateField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        dateField.textColor = .secondaryLabelColor
        dateField.lineBreakMode = .byTruncatingTail
        dateField.maximumNumberOfLines = 1
        addSubview(dateField)

        commentField.translatesAutoresizingMaskIntoConstraints = false
        commentField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        commentField.textColor = .secondaryLabelColor
        commentField.lineBreakMode = .byTruncatingTail
        commentField.maximumNumberOfLines = 1
        addSubview(commentField)

        NSLayoutConstraint.activate([
            boardHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            boardHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            boardHost.widthAnchor.constraint(equalToConstant: 40),
            boardHost.heightAnchor.constraint(equalToConstant: 40),

            nameField.leadingAnchor.constraint(equalTo: boardHost.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            dateField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            dateField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            dateField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2),

            commentField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            commentField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            commentField.topAnchor.constraint(equalTo: dateField.bottomAnchor, constant: 2),
            commentField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    /// Populates the cell from a game record. The board is derived from the
    /// record's own SGF (ADR 0014), never from a stored bitmap, so a row cannot
    /// draw another game's position.
    func configure(with gameRecord: GameRecord) {
        nameField.stringValue = gameRecord.name

        if let date = gameRecord.lastModificationDate {
            dateField.stringValue = Self.dateFormatter.string(from: date)
        } else {
            dateField.stringValue = ""
        }

        // `comments` is keyed by move index; [0] is the root comment, matching
        // the iOS `GameLinkView` row preview.
        commentField.stringValue = gameRecord.comments?[0] ?? ""

        boardHost.rootView = Self.boardView(for: gameRecord)
    }

    /// The row's board, or the unreadable-record symbol.
    ///
    /// Stone style and vertical flip come from `UserDefaults`: the sidebar
    /// controller holds no `GobanState`, and these two keys are what
    /// `MacGlobalPreferenceSync` persists and reads back, so `UserDefaults` IS
    /// the macOS source of truth for them.
    @MainActor
    private static func boardView(for gameRecord: GameRecord) -> AnyView {
        guard let preview = RecordBoardPreviewSource.preview(for: gameRecord) else {
            return AnyView(
                Image(nsImage: Self.unreadableImage ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Unreadable game record"))
        }

        let defaults = UserDefaults.standard
        let stoneStyle = (defaults.object(forKey: GlobalSettingsKeys.stoneStyle) as? Int)
            ?? Config.defaultStoneStyle
        let verticalFlip = (defaults.object(forKey: GlobalSettingsKeys.verticalFlip) as? Bool)
            ?? Config.compatibleVerticalFlip

        return AnyView(
            ReportBoardView(width: preview.width,
                            height: preview.height,
                            blackVertices: preview.blackVertices,
                            whiteVertices: preview.whiteVertices,
                            overlay: .none,
                            lastMoveVertex: preview.lastMoveVertex,
                            isClassicStoneStyle: Config.isClassicStoneStyle(atIndex: stoneStyle),
                            showCoordinate: false,
                            verticalFlip: verticalFlip))
    }
}
