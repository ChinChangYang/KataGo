//
//  AnalysisColorTests.swift
//  KataGo AnytimeTests
//
//  Pins the 2D analysis quality-color mapping so the extraction into
//  analysisBaseHue/analysisBaseColor is provably behavior-preserving,
//  and so the 3D candidate markers share the exact same mapping.
//

import SwiftUI
import Testing
@testable import KataGoUICore

struct AnalysisColorTests {
    @Test func pinsDiscretizedHues() {
        // Values computed from the pre-extraction implementation
        // (AnalysisView.computeBaseColorByVisits) for these inputs.
        #expect(abs(analysisBaseHue(visits: 1, maxVisits: 100) - 0.0) <= 1e-6)
        #expect(abs(analysisBaseHue(visits: 25, maxVisits: 100) - 0.15) <= 1e-6)
        #expect(abs(analysisBaseHue(visits: 50, maxVisits: 100) - 0.25) <= 1e-6)
        #expect(abs(analysisBaseHue(visits: 100, maxVisits: 100) - 0.5) <= 1e-6)
    }

    @Test func hueIsMonotonicInVisits() {
        var previous: Double = -1
        for visits in stride(from: 1, through: 100, by: 3) {
            let hue = analysisBaseHue(visits: visits, maxVisits: 100)
            #expect(hue >= previous)
            previous = hue
        }
    }

    @Test func colorWrapsHueAtFullSaturationAndBrightness() {
        let color = analysisBaseColor(visits: 50, maxVisits: 100)
        #expect(color == Color(hue: 0.25, saturation: 1, brightness: 1))
    }

    @Test func zeroMaxVisitsDoesNotDivideByZero() {
        // ratio clamps via max(0.01, ...); must not crash or return NaN.
        let hue = analysisBaseHue(visits: 0, maxVisits: 0)
        #expect(hue.isFinite)
    }
}
