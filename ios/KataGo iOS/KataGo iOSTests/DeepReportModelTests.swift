//
//  DeepReportModelTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct DeepReportModelTests {
    @Test func perspectiveConvertsWhiteValuesToSide() {
        #expect(abs(ReportPerspective.winrate(0.61, for: .white) - 0.61) < 1e-6)
        #expect(abs(ReportPerspective.winrate(0.61, for: .black) - 0.39) < 1e-6)
        #expect(abs(ReportPerspective.score(3.5, for: .white) - 3.5) < 1e-6)
        #expect(abs(ReportPerspective.score(3.5, for: .black) - (-3.5)) < 1e-6)
    }

    @Test func deltaGridSubtractsPerPoint() {
        // 2x2, emission order: (0,1),(1,1),(0,0),(1,0) — y from height-1 down.
        let base: [Float] = [0.0, 0.5, -0.5, 1.0]
        let probe: [Float] = [0.2, 0.5, -1.0, 1.0]
        let grid = OwnershipDelta.grid(base: base, probe: probe, width: 2, height: 2)
        #expect(abs((grid[BoardPoint(x: 0, y: 1)] ?? 0) - 0.2) < 1e-6)
        #expect(abs((grid[BoardPoint(x: 1, y: 1)] ?? 0) - 0.0) < 1e-6)
        #expect(abs((grid[BoardPoint(x: 0, y: 0)] ?? 0) - (-0.5)) < 1e-6)
    }

    @Test func deltaGridEmptyOnMismatch() {
        #expect(OwnershipDelta.grid(base: [0, 0], probe: [0, 0, 0, 0], width: 2, height: 2).isEmpty)
    }

    @Test func contestedPointsAreTop8ByMagnitude() {
        var grid: [BoardPoint: Float] = [:]
        for x in 0..<10 {
            grid[BoardPoint(x: x, y: 0)] = Float(x) * 0.1 - 0.5   // magnitudes 0.5 ... 0.4
        }
        let points = OwnershipDelta.contestedPoints(in: grid, width: 19, height: 19)
        #expect(points.count == 8)
        #expect(abs(points[0].delta.magnitude - 0.5) < 1e-6)      // biggest |Δ| first
        #expect(points.allSatisfy { !$0.regionName.isEmpty && !$0.vertex.isEmpty })
    }

    @Test func regionNamesFollowBoardThirds() {
        // BoardPoint y is 0 at the BOTTOM row; high y = upper side.
        #expect(OwnershipDelta.regionName(point: BoardPoint(x: 0, y: 18), width: 19, height: 19) == "upper left")
        #expect(OwnershipDelta.regionName(point: BoardPoint(x: 18, y: 0), width: 19, height: 19) == "lower right")
        #expect(OwnershipDelta.regionName(point: BoardPoint(x: 9, y: 9), width: 19, height: 19) == "center")
        #expect(OwnershipDelta.regionName(point: BoardPoint(x: 9, y: 18), width: 19, height: 19) == "upper center")
    }

    @Test @MainActor func modelStageDrivesIsGenerating() {
        let model = DeepReportModel()
        #expect(model.isGenerating == false)
        model.stage = .snapshot
        #expect(model.isGenerating == true)
        model.stage = .tenuki(1)
        #expect(model.isGenerating == true)
        model.stage = .complete
        #expect(model.isGenerating == false)
        model.stage = .failed("x")
        #expect(model.isGenerating == false)
    }
}
