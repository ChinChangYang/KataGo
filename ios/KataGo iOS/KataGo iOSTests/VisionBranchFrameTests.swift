//
//  VisionBranchFrameTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure geometry behind the visionOS red branch frame — the 3D
//  stand-in for iOS's red rectangle around the goban while a branch is
//  active: four corner-tiled opaque bars hugging the board-top perimeter,
//  sized from the same analytic BoardGeometryRules the board itself uses,
//  adapting to any rectangle in 2...37.
//

import Testing
import simd
@testable import KataGoUICore

struct VisionBranchFrameTests {
    private let epsilon: Float = 1e-6

    @Test func nineteenFrameHasFourCornerTiledBars() {
        // 19x19 slab: 18*22+27 = 423 mm by 18*23.7+29.4 = 456 mm.
        let frame = VisionBranchFrame.make(width: 19, height: 19)
        let t = VisionBranchFrame.barThickness
        let h = VisionBranchFrame.barHeight
        #expect(frame.bars.count == 4)

        let far = frame.bars[0], near = frame.bars[1]
        let left = frame.bars[2], right = frame.bars[3]
        // Far/near span the full X extent; left/right tile between them.
        #expect(abs(far.size.x - 0.423) < epsilon)
        #expect(abs(far.size.z - t) < epsilon)
        #expect(abs(near.size.x - 0.423) < epsilon)
        #expect(abs(left.size.x - t) < epsilon)
        #expect(abs(left.size.z - (0.456 - 2 * t)) < epsilon)
        #expect(abs(right.size.z - (0.456 - 2 * t)) < epsilon)
        for bar in frame.bars {
            #expect(abs(bar.size.y - h) < epsilon)
        }
        #expect(abs(far.center.z - -(0.456 / 2 - t / 2)) < epsilon)
        #expect(abs(near.center.z - (0.456 / 2 - t / 2)) < epsilon)
        #expect(abs(left.center.x - -(0.423 / 2 - t / 2)) < epsilon)
        #expect(abs(right.center.x - (0.423 / 2 - t / 2)) < epsilon)
        #expect(abs(far.center.x) < epsilon)
        #expect(abs(left.center.z) < epsilon)
    }

    @Test func barsSitJustAboveTheBoardTop() {
        for (width, height) in [(19, 19), (6, 15), (2, 2), (37, 37)] {
            let frame = VisionBranchFrame.make(width: width, height: height)
            let expectedY = Float(BoardGeometryRules
                .dimensions(width: width, height: height).topY)
                + VisionBranchFrame.lift + VisionBranchFrame.barHeight / 2
            for bar in frame.bars {
                #expect(abs(bar.center.y - expectedY) < epsilon)
            }
        }
    }

    @Test func rectangularBoardAdaptsSpans() {
        // 6x15 slab: 5*22+27 = 137 mm by 14*23.7+29.4 = 361.2 mm.
        let frame = VisionBranchFrame.make(width: 6, height: 15)
        let t = VisionBranchFrame.barThickness
        #expect(abs(frame.bars[0].size.x - 0.137) < epsilon)
        #expect(abs(frame.bars[2].size.z - (0.3612 - 2 * t)) < epsilon)
        #expect(abs(frame.bars[0].center.z - -(0.3612 / 2 - t / 2)) < epsilon)
        #expect(abs(frame.bars[2].center.x - -(0.137 / 2 - t / 2)) < epsilon)
    }

    @Test func frameIsSymmetricAboutBothAxes() {
        let frame = VisionBranchFrame.make(width: 6, height: 15)
        let far = frame.bars[0], near = frame.bars[1]
        let left = frame.bars[2], right = frame.bars[3]
        #expect(abs(far.center.z + near.center.z) < epsilon)
        #expect(abs(left.center.x + right.center.x) < epsilon)
        #expect(far.size == near.size)
        #expect(left.size == right.size)
    }

    @Test func frameStaysInsideTheSlabFootprint() {
        for (width, height) in [(2, 2), (37, 37), (6, 15), (19, 19)] {
            let mm = BoardGeometryRules.boardMM(width: width, height: height)
            let halfX = Float(mm.x / 1000) / 2
            let halfZ = Float(mm.z / 1000) / 2
            let frame = VisionBranchFrame.make(width: width, height: height)
            for bar in frame.bars {
                #expect(abs(bar.center.x) + bar.size.x / 2 <= halfX + epsilon)
                #expect(abs(bar.center.z) + bar.size.z / 2 <= halfZ + epsilon)
            }
        }
    }

    @Test func cornerTilingNeverOverlaps() {
        for (width, height) in [(2, 2), (37, 37), (6, 15)] {
            let frame = VisionBranchFrame.make(width: width, height: height)
            let far = frame.bars[0], near = frame.bars[1]
            let left = frame.bars[2]
            // The side bars' z extent ends where the near/far bands begin.
            let sideMaxZ = left.center.z + left.size.z / 2
            let sideMinZ = left.center.z - left.size.z / 2
            let nearMinZ = near.center.z - near.size.z / 2
            let farMaxZ = far.center.z + far.size.z / 2
            #expect(sideMaxZ <= nearMinZ + epsilon)
            #expect(sideMinZ >= farMaxZ - epsilon)
        }
    }
}
