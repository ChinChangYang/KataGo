//
//  ScoreChartVisibility.swift
//  KataGoUICore
//
//  The score-lead chart's empty-state policy, shared by iOS `LinePlotView` and
//  the tvOS `TVScoreChart` so the two cannot drift apart again.
//
//  Why a shared type rather than a check in each view: the chart plots
//  `GameRecord.scoreLeads`, which keeps accumulating whenever the engine is
//  running — `GobanState.maybeUpdateAnalysisData` writes it on every move as
//  long as `analysisStatus != .clear`, regardless of the eye. So a screen that
//  suppresses its winrate/score TEXT behind a closed eye, but leaves the chart
//  ungated, still shows the reader who is winning. That is exactly what the
//  tvOS play screen did.
//

import Foundation

public enum ScoreChartVisibility {

    /// Which presentation the chart owes its caller. Exhaustive, so the ladder
    /// is unit-testable without SwiftUI — which matters because tvOS view code
    /// is not reachable from the test host at all.
    public enum Presentation: Equatable, Sendable {
        /// Eye open with a trend to draw: header, current-move marker, plot.
        case plot
        /// Eye closed on a screen that hides history: header and a reserved
        /// slot, no marker. Distinct from `awaitingHistory` on purpose — see
        /// the ordering note in `presentation(...)`.
        case hiddenByEye
        /// Too few points yet, and the caller reserves the space so its panel
        /// does not reflow when the history fills in.
        case awaitingHistory
        /// Too few points yet, and the caller supplied guidance copy.
        case noHistoryText
        /// Nothing at all.
        case none
    }

    /// The one predicate. Raw `.closed` — NOT `!= .opened` — mirroring
    /// `LinePlotView.scoreLeadPoints` exactly, so `.book` keeps plotting.
    public static func isSeriesHidden(eyeStatus: EyeStatus) -> Bool {
        eyeStatus == .closed
    }

    /// - Parameters:
    ///   - honorsEyeStatus: whether this caller hides recorded history behind a
    ///     closed eye. True only where the eye means "don't tell me who is
    ///     winning" — i.e. a game the viewer is playing. A review screen means
    ///     the opposite by design: closing the eye there is what makes the
    ///     persisted per-move numbers appear as text, so blanking its plot
    ///     would contradict the number printed directly above it.
    ///   - pointCount: the plotted series length, interpolated zero-crossings
    ///     included; `>= 2` is the existing "is there a trend to draw" bar.
    public static func presentation(eyeStatus: EyeStatus,
                                    honorsEyeStatus: Bool,
                                    pointCount: Int,
                                    reservesSpaceWhenEmpty: Bool,
                                    hasNoHistoryMessage: Bool) -> Presentation {
        // HIDDEN OUTRANKS ABSENT. A closed eye must never fall through to the
        // "no score history yet — step through this game on iPhone" guidance,
        // which would be a flat lie about a game whose history exists and is
        // merely being withheld.
        if honorsEyeStatus, isSeriesHidden(eyeStatus: eyeStatus) { return .hiddenByEye }
        if pointCount >= 2 { return .plot }
        if reservesSpaceWhenEmpty { return .awaitingHistory }
        if hasNoHistoryMessage { return .noHistoryText }
        return .none
    }
}
