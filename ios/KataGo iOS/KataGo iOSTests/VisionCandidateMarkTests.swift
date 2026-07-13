//
//  VisionCandidateMarkTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure mapping behind the visionOS flat candidate markers:
//  exact 2D AnalysisView parity — visits-ratio hue fill at 0.8 opacity,
//  the hidden-below-visit-ratio dim treatment (bare 0.2 circle, no text),
//  the blue ring keyed on max utilityLcb (surviving hiding), the bold
//  winrate line, and the 1.0-cell circle sized for the fixed-scale
//  volumetric window (1360 pt/m) with 4x supersampling.
//

import Testing
@testable import KataGoUICore

struct VisionCandidateMarkTests {
    /// Real bundled-board spacings: 22 mm × 23.7 mm (boards_manifest.json).
    private let spacingX: Float = 0.022
    private let spacingZ: Float = 0.0237

    private func make(visits: Int = 600,
                      maxVisits: Int = 800,
                      utilityLcb: Float = 0.12,
                      maxUtilityLcb: Float? = 0.34,
                      hiddenAnalysisVisitRatio: Float = 0.03125,
                      analysisInformation: Int = 0,
                      winrate: Float = 0.54,
                      scoreLead: Float = -0.4) -> VisionCandidateMark {
        VisionCandidateMark.make(visits: visits,
                                 maxVisits: maxVisits,
                                 utilityLcb: utilityLcb,
                                 maxUtilityLcb: maxUtilityLcb,
                                 hiddenAnalysisVisitRatio: hiddenAnalysisVisitRatio,
                                 analysisInformation: analysisInformation,
                                 winrate: winrate,
                                 scoreLead: scoreLead,
                                 cellSpacingX: spacingX,
                                 cellSpacingZ: spacingZ)
    }

    @Test func visibleMarkMatchesAnalysisViewAppearance() {
        let mark = make()
        #expect(mark.opacity == 0.8)
        #expect(mark.hue == analysisBaseHue(visits: 600, maxVisits: 800))
        #expect(mark.labelLines == visionAnalysisLabelLines(analysisInformation: 0,
                                                            winrate: 0.54,
                                                            visits: 600,
                                                            scoreLead: -0.4))
    }

    @Test func hiddenBelowVisitRatioIsBareDimCircle() {
        // 24 < 0.03125 × 800 = 25 → the 2D dim treatment.
        let mark = make(visits: 24)
        #expect(mark.opacity == 0.2)
        #expect(mark.labelLines.isEmpty)
        #expect(mark.boldLineIndex == nil)
    }

    @Test func exactRatioBoundaryStaysVisible() {
        // 25 == 0.03125 × 800 — AnalysisView hides on strict less-than only.
        let mark = make(visits: 25)
        #expect(mark.opacity == 0.8)
        #expect(!mark.labelLines.isEmpty)
    }

    @Test func ringRequiresExactMaxUtilityLcb() {
        #expect(make(utilityLcb: 0.42, maxUtilityLcb: 0.42).showsRing)
        #expect(!make(utilityLcb: Float(0.42).nextDown, maxUtilityLcb: 0.42).showsRing)
        #expect(!make(utilityLcb: 0.42, maxUtilityLcb: nil).showsRing)
    }

    @Test func ringSurvivesHiding() {
        // 2D draws the ring outside the isHidden branch.
        let mark = make(visits: 24, utilityLcb: 0.42, maxUtilityLcb: 0.42)
        #expect(mark.showsRing)
        #expect(mark.opacity == 0.2)
    }

    @Test func circleFillsOneCellAtVolumeScale() {
        let mark = make()
        #expect(mark.diameterMeters == 0.022)
        #expect(abs(Float(mark.framePoints) - 0.022 * 1360 * 4) < 1e-3)
        #expect(mark.entityScale == 0.25)
        #expect(abs(mark.ringLineWidthPoints - mark.framePoints / 16) < 1e-9)
    }

    @Test func winrateLineIsBoldInWinrateAndAllModes() {
        #expect(make(analysisInformation: 0).boldLineIndex == 0)
        #expect(make(analysisInformation: 2).boldLineIndex == 0)
        #expect(make(analysisInformation: 1).boldLineIndex == nil)
    }

    @Test func equalInputsCompareEqual() {
        #expect(make() == make())
    }
}
