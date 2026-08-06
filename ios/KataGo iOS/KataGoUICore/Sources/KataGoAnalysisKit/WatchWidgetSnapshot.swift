//
//  WatchWidgetSnapshot.swift
//  KataGoAnalysisKit
//
//  What the watch complication renders: one game, at one position.
//
//  Lives in the Foundation-only tier for two reasons. The watch complication
//  appex must link a product that drags in no SwiftData, CoreData, or
//  AppIntents — a wrist-sized extension has a hard memory ceiling and the iOS
//  widget already has a jetsam scar from exactly that. And the watch target
//  has no test bundle, so every rule spelled out here is only testable because
//  "KataGo AnytimeTests" (iOS Simulator) can compile it. That is also why
//  there is no `#if os(watchOS)` anywhere in this file: guarded code would not
//  be compiled by the only bundle that tests it.
//

import Foundation

public struct WatchWidgetSnapshot: Codable, Equatable, Sendable {
    /// Bounds the wire payload, NOT the tile. Fitting text to the rect is
    /// SwiftUI's job; this exists so a Commentator paragraph cannot push the
    /// 2 Hz application context past its 16 KB test bound.
    public static let commentCharacterLimit = 256

    public var gameID: String
    public var name: String
    /// nil means "no comment at this position" and must be rendered as a
    /// different layout, never as an empty region.
    public var comment: String?
    /// Where the game is parked — an SGF mainline index. NOT the end of the
    /// mainline, and NOT a count of stones placed, which passes do not advance.
    public var parkedIndex: Int
    public var mainlineMoveCount: Int
    public var scoreLeadBlack: Double?
    /// True while the phone is on a branch. The saved record's comments are
    /// mainline-indexed, so a branch index must not be used to look one up.
    public var isBranch: Bool
    /// Watch-observed time at which `contentKey` last changed — deliberately
    /// not `lastModificationDate`, which is another device's clock and does
    /// not move when only a comment changes.
    public var capturedAt: Date

    public init(gameID: String, name: String, comment: String?,
                parkedIndex: Int, mainlineMoveCount: Int,
                scoreLeadBlack: Double?, isBranch: Bool,
                capturedAt: Date) {
        self.gameID = gameID
        self.name = name
        self.comment = comment
        self.parkedIndex = parkedIndex
        self.mainlineMoveCount = mainlineMoveCount
        self.scoreLeadBlack = scoreLeadBlack
        self.isBranch = isBranch
        self.capturedAt = capturedAt
    }

    /// Identity of what the tile would DISPLAY. Excludes `capturedAt` so an
    /// unchanged position produces an unchanged key: the writer skips the
    /// encode and the `UserDefaults` write entirely on a match.
    ///
    /// The score is rounded to a tenth as an Int rather than formatted.
    /// Rounding collapses sub-tenth differences the tile would not render
    /// anyway, and makes +0.0 / -0.0 produce the same key instead of two
    /// different ones for the same lead.
    ///
    /// Every field is written length-prefixed (`"<count>:<text>"`) rather
    /// than joined with a plain separator. `name` and `comment` are user
    /// content — a game title, or commentary copied verbatim from an
    /// imported SGF `C[]` node — so they may contain any character,
    /// including whatever separator this code might otherwise pick. A
    /// prefixed count is not something the content can imitate: the
    /// boundary is fixed the instant the count is read, before a single
    /// character of the content itself is examined, so two distinct field
    /// splits (e.g. `name: "X|Y", comment: "c"` vs. `name: "X", comment:
    /// "Y|c"`) can never produce the same key. `isBranch` and
    /// `mainlineMoveCount` are included too: the tile renders "Move 42 of
    /// 178" and suppresses the "of 178" half on a branch, so both drive
    /// what is actually displayed and both must be able to change the key.
    ///
    /// This cannot be built with Swift's `Hasher` / `hashValue` /
    /// `hash(into:)`. Those are seeded per process for hash-flooding
    /// protection, so the same snapshot would hash differently in the
    /// watch app (which writes this key) than in the widget extension
    /// (which recomputes it later, in a separate process, to compare
    /// against what was written) — the two would never agree. Only a
    /// deterministic string survives that process boundary.
    public var contentKey: String {
        let score = scoreLeadBlack.map { String(Int(($0 * 10).rounded())) } ?? ""
        let fields = [
            gameID,
            String(parkedIndex),
            name,
            comment ?? "",
            score,
            isBranch ? "1" : "0",
            String(mainlineMoveCount),
        ]
        return fields.map { "\($0.count):\($0)" }.joined()
    }

    /// Trim, drop-if-blank, and cap by GRAPHEME count. Never bytes or unicode
    /// scalars: imported SGFs carry CJK and emoji commentary verbatim
    /// (`GameRecord+SGF.swift` copies every `C[]` node), and a scalar cap would
    /// split a cluster. The ellipsis is appended only when truncation actually
    /// happened, so a 256-character comment is not falsely marked as clipped.
    public static func cappedComment(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > commentCharacterLimit else { return trimmed }
        return String(trimmed.prefix(commentCharacterLimit)) + "\u{2026}"
    }
}
