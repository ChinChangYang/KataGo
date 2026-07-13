//
//  BoardSceneGeometryTests.swift
//  KataGo AnytimeTests
//
//  Orientation lock-in for the 3D goban: viewer at the volume front (+Z),
//  GTP row 1 nearest the viewer, column A on the viewer's left (-X).
//

import Foundation
import Testing
@testable import KataGoUICore

struct BoardSceneGeometryTests {
    private func geometry9() throws -> BoardSceneGeometry {
        let manifest = try BoardAssetManifest.parse(VisionTestFixtures.manifest9x9JSON())
        let entry = try #require(manifest.entry(forSquareSize: 9))
        return BoardSceneGeometry(entry: entry)
    }

    private func expectClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float = 1e-6) {
        #expect(abs(a.x - b.x) <= tolerance)
        #expect(abs(a.y - b.y) <= tolerance)
        #expect(abs(a.z - b.z) <= tolerance)
    }

    @Test func cornersMatchOrientationContract() throws {
        let geometry = try geometry9()

        // A1 = front-left: minimum x, maximum z (real manifest values).
        let a1 = try #require(geometry.position(of: BoardPoint(x: 0, y: 0)))
        expectClose(a1, SIMD3<Float>(-0.088, 0.062, 0.0948))

        // J1 = front-right (x index 8 is "J": GTP skips the letter I).
        let j1 = try #require(geometry.position(of: BoardPoint(x: 8, y: 0)))
        expectClose(j1, SIMD3<Float>(0.088, 0.062, 0.0948))

        // A9 = far-left.
        let a9 = try #require(geometry.position(of: BoardPoint(x: 0, y: 8)))
        expectClose(a9, SIMD3<Float>(-0.088, 0.062, -0.0948))

        // J9 = far-right.
        let j9 = try #require(geometry.position(of: BoardPoint(x: 8, y: 8)))
        expectClose(j9, SIMD3<Float>(0.088, 0.062, -0.0948))

        // Tengen sits on the origin at board-top height.
        let tengen = try #require(geometry.position(of: BoardPoint(x: 4, y: 4)))
        expectClose(tengen, SIMD3<Float>(0, 0.062, 0))

        #expect(geometry.size == 9)
        #expect(abs(geometry.topY - 0.062) <= 1e-6)
    }

    @Test func outOfRangeIsNil() throws {
        let geometry = try geometry9()
        #expect(geometry.position(of: BoardPoint(x: -1, y: 0)) == nil)
        #expect(geometry.position(of: BoardPoint(x: 0, y: 9)) == nil)
        #expect(geometry.position(of: BoardPoint(x: 9, y: 9)) == nil)
    }

    @Test func vertexStringsFollowGtp() throws {
        let geometry = try geometry9()
        #expect(geometry.vertex(for: BoardPoint(x: 0, y: 0)) == "A1")
        #expect(geometry.vertex(for: BoardPoint(x: 8, y: 0)) == "J1")
        #expect(geometry.vertex(for: BoardPoint(x: 0, y: 8)) == "A9")
        #expect(geometry.vertex(for: BoardPoint(x: 4, y: 4)) == "E5")
        #expect(geometry.vertex(for: BoardPoint(x: 9, y: 0)) == nil)
    }

    @Test func nearestPointRoundTripsWithJitter() throws {
        let geometry = try geometry9()
        for point in [BoardPoint(x: 0, y: 0), BoardPoint(x: 8, y: 8), BoardPoint(x: 4, y: 4), BoardPoint(x: 2, y: 6)] {
            let position = try #require(geometry.position(of: point))
            // Jitter by less than half a grid step in each axis.
            let nearest = geometry.nearestPoint(toX: position.x + 0.009, z: position.z - 0.010)
            #expect(nearest == point)
        }
    }

    @Test func nearestPointClampsOutsideBoard() throws {
        let geometry = try geometry9()
        #expect(geometry.nearestPoint(toX: -10, z: 10) == BoardPoint(x: 0, y: 0))
        #expect(geometry.nearestPoint(toX: 10, z: -10) == BoardPoint(x: 8, y: 8))
    }
}
