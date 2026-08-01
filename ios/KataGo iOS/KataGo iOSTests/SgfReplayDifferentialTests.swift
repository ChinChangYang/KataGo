//
//  SgfReplayDifferentialTests.swift
//  KataGo AnytimeTests
//
//  The watch draws saved games by replaying their SGF in pure Swift, with no
//  engine. This pins that replay to the C++ parser the app itself uses, so a
//  divergence shows up here rather than as a wrong board on someone's wrist.
//

import Testing
import Foundation
import GoRulesKit
import KataGoAnalysisKit
import KataGoGameStore
@testable import KataGoUICore

struct SgfReplayDifferentialTests {
    /// Replay's final position must equal the C++ parser's final position.
    private func expectAgreement(_ sgf: String, _ label: String) throws {
        let scan = try #require(SgfHeaderScan(sgf: sgf), "scan failed for \(label)")
        var replay = SgfReplay(scan: scan)
        let mine = replay.position(at: replay.moveCount)

        let operations = SgfOperations(sgf: sgf)
        let theirs = operations.finalStones()

        #expect(Set(mine.blackVertices) == Set(theirs.black), "black mismatch: \(label)")
        #expect(Set(mine.whiteVertices) == Set(theirs.white), "white mismatch: \(label)")
        #expect(replay.moveCount == operations.moveSize, "move count mismatch: \(label)")
        #expect(replay.anomalyIndex == nil, "replay refused a move: \(label)")
    }

    @Test func plainGameAgrees() throws {
        try expectAgreement(
            "(;FF[4]GM[1]SZ[19]KM[7];B[pd];W[dp];B[dd];W[pp];B[qn];W[nq])",
            "plain 19x19")
    }

    @Test func captureAgrees() throws {
        // White's corner stone dies; both parsers must remove it.
        try expectAgreement(
            "(;FF[4]GM[1]SZ[9]KM[7];B[bi];W[ai];B[ah])",
            "corner capture")
    }

    @Test func passesAgree() throws {
        try expectAgreement(
            "(;FF[4]GM[1]SZ[9]KM[7];B[cc];W[];B[gg];W[tt])",
            "passes")
    }

    @Test func handicapSetupAgrees() throws {
        try expectAgreement(
            "(;FF[4]GM[1]SZ[19]HA[2]KM[0]AB[pd][dp];W[dd];B[pp])",
            "two-stone handicap")
    }

    @Test func rectangularBoardAgrees() throws {
        try expectAgreement(
            "(;FF[4]GM[1]SZ[19:9]KM[7];B[aa];W[si];B[jd])",
            "19x9 rectangle")
    }

    @Test func ladderCaptureAgrees() throws {
        // A multi-stone capture: White's two-stone chain on the first line is
        // enclosed and taken.
        try expectAgreement(
            "(;FF[4]GM[1]SZ[9]KM[7];B[ah];W[ai];B[bh];W[bi];B[ci])",
            "two-stone capture")
    }

    @Test func defaultRecordSgfAgrees() throws {
        try expectAgreement(GameRecord.defaultSgf, "GameRecord.defaultSgf")
    }
}
