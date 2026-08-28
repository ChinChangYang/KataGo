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
/// with a bold name, the comment on the move the game is parked on, and a short
/// modification date stacked on the trailing side — in that order, so the note
/// reads as the row's content and the date as its metadata.
/// Mirrors the iOS `GameLinkView` row layout in AppKit.
///
/// Two of those parts are optional. A game with no comment on its current move
/// loses the middle line rather than reserving a blank one, and the board
/// disappears entirely when `GlobalSettings.thumbnailSize` is Off — text then
/// sits flush against the leading edge, which is the point of turning it off.
final class GameRowView: NSTableCellView {
    private let boardHost = BoardHostView<AnyView>(rootView: AnyView(Color.clear))
    private let nameField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")
    private let commentField = NSTextField(labelWithString: "")

    /// The text block's own vertical extent, so the three labels can be sized by
    /// their own content and then FLOATED in the row rather than welded to its
    /// top and bottom edges.
    ///
    /// They used to be welded: `name.top == top + 4` … `date.bottom == bottom - 4`
    /// were required equalities, which made the text stack the sole author of the
    /// row height. That is what let a taller board overhang its row — and it is
    /// also why simply forcing the row taller does not work: with both edges
    /// pinned, every point of new height is absorbed INSIDE the stack by breaking
    /// a label's content hugging (750). Measured, `nameField` took all of it,
    /// growing 16 → 56 pt, and an `NSTextField` label draws its single line flush
    /// at the TOP of an oversized box — so the name and the date fly to opposite
    /// ends of the row with a 48 pt hole between them. No conflict is logged and
    /// `hasAmbiguousLayout` stays false; the row is just silently torn apart.
    private let textGuide = NSLayoutGuide()

    /// Mutable because the thumbnail size is a user preference, and zero-width
    /// with a collapsed gap is how the board is taken out of the row.
    private var boardWidthConstraint: NSLayoutConstraint!
    private var boardHeightConstraint: NSLayoutConstraint!
    private var textLeadingConstraint: NSLayoutConstraint!

    /// The row is at least as tall as its picture, plus breathing room.
    ///
    /// `boardHost` hangs off `centerY` alone. `centerY` POSITIONS a view, it
    /// cannot size the cell: `board.top = (H - side) / 2` solves for any H,
    /// including an H smaller than the board, in which case the board simply
    /// overhangs both edges. Under `usesAutomaticRowHeights` nothing then made
    /// the row grow for it. The same failure `ModelRowView` documents: automatic
    /// row heights measure only what is on the chain.
    ///
    /// Mutable because the padding is a function of the size — see
    /// `rowFloorPadding(forBoardSide:)`.
    private var boardRowFloorConstraint: NSLayoutConstraint!

    /// Exactly one is active: the date follows the comment when there is one,
    /// and the name when there is not. Hiding `commentField` alone would not
    /// shrink the row — a hidden field keeps its constraints.
    private var dateBelowCommentConstraint: NSLayoutConstraint!
    private var dateBelowNameConstraint: NSLayoutConstraint!

    /// Short date used for the tertiary line (e.g. "Jun 16, 2026 at 3:04 PM").
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Shown when a record's SGF cannot be read. Under live rendering there is
    /// no "no board yet" state — a readable record always has a position — so
    /// this is a diagnostic, not a waiting state. It lives in the picture slot,
    /// so a row with thumbnails off carries no such signal at all (ADR 0014).
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

        commentField.translatesAutoresizingMaskIntoConstraints = false
        commentField.font = .systemFont(ofSize: NSFont.systemFontSize)
        commentField.textColor = .secondaryLabelColor
        commentField.lineBreakMode = .byTruncatingTail
        commentField.maximumNumberOfLines = 1
        // `maximumNumberOfLines = 1` does NOT clamp a string carrying hard line
        // breaks — AppKit lays those out as separate lines regardless, and a
        // Deep Report comment is a paragraph. `libraryRowComment` already
        // flattens them; this is the structural guarantee behind it.
        commentField.usesSingleLineMode = true
        addSubview(commentField)

        dateField.translatesAutoresizingMaskIntoConstraints = false
        dateField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        dateField.textColor = .tertiaryLabelColor
        dateField.lineBreakMode = .byTruncatingTail
        dateField.maximumNumberOfLines = 1
        addSubview(dateField)

        addLayoutGuide(textGuide)

