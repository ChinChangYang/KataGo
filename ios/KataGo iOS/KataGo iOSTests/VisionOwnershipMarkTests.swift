//
//  VisionOwnershipMarkTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure quad mapping behind the visionOS 3D ownership overlay:
//  an OwnershipUnit (already digitized by AnalysisLineParser) becomes a
//  board-hugging quad sized per axis against the anisotropic cell spacing,
//  with a material-cache key derived from the digitized appearance.
//

import Testing
@testable import KataGoUICore

struct VisionOwnershipMarkTests {
    /// Real bundled-board spacings: 22 mm × 23.7 mm (boards_manifest.json).
    private let spacingX: Float = 0.022
    private let spacingZ: Float = 0.0237

    private func make(whiteness: Float = 0.8,
                      scale: Float = 0.52,
                      opacity: Float = 0.6,
                      point: BoardPoint = BoardPoint(x: 3, y: 4)) -> VisionOwnershipMark {
        VisionOwnershipMark.make(unit: OwnershipUnit(point: point,
                                                     whiteness: whiteness,
                                                     scale: scale,
                                                     opacity: opacity),
                                 cellSpacingX: spacingX,
                                 cellSpacingZ: spacingZ)
    }

    @Test func quadFillsCellProportionallyPerAxis() {
        let mark = make(scale: 0.5)
        #expect(abs(mark.width - 0.011) < 1e-6)
        #expect(abs(mark.depth - 0.011_85) < 1e-6)
    }

    @Test func maxParserScaleStillLeavesGaps() {
        // AnalysisLineParser caps scale at 0.65, so neighboring quads never
        // touch on either axis.
        let mark = make(scale: 0.65)
        #expect(mark.width < spacingX)
        #expect(mark.depth < spacingZ)
    }

    @Test func appearancePassesThroughDigitizedValues() {
        let mark = make(whiteness: 0.2, opacity: 0.35)
        #expect(mark.whiteness == 0.2)
        #expect(mark.opacity == 0.35)
    }

    @Test func materialKeyIsStableAcrossScaleAndPoint() {
        let a = make(scale: 0.13, point: BoardPoint(x: 0, y: 0))
        let b = make(scale: 0.65, point: BoardPoint(x: 18, y: 18))
        #expect(a.materialKey == b.materialKey)
    }

    @Test func materialKeyDistinguishesAppearanceBuckets() {
        let base = make(whiteness: 0.4, opacity: 0.6)
        #expect(make(whiteness: 0.6, opacity: 0.6).materialKey != base.materialKey)
        #expect(make(whiteness: 0.4, opacity: 0.8).materialKey != base.materialKey)
    }
}
