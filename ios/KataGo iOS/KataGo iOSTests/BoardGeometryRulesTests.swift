//
//  BoardGeometryRulesTests.swift
//  KataGo AnytimeTests
//
//  The analytic board construction rules that replaced the bundled
//  boards_manifest.json. Parity contract: the formulas must reproduce the
//  legacy manifest values for 9/13/19 exactly (they were generated from the
//  same parametric source), and generalize to any width x height in 2...37
//  with thickness/legs keyed off the width-matched square asset.
//

import Foundation
import Testing
@testable import KataGoUICore

struct BoardGeometryRulesTests {
    @Test func topHeightMatchesLegacyManifest() {
        #expect(abs(BoardGeometryRules.dimensions(width: 9, height: 9).topY - 0.062) <= 1e-4)
        #expect(abs(BoardGeometryRules.dimensions(width: 13, height: 13).topY - 0.088877) <= 1e-4)
        #expect(abs(BoardGeometryRules.dimensions(width: 19, height: 19).topY - 0.115842) <= 1e-4)
    }

    @Test func nineteenLegHeightIsClampLimited() {
        let dims = BoardGeometryRules.dimensions(width: 19, height: 19)
        #expect(abs(dims.legHeight - 0.070) <= 1e-9)
        let huge = BoardGeometryRules.dimensions(width: 37, height: 37)
        #expect(abs(huge.thickness - 0.060) <= 1e-9)
        #expect(abs(huge.legHeight - 0.070) <= 1e-9)
        let tiny = BoardGeometryRules.dimensions(width: 2, height: 2)
        #expect(abs(tiny.thickness - 0.012) <= 1e-9)
        #expect(abs(tiny.legHeight - 0.025) <= 1e-9)
    }

    @Test func cornersMatchLegacyManifest() {
        func corner(_ n: Int) -> SIMD3<Float> {
            let topY = BoardGeometryRules.dimensions(width: n, height: n).topY
            return BoardGeometryRules.intersection(x: 0, y: 0, width: n, height: n, topY: topY)
        }
        let nine = corner(9)
        #expect(abs(nine.x - -0.088) <= 1e-4 && abs(nine.y - 0.062) <= 1e-4 && abs(nine.z - 0.0948) <= 1e-4)
        let thirteen = corner(13)
        #expect(abs(thirteen.x - -0.132) <= 1e-4 && abs(thirteen.z - 0.1422) <= 1e-4)
        let nineteen = corner(19)
        #expect(abs(nineteen.x - -0.198) <= 1e-4 && abs(nineteen.z - 0.2133) <= 1e-4)
    }

    @Test func rectangularKeysThicknessOffWidth() {
        // A 13x9 board uses the 13-wide square slab depth-stretched, so its
        // top height equals the 13x13 board's.
        let rect = BoardGeometryRules.dimensions(width: 13, height: 9)
        let square = BoardGeometryRules.dimensions(width: 13, height: 13)
        #expect(abs(rect.topY - square.topY) <= 1e-9)
        #expect(abs(rect.boardXMM - 291.0) <= 1e-9)
        #expect(abs(rect.boardZMM - 219.0) <= 1e-9)
    }

    @Test func footClearanceHoldsAcrossTheFamily() {
        for width in 2...37 {
            for height in [2, width, 37] {
                let dims = BoardGeometryRules.dimensions(width: width, height: height)
                for halfMM in [dims.boardXMM / 2, dims.boardZMM / 2] {
                    let half = halfMM / 1000
                    let gap = 2 * (half - dims.inset - dims.footRadius)
                    #expect(gap >= 0.004 - 1e-9)
                    #expect(dims.inset + dims.footRadius <= half + 1e-12)
                }
            }
        }
    }

    @Test func evenSizesCenterTheGrid() {
        for n in [2, 6, 36] {
            let topY = BoardGeometryRules.dimensions(width: n, height: n).topY
            let first = BoardGeometryRules.intersection(x: 0, y: 0, width: n, height: n, topY: topY)
            let last = BoardGeometryRules.intersection(x: n - 1, y: n - 1, width: n, height: n, topY: topY)
            #expect(abs(first.x + last.x) <= 1e-6)
            #expect(abs(first.z + last.z) <= 1e-6)
        }
    }

