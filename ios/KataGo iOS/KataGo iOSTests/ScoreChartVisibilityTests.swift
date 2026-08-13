//
//  ScoreChartVisibilityTests.swift
//  KataGo AnytimeTests
//
//  The score-lead chart's empty-state ladder, shared by iOS LinePlotView and
//  tvOS TVScoreChart. Pure policy — the tvOS view itself is unreachable from
//  this test host, so this is the only automated coverage the gate has; the
//  view is verified by its #Preview renders.
//

import Testing
@testable import KataGoUICore

struct ScoreChartVisibilityTests {

    // MARK: - The predicate

    @Test("A closed eye hides the series; .book does NOT — iOS parity")
    func onlyClosedHidesTheSeries() {
        #expect(ScoreChartVisibility.isSeriesHidden(eyeStatus: .closed))
        #expect(!ScoreChartVisibility.isSeriesHidden(eyeStatus: .opened))
        // The gate is raw `== .closed`, not `!= .opened`. LinePlotView keeps
        // plotting in book mode, and this mirrors it exactly — which is also
        // where it deliberately differs from isAnalysisOverlayVisible.
        #expect(!ScoreChartVisibility.isSeriesHidden(eyeStatus: .book))
    }

    // MARK: - The ladder

    @Test("Eye open with a trend plots")
    func openEyeWithHistoryPlots() {
        #expect(ScoreChartVisibility.presentation(eyeStatus: .opened,
                                                  honorsEyeStatus: true,
                                                  pointCount: 12,
                                                  reservesSpaceWhenEmpty: true,
                                                  hasNoHistoryMessage: false) == .plot)
    }

    @Test("A gating caller hides a real history behind a closed eye")
    func gatingCallerHidesHistory() {
        #expect(ScoreChartVisibility.presentation(eyeStatus: .closed,
                                                  honorsEyeStatus: true,
                                                  pointCount: 12,
                                                  reservesSpaceWhenEmpty: true,
                                                  hasNoHistoryMessage: false) == .hiddenByEye)
    }

    @Test("A non-gating caller keeps plotting behind a closed eye")
    func nonGatingCallerKeepsPlotting() {
        // Review's contract: a closed eye is what SURFACES its persisted
        // numbers, so its plot must stay up or the panel contradicts itself.
        #expect(ScoreChartVisibility.presentation(eyeStatus: .closed,
                                                  honorsEyeStatus: false,
                                                  pointCount: 12,
                                                  reservesSpaceWhenEmpty: false,
                                                  hasNoHistoryMessage: true) == .plot)
    }

    /// The load-bearing ordering. Without it a closed eye falls through to the
    /// "no score history yet — step through this game on iPhone, iPad, or Mac"
    /// guidance, which is a flat lie about a game whose history exists.
    @Test("Hidden outranks absent: a closed eye never shows sync guidance")
    func hiddenOutranksAbsent() {
        #expect(ScoreChartVisibility.presentation(eyeStatus: .closed,
                                                  honorsEyeStatus: true,
                                                  pointCount: 0,
                                                  reservesSpaceWhenEmpty: false,
                                                  hasNoHistoryMessage: true) == .hiddenByEye)
    }

    @Test("Too little history: the reserved slot wins over guidance copy")
    func reservedSlotBeatsGuidance() {
        #expect(ScoreChartVisibility.presentation(eyeStatus: .opened,
                                                  honorsEyeStatus: true,
                                                  pointCount: 1,
                                                  reservesSpaceWhenEmpty: true,
                                                  hasNoHistoryMessage: true) == .awaitingHistory)
    }

    @Test("Too little history and no reservation: guidance copy")
    func guidanceWhenNothingReserved() {
        #expect(ScoreChartVisibility.presentation(eyeStatus: .opened,
                                                  honorsEyeStatus: false,
                                                  pointCount: 1,
                                                  reservesSpaceWhenEmpty: false,
                                                  hasNoHistoryMessage: true) == .noHistoryText)
    }

    @Test("Nothing to show and nothing to say: nothing is rendered")
    func nothingAtAll() {
        #expect(ScoreChartVisibility.presentation(eyeStatus: .opened,
                                                  honorsEyeStatus: false,
                                                  pointCount: 0,
                                                  reservesSpaceWhenEmpty: false,
                                                  hasNoHistoryMessage: false) == .none)
    }

    /// A single point is not a trend — the existing threshold, pinned so the
    /// gate rework cannot quietly change it.
    @Test("One point is not a trend")
    func onePointIsNotATrend() {
        #expect(ScoreChartVisibility.presentation(eyeStatus: .opened,
                                                  honorsEyeStatus: true,
                                                  pointCount: 1,
                                                  reservesSpaceWhenEmpty: true,
                                                  hasNoHistoryMessage: false) == .awaitingHistory)
        #expect(ScoreChartVisibility.presentation(eyeStatus: .opened,
                                                  honorsEyeStatus: true,
                                                  pointCount: 2,
                                                  reservesSpaceWhenEmpty: true,
                                                  hasNoHistoryMessage: false) == .plot)
    }
}
