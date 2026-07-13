//
//  BoardAssetManifestTests.swift
//  KataGo AnytimeTests
//

import Foundation
import Testing
@testable import KataGoUICore

struct BoardAssetManifestTests {
    @Test func parsesFixtureAndLooksUpEntry() throws {
        let manifest = try BoardAssetManifest.parse(VisionTestFixtures.manifest9x9JSON())

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.spacing.x == 0.022)
        #expect(manifest.spacing.z == 0.0237)
        #expect(manifest.stoneRef.diameter == 0.0224)
        #expect(manifest.stoneRef.thickness == 0.0096)

        let entry = try #require(manifest.entry(forSquareSize: 9))
        #expect(entry.n == 9)
        #expect(entry.fileUSDZ == "go_board_9x9.usdz")
        #expect(entry.topY == 0.062)
        #expect(entry.hoshi.count == 5)
        #expect(entry.intersections.count == 9)
        #expect(entry.intersections.allSatisfy { $0.count == 9 })
    }

    @Test func missingSizeReturnsNil() throws {
        let manifest = try BoardAssetManifest.parse(VisionTestFixtures.manifest9x9JSON())
        #expect(manifest.entry(forSquareSize: 13) == nil)
        #expect(manifest.entry(forSquareSize: 19) == nil)
    }

    @Test func rejectsTruncatedIntersections() {
        #expect(throws: (any Error).self) {
            try BoardAssetManifest.parse(VisionTestFixtures.manifest9x9JSON(truncateLastRow: true))
        }
    }
}
