//
//  SgfReplayTests.swift
//  GoRulesKitTests
//
//  Locks in the engine-free replay the watch uses to draw any position of a
//  saved game without the phone or the C++ engine.
//

import Foundation
import Testing
@testable import GoRulesKit
import KataGoAnalysisKit

struct SgfReplayTests {
    private func replay(_ sgf: String) throws -> SgfReplay {
        SgfReplay(scan: try #require(SgfHeaderScan(sgf: sgf)))
    }

    @Test func emptyPositionAtIndexZero() throws {
        var r = try replay("(;GM[1]SZ[9];B[cc];W[gg])")
        let p = r.position(at: 0)
        #expect(p.blackVertices.isEmpty)
        #expect(p.whiteVertices.isEmpty)
        #expect(p.lastMoveVertex == nil)
        #expect(p.toMove == .black)
    }

    @Test func playsMovesInOrder() throws {
        var r = try replay("(;GM[1]SZ[9];B[cc];W[gg])")
        #expect(r.moveCount == 2)
        let one = r.position(at: 1)
        #expect(one.blackVertices == ["C7"])
        #expect(one.whiteVertices.isEmpty)
        #expect(one.lastMoveVertex == "C7")
        #expect(one.toMove == .white)

        let two = r.position(at: 2)
        #expect(two.blackVertices == ["C7"])
        #expect(two.whiteVertices == ["G3"])
        #expect(two.lastMoveVertex == "G3")
        #expect(two.toMove == .black)
    }

    @Test func indexIsClampedToTheMoveRange() throws {
        var r = try replay("(;GM[1]SZ[9];B[cc];W[gg])")
        #expect(r.position(at: -5) == r.position(at: 0))
        #expect(r.position(at: 99) == r.position(at: 2))
    }

    @Test func capturesAreApplied() throws {
        // Black surrounds a lone White stone in the corner (a1) and takes it.
        // W a1 = "ai" on a 9x9 (y = 8). Black plays b1 ("bi") and a2 ("ah").
        var r = try replay("(;GM[1]SZ[9];B[bi];W[ai];B[ah])")
        let p = r.position(at: 3)
        #expect(p.whiteVertices.isEmpty)
        #expect(Set(p.blackVertices) == Set(["B1", "A2"]))
    }

    @Test func passesAdvanceTheIndexWithoutChangingTheBoard() throws {
        var r = try replay("(;GM[1]SZ[9];B[cc];W[];B[gg])")
        #expect(r.moveCount == 3)
        let afterPass = r.position(at: 2)
        #expect(afterPass.blackVertices == ["C7"])
        #expect(afterPass.whiteVertices.isEmpty)
        #expect(afterPass.lastMoveVertex == nil)
        #expect(afterPass.toMove == .black)
    }

    @Test func setupStonesSeedThePosition() throws {
        var r = try replay("(;GM[1]SZ[19]HA[2]AB[pd][dp];W[dd])")
        let start = r.position(at: 0)
        #expect(Set(start.blackVertices) == Set(["Q16", "D4"]))
        #expect(start.toMove == .white)
        let one = r.position(at: 1)
        #expect(one.whiteVertices == ["D16"])
    }

    @Test func replayingFromACheckpointMatchesReplayingFromZero() throws {
        // 60 moves on every other intersection, so no stone ever touches
        // another: no captures, no suicide, and every move stays on a 19x19
        // board. That isolates what this test is about — the stride-25
        // checkpoints — from rules behaviour covered elsewhere.
        var sgf = "(;GM[1]SZ[19]"
        for index in 0..<60 {
            let color = index.isMultiple(of: 2) ? "B" : "W"
            let column = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(2 * (index % 8))))
            let row = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(2 * (index / 8))))
            sgf += ";\(color)[\(column)\(row)]"
        }
        sgf += ")"

        var forward = try replay(sgf)
        var backward = try replay(sgf)
        var expected: [SgfReplay.Position] = []
        for index in 0...60 { expected.append(forward.position(at: index)) }
        for index in stride(from: 60, through: 0, by: -1) {
            #expect(backward.position(at: index) == expected[index])
        }
        #expect(forward.anomalyIndex == nil)
    }

    @Test func aRefusedMoveIsSkippedAndRecorded() throws {
        // The second Black move repeats an occupied point; replay must skip it
        // and keep going rather than corrupting every later index.
        var r = try replay("(;GM[1]SZ[9];B[cc];W[gg];B[cc];W[dd])")
        let p = r.position(at: 4)
        #expect(Set(p.blackVertices) == Set(["C7"]))
        #expect(Set(p.whiteVertices) == Set(["G3", "D6"]))
        #expect(r.anomalyIndex == 2)
    }

    @Test func rectangularBoardsReplay() throws {
        var r = try replay("(;GM[1]SZ[19:9];B[aa];W[si])")
        #expect(r.width == 19)
        #expect(r.height == 9)
        let p = r.position(at: 2)
        #expect(p.blackVertices == ["A9"])
        #expect(p.whiteVertices == ["T1"])
    }

    @Test func compressedSetupRangeSeedsEveryPointInTheRectangle() throws {
        // AB[dd:ff] on a 9x9 is the 3x3 rectangle (3,3)...(5,5).
        var r = try replay("(;GM[1]SZ[9]AB[dd:ff];W[aa])")
        let start = r.position(at: 0)
        #expect(Set(start.blackVertices) == Set(["D6", "E6", "F6", "D5", "E5", "F5", "D4", "E4", "F4"]))
    }

    @Test func aeRemovesASetupStoneBeforeAnyMoveIsPlayed() throws {
        var r = try replay("(;GM[1]SZ[9]AB[dd][ee]AE[dd];W[aa])")
        let start = r.position(at: 0)
        #expect(start.blackVertices == ["E5"])
    }

    @Test func aeOnAPointNothingPlacedIsANoOp() throws {
        var r = try replay("(;GM[1]SZ[9]AB[dd]AE[gg];W[aa])")
        let start = r.position(at: 0)
        #expect(start.blackVertices == ["D6"])
        #expect(r.anomalyIndex == nil)
    }
}
