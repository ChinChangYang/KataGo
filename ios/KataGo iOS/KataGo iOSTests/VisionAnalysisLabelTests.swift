//
//  VisionAnalysisLabelTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure label-lines mapping behind the visionOS candidate-marker
//  attachments: the "Analysis information" setting (Winrate/Score/All/None
//  index into Config.analysisInformations) selects which lines float above
//  a marker, with exact 2D AnalysisView format parity.
//

import Testing
@testable import KataGoUICore
import KataGoGameStore

struct VisionAnalysisLabelTests {
    private let winrateIndex = Config.analysisInformations.firstIndex(of: Config.analysisInformationWinrate)!
    private let scoreIndex = Config.analysisInformations.firstIndex(of: Config.analysisInformationScore)!
    private let allIndex = Config.analysisInformations.firstIndex(of: Config.analysisInformationAll)!
    private let noneIndex = Config.analysisInformations.firstIndex(of: Config.analysisInformationNone)!

    private func lines(_ information: Int,
                       winrate: Float = 0.55,
                       visits: Int = 1234,
                       scoreLead: Float = 3.4) -> [String] {
        visionAnalysisLabelLines(analysisInformation: information,
                                 winrate: winrate,
                                 visits: visits,
                                 scoreLead: scoreLead)
    }

    @Test func winrateModeShowsOnlyWinrate() {
        #expect(lines(winrateIndex) == ["55%"])
    }

    @Test func scoreModeShowsOnlySignedScore() {
        #expect(lines(scoreIndex) == ["+3"])
    }

    @Test func allModeStacksWinrateVisitsScore() {
        #expect(lines(allIndex) == ["55%", "1.2k", "+3"])
    }

    @Test func noneModeShowsNothing() {
        #expect(lines(noneIndex).isEmpty)
    }

    @Test func outOfRangeIndexShowsNothing() {
        // 2D parity: an index matching no mode renders no text (the marker
        // itself is only hidden by None, which the view gates separately).
        #expect(lines(-1).isEmpty)
        #expect(lines(Config.analysisInformations.count).isEmpty)
    }

    @Test func winrateFormatMatches2D() {
        // "%2.0f%%" keeps the 2D leading-space parity for single digits.
        #expect(lines(winrateIndex, winrate: 0.05) == [" 5%"])
        #expect(lines(winrateIndex, winrate: 1.0) == ["100%"])
        #expect(lines(winrateIndex, winrate: 0.494) == ["49%"])
    }

    @Test func scoreFormatMatches2D() {
        // Signed, rounded to integer — including the 2D "-0" parity case.
        #expect(lines(scoreIndex, scoreLead: -0.4) == ["-0"])
        #expect(lines(scoreIndex, scoreLead: 0.4) == ["+0"])
        #expect(lines(scoreIndex, scoreLead: -12.7) == ["-13"])
    }

    @Test func visitsUseSIUnits() {
        #expect(lines(allIndex, visits: 850)[1] == "850")
        #expect(lines(allIndex, visits: 2_500_000)[1] == "2.5M")
    }
}
