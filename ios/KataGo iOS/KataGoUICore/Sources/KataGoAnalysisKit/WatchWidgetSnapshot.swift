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
    /// Which mirror wrote this record. Rendered as a one-glyph distinction on
    /// the tile so a tester can tell a stalled push from a stalled reload —
    /// the freshness path's failure modes are otherwise indistinguishable.
    public enum Source: String, Codable, Sendable {
        case live
        case library
    }

    /// Bounds the wire payload, NOT the tile. Fitting text to the rect is
    /// SwiftUI's job; this exists so a Commentator paragraph cannot push the
    /// 2 Hz application context past its 16 KB test bound.
    public static let commentCharacterLimit = 256

    public var gameID: String
    public var name: String
    /// nil means "no comment at this position" and must be rendered as a
    /// different layout, never as an empty region.
    public var comment: String?
    /// Where the game is parked. NOT the end of the mainline, and NOT
    /// `WatchSnapshot.moveNumber` (stones placed, which passes do not advance).
    public var parkedIndex: Int
    public var mainlineMoveCount: Int
    public var scoreLeadBlack: Double?
    /// True while the phone is on a branch. The saved record's comments are
    /// mainline-indexed, so a branch index must not be used to look one up.
    public var isBranch: Bool
    /// Watch-observed time at which `contentKey` last changed — deliberately
    /// not the phone's `hostTimestamp` (a 2 Hz heartbeat) nor
    /// `lastModificationDate` (another device's clock, and unmoved by a
    /// comment edit). One clock governs both records, so they are comparable.
    public var capturedAt: Date
    public var source: Source

    public init(gameID: String, name: String, comment: String?,
                parkedIndex: Int, mainlineMoveCount: Int,
                scoreLeadBlack: Double?, isBranch: Bool,
                capturedAt: Date, source: Source) {
        self.gameID = gameID
        self.name = name
        self.comment = comment
        self.parkedIndex = parkedIndex
        self.mainlineMoveCount = mainlineMoveCount
        self.scoreLeadBlack = scoreLeadBlack
        self.isBranch = isBranch
        self.capturedAt = capturedAt
        self.source = source
    }

    /// Identity of what the tile would DISPLAY. Excludes `capturedAt` and
    /// `source` so an unchanged position produces an unchanged key: the
    /// writers skip the encode and the `UserDefaults` write entirely on a
    /// match, which is what keeps a 2 Hz ingest off cfprefsd.
    ///
    /// The score is rounded to a tenth as an Int rather than formatted, so
    /// analysis jitter does not churn the key and +0.0 / -0.0 cannot produce
    /// two different keys for the same lead.
    public var contentKey: String {
        let score = scoreLeadBlack.map { String(Int(($0 * 10).rounded())) } ?? ""
        return "\(gameID)|\(parkedIndex)|\(name)|\(comment ?? "")|\(score)"
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
