//
//  WatchWidgetTileText.swift
//  KataGoAnalysisKit
//
//  Which layout the rectangular tile picks, and every string the complication
//  puts on a watch face.
//
//  All of it lives here because the widget's view code has no test target and
//  cannot be given one: the only bundle that covers watch logic is
//  "KataGo AnytimeTests", which builds for the iOS Simulator against the iOS
//  host app. A rule spelled out inline in the widget would be verifiable only
//  by looking at a screenshot.
//

import Foundation

public enum WatchWidgetTileLayout: Equatable, Sendable {
    /// Nothing to show. `headline` always renders; `detail` is a second line
    /// when there is room for it.
    case unavailable(headline: String, detail: String?)
    /// No record yet, but the retired complication's score scalar is still
    /// in the App Group. A one-release cutover fallback: the string is
    /// already formatted (by `scoreText`), so the view does no formatting of
    /// its own.
    case legacyScore(String)
    /// Name + score row, then up to three lines of comment. The move line is
    /// deliberately absent here: a 40mm rectangular tile affords one or the
    /// other, and on a position that carries a comment the comment is what
    /// this tile exists to show.
    case withComment
    /// Name + score row, then the move line. The DEFAULT: most positions
    /// carry no comment, and this is where the move number lives.
    case withoutComment
    /// Always-On (luminance reduced): the header row and the move line only.
    case reduced
}

public enum WatchWidgetTileText {
    /// Roughly what the inline slot affords once the face's own date is
    /// alongside it. A budget, not a guarantee — the system still truncates.
    public static let inlineBudget = 20

    /// ASCII, per `WatchLibraryRow.sizeText`'s rule that a typographic
    /// character is not worth the encoding risk in a string this small.
    public static let separator = " - "

    public static func layout(for snapshot: WatchWidgetSnapshot?,
                              legacyScoreLeadBlack: Double? = nil,
                              storageAvailable: Bool,
                              luminanceReduced: Bool) -> WatchWidgetTileLayout {
        // Storage first: it outranks everything else, including the legacy
        // fallback below — the legacy scalar lives in the same App Group, so
        // a tile that cannot read its record cannot read that either. There
        // is nothing to fall back to.
        guard storageAvailable else {
            return .unavailable(headline: "Storage unavailable", detail: nil)
        }
        guard let snapshot else {
            // Cutover window: no record has been written yet, but the
            // retired complication's score scalar is still sitting in the
            // App Group. This is checked before "No game yet" — and before
            // the Always-On check below, since `.reduced` only makes sense
            // as a dimming of an existing record's content; with no record
            // at all there is nothing to dim, only a lone score to show.
            if let legacyScoreLeadBlack, let score = scoreText(legacyScoreLeadBlack) {
                return .legacyScore(score)
            }
            return .unavailable(headline: "No game yet",
                                detail: "Open KataGo Anytime on your Watch")
        }
        if luminanceReduced { return .reduced }
        return snapshot.comment == nil ? .withoutComment : .withComment
    }

    /// "B+3.5" / "W+3.5". Hierarchy on this tile is carried by weight and
    /// `.primary`/`.secondary` only, never hue — a tinted face renders in
    /// `.accented` mode and would flatten two colors into one.
    public static func scoreText(_ scoreLeadBlack: Double?) -> String? {
        guard let value = scoreLeadBlack else { return nil }
        return value >= 0 ? String(format: "B+%.1f", value)
                          : String(format: "W+%.1f", -value)
    }

    /// "B+22". The circular slot has no room for a decimal at a legible size.
    public static func compactScoreText(_ scoreLeadBlack: Double?) -> String? {
        guard let value = scoreLeadBlack else { return nil }
        let points = Int(abs(value).rounded())
        return value >= 0 ? "B+\(points)" : "W+\(points)"
    }

    /// The "of M" half is dropped whenever it would be a lie: on a branch the
    /// index and the mainline count describe different lines, and a parked
    /// index past the count would render an impossible ratio.
    public static func moveText(parkedIndex: Int,
                                mainlineMoveCount: Int,
                                isBranch: Bool) -> String {
        guard !isBranch, parkedIndex <= mainlineMoveCount else {
            return "Move \(parkedIndex)"
        }
        return "Move \(parkedIndex) of \(mainlineMoveCount)"
    }

    /// The inline slot is rendered by the system — its font, the face's tint,
    /// its truncation — and `.font`/`.foregroundStyle`/`.lineLimit` are
    /// silently dropped, the same styling loss this repo already recorded for
    /// watchOS navigation titles. So the WRITER truncates, and the durable
    /// token goes first.
    public static func inlineText(for snapshot: WatchWidgetSnapshot?,
                                  legacyScoreLeadBlack: Double? = nil) -> String {
        guard let snapshot else {
            // Same cutover fallback as `layout(for:legacyScoreLeadBlack:...)`,
            // rendered through the same compact formatting a real score gets
            // in this family.
            if let legacyScoreLeadBlack, let score = compactScoreText(legacyScoreLeadBlack) {
                return score
            }
            return "No game"
        }
        let lead = compactScoreText(snapshot.scoreLeadBlack) ?? "Move \(snapshot.parkedIndex)"
        let remaining = inlineBudget - lead.count - separator.count
        guard remaining > 0 else { return lead }
        guard snapshot.name.count > remaining else {
            return lead + separator + snapshot.name
        }
        let clipped = String(snapshot.name.prefix(max(remaining - 1, 1)))
        return lead + separator + clipped + "\u{2026}"
    }

    /// A different readout, not a compact rendition of name + comment.
    public static func circularText(for snapshot: WatchWidgetSnapshot?,
                                    legacyScoreLeadBlack: Double? = nil) -> String {
        guard let snapshot else {
            // Same cutover fallback as `inlineText`, above.
            if let legacyScoreLeadBlack, let score = compactScoreText(legacyScoreLeadBlack) {
                return score
            }
            return "--"
        }
        return compactScoreText(snapshot.scoreLeadBlack) ?? "\(snapshot.parkedIndex)"
    }
}