    @Test func textureSizeMatchesPipeline() {
        // 5 px/mm target, long side clamped to [512, 2048], multiples of 4.
        // 9x9 and 19x19 reproduce the shipped baked texture dimensions.
        #expect(BoardGeometryRules.textureSize(width: 9, height: 9) == SIMD2<Int>(1016, 1096))
        #expect(BoardGeometryRules.textureSize(width: 19, height: 19) == SIMD2<Int>(1900, 2048))
        #expect(BoardGeometryRules.textureSize(width: 37, height: 37) == SIMD2<Int>(1900, 2048))
        // Wide rectangle: the long side is the WIDTH, so the clamp binds there.
        let wide = BoardGeometryRules.textureSize(width: 19, height: 9)
        #expect(wide.x == 2048)
        #expect(wide.y % 4 == 0 && wide.y < 1100)
        let small = BoardGeometryRules.textureSize(width: 2, height: 2)
        #expect(small.x % 4 == 0 && small.y >= 512)
    }
}

struct BoardSceneGeometryAnalyticTests {
    private func expectClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float = 1e-4) {
        #expect(abs(a.x - b.x) <= tolerance)
        #expect(abs(a.y - b.y) <= tolerance)
        #expect(abs(a.z - b.z) <= tolerance)
    }

    @Test func analyticNineMatchesLegacyManifestContract() throws {
        let geometry = BoardSceneGeometry(width: 9, height: 9)
        let a1 = try #require(geometry.position(of: BoardPoint(x: 0, y: 0)))
        expectClose(a1, SIMD3<Float>(-0.088, 0.062, 0.0948))
        let j9 = try #require(geometry.position(of: BoardPoint(x: 8, y: 8)))
        expectClose(j9, SIMD3<Float>(0.088, 0.062, -0.0948))
        let tengen = try #require(geometry.position(of: BoardPoint(x: 4, y: 4)))
        expectClose(tengen, SIMD3<Float>(0, 0.062, 0))
        #expect(geometry.width == 9 && geometry.height == 9)
        #expect(abs(geometry.topY - 0.062) <= 1e-4)
    }

    @Test func rectangularBoundsAndPositions() throws {
        let geometry = BoardSceneGeometry(width: 13, height: 9)
        // 13x13 top height (width-keyed), 13-wide x span, 9-deep z span.
        let a1 = try #require(geometry.position(of: BoardPoint(x: 0, y: 0)))
        expectClose(a1, SIMD3<Float>(-0.132, 0.088877, 0.0948))
        let far = try #require(geometry.position(of: BoardPoint(x: 12, y: 8)))
        expectClose(far, SIMD3<Float>(0.132, 0.088877, -0.0948))
        #expect(geometry.position(of: BoardPoint(x: 13, y: 0)) == nil)
        #expect(geometry.position(of: BoardPoint(x: 0, y: 9)) == nil)
        #expect(geometry.vertex(for: BoardPoint(x: 12, y: 8)) == "N9")
        #expect(geometry.vertex(for: BoardPoint(x: 0, y: 9)) == nil)
    }

    @Test func nearestPointRoundTripsOnRectangle() throws {
        let geometry = BoardSceneGeometry(width: 13, height: 9)
        for point in [BoardPoint(x: 0, y: 0), BoardPoint(x: 12, y: 8), BoardPoint(x: 6, y: 4)] {
            let position = try #require(geometry.position(of: point))
            let nearest = geometry.nearestPoint(toX: position.x + 0.009, z: position.z - 0.010)
            #expect(nearest == point)
        }
        #expect(geometry.nearestPoint(toX: -10, z: 10) == BoardPoint(x: 0, y: 0))
        #expect(geometry.nearestPoint(toX: 10, z: -10) == BoardPoint(x: 12, y: 8))
    }

    @Test func thirtySevenVertexUsesDoubleLetters() throws {
        let geometry = BoardSceneGeometry(width: 37, height: 37)
        #expect(geometry.vertex(for: BoardPoint(x: 36, y: 36)) == "AM37")
    }
}
