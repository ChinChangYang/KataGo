import AppKit
import KataGoUICore

/// A view-based table cell for one library game: a thumbnail on the leading
/// edge, with a bold name, a short modification date, and the root comment
/// (the comment at move 0, secondary and truncated) stacked on the trailing
/// side. Mirrors the iOS `GameLinkView` row layout in AppKit.
final class GameRowView: NSTableCellView {
    private let thumbnailView = NSImageView()
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

    /// SF Symbol placeholder shown when a game has no rendered thumbnail yet.
    private static let placeholderImage: NSImage? =
        NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "No thumbnail")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setup() {
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.imageFrameStyle = .none
        addSubview(thumbnailView)
        // Wire `imageView` so `NSTableCellView` row styling cooperates.
        imageView = thumbnailView

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
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 40),
            thumbnailView.heightAnchor.constraint(equalToConstant: 40),

            nameField.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 8),
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

    /// Populates the cell from a game record. The thumbnail decodes the
    /// persisted `thumbnail` data, falling back to a placeholder symbol.
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

        thumbnailView.image =
            gameRecord.thumbnail.flatMap(NSImage.init(data:)) ?? Self.placeholderImage
    }
}