        boardWidthConstraint = boardHost.widthAnchor.constraint(equalToConstant: ThumbnailMetrics.smallSide)
        boardHeightConstraint = boardHost.heightAnchor.constraint(equalToConstant: ThumbnailMetrics.smallSide)
        textLeadingConstraint = nameField.leadingAnchor.constraint(equalTo: boardHost.trailingAnchor, constant: 8)
        dateBelowCommentConstraint = dateField.topAnchor.constraint(equalTo: commentField.bottomAnchor, constant: 2)
        dateBelowNameConstraint = dateField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2)

        boardRowFloorConstraint = heightAnchor.constraint(greaterThanOrEqualTo: boardHost.heightAnchor,
                                                         constant: 0)
        // 999, not required: `usesAutomaticRowHeights` can lay a cell out at a
        // provisional height before it measures it, and a required floor there
        // would log a conflict and let AppKit break the board's own height or
        // its centerY — a visible flicker. 999 still beats the fitting-size
        // compression priority (50), so it genuinely DRIVES the measured
        // height; a provisional pass merely degrades to the old overhang.
        boardRowFloorConstraint.priority = NSLayoutConstraint.Priority(999)

        NSLayoutConstraint.activate([
            boardHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            boardHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            boardWidthConstraint,
            boardHeightConstraint,
            boardRowFloorConstraint,

            textLeadingConstraint,
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

            commentField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            commentField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            commentField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2),

            dateField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            dateField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            dateBelowCommentConstraint,

            // The text block's extent. The required chain (name → comment →
            // date) lives INSIDE the guide; the guide is the only thing that
            // meets the cell's edges, and it meets them with inequalities plus
            // a centerY. So the labels always keep their intrinsic heights and
            // the block rides centred beside the board however tall the row is.
            textGuide.topAnchor.constraint(equalTo: nameField.topAnchor),
            textGuide.bottomAnchor.constraint(equalTo: dateField.bottomAnchor),
            textGuide.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            textGuide.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            textGuide.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            textGuide.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            textGuide.centerYAnchor.constraint(equalTo: centerYAnchor),

            // The row's height is max(text + 8, board + padding) — two floors,
            // never one chain. The solver minimises it down to whichever wins.
            heightAnchor.constraint(greaterThanOrEqualTo: textGuide.heightAnchor, constant: 8),
        ])
    }

    /// Vertical breathing room a thumbnail claims inside its row, matching the
    /// 4 pt inset the text block already uses top and bottom.
    private static let boardVerticalInset: CGFloat = 4

    /// The padding added to the board's own height to get the row's floor.
    ///
    /// Only a board TALLER than the text a row already carries pays the inset.
    /// A comment-less row measures 4 + 16 + 2 + 14 + 4 = 40 pt, which is exactly
    /// `ThumbnailMetrics.smallSide` — the coincidence that hid this bug for as
    /// long as the board was a fixed 40 pt. Charging Small the inset too would
    /// grow every comment-less row by 8 pt to fix a tightness nobody reported.
    private static func rowFloorPadding(forBoardSide side: CGFloat) -> CGFloat {
        side > ThumbnailMetrics.smallSide ? 2 * boardVerticalInset : 0
    }

    /// Populates the cell from a game record. The board is derived from the
    /// record's own SGF (ADR 0014), never from a stored bitmap, so a row cannot
    /// draw another game's position.
    func configure(with gameRecord: GameRecord, thumbnailSizeIndex: Int) {
        nameField.stringValue = gameRecord.name

        if let date = gameRecord.lastModificationDate {
            dateField.stringValue = Self.dateFormatter.string(from: date)
        } else {
            dateField.stringValue = ""
        }

        let comment = gameRecord.libraryRowComment
        commentField.stringValue = comment ?? ""
        commentField.isHidden = comment == nil
        // Deactivate BOTH before activating one. Assigning `isActive` in place
        // leaves the pair momentarily both-active on a reused cell, which is an
        // over-constrained instant the engine may resolve by breaking the wrong
        // one.
        dateBelowCommentConstraint.isActive = false
        dateBelowNameConstraint.isActive = false
        (comment != nil ? dateBelowCommentConstraint! : dateBelowNameConstraint!).isActive = true

        applyThumbnailSize(gameRecord: gameRecord, sizeIndex: thumbnailSizeIndex)
    }

    /// Sizes — or removes — the board. Off is not just a hidden view: resolving
    /// a row's picture replays that game's SGF, so the guard has to sit in front
    /// of `boardView(for:)` rather than behind it.
    private func applyThumbnailSize(gameRecord: GameRecord, sizeIndex: Int) {
        guard let side = ThumbnailMetrics.side(for: sizeIndex) else {
            boardHost.isHidden = true
            boardHost.rootView = AnyView(Color.clear)
            boardWidthConstraint.constant = 0
            boardHeightConstraint.constant = 0
            boardRowFloorConstraint.constant = 0
            // 4 (board leading inset) + 0 (board) + 2 = the 6 pt the trailing
            // edge already uses, so hidden rows read as a plain, even list.
            textLeadingConstraint.constant = 2
            return
        }

        boardHost.isHidden = false
        boardWidthConstraint.constant = side
        boardHeightConstraint.constant = side
        boardRowFloorConstraint.constant = Self.rowFloorPadding(forBoardSide: side)
        textLeadingConstraint.constant = 8
        boardHost.rootView = Self.boardView(for: gameRecord)
    }

    /// The row's board, or the unreadable-record symbol.
    ///
    /// Stone style and vertical flip come from `UserDefaults`: they are what
    /// `MacGlobalPreferenceSync` persists and reads back, and nothing reloads
    /// the sidebar when they change, so there is no live value to prefer. The
    /// thumbnail size deliberately does NOT come from here — it arrives from
    /// the same `GobanState` property whose change triggers the reload, so the
    /// value a row draws and the trigger that redraws it cannot disagree.
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
