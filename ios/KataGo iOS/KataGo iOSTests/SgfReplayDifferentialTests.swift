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

    @Test func compressedSetupRangeAgrees() throws {
        // AB[cc:ee] at the root: both parsers now expand FF[4] compressed
        // point ranges (SgfHeaderScan.points, cpp/dataio/sgf.cpp's
        // parseSgfLocRectangle), so they should agree.
        try expectAgreement(
            "(;FF[4]GM[1]SZ[9]KM[7]AB[cc:ee];W[gg])",
            "compressed AB range")
    }

    @Test func aeSetupRemovalAgrees() throws {
        // AE[ee] at the root targets a point NEITHER AB nor any move ever
        // touches — deliberately, NOT "AE cancels an AB in the same node"
        // (e.g. AB[cc]AE[cc]): that collides in the C++ side's own
        // Board::setStonesFailIfNoLibs, which rejects ANY duplicate loc
        // across the accumulated root placements regardless of color —
        // an AB-then-AE-same-point root node throws there (caught, empty
        // position), a PRE-EXISTING, unrelated engine limitation this fix
        // does not touch. Genuine "AE removes a stone AB just placed" is
        // pinned engine-free instead, in GoRulesKitTests'
        // aeRemovesASetupStoneBeforeAnyMoveIsPlayed. This case exists to
        // confirm AE parses and plumbs through to agreement for the
        // non-colliding shape.
        try expectAgreement(
            "(;FF[4]GM[1]SZ[9]KM[7]AB[cc][dd]AE[ee];W[gg])",
            "AE setup removal (non-colliding)")
    }

    @Test func midGameSetupNodeIsTheDocumentedOutOfScopeGap() throws {
        // AB[gg] sits on a node AFTER the root, mid-game. SgfHeaderScan
        // collects every AB/AW/AE it finds anywhere on the mainline into one
        // flat list, and SgfReplay applies that whole list at index 0 (the
        // documented, explicitly out-of-scope limitation — see
        // SgfHeaderScan.setupEmpty's doc comment). Here the premature `gg`
        // stone collides with a LATER real move at the same point.
        let sgf = "(;FF[4]GM[1]SZ[9]KM[7];B[cc];W[dd];AB[gg];B[hh];W[gg])"
        let scan = try #require(SgfHeaderScan(sgf: sgf))
        var replay = SgfReplay(scan: scan)
        let mine = replay.position(at: replay.moveCount)

        // WHAT SgfReplay ACTUALLY DOES: `gg` is already black (from the
        // premature index-0 setup) by the time the real `W[gg]` move is
        // replayed, so that move is refused and skipped — exactly the
        // failure mode Fix 2c's safety valve exists to catch.
        #expect(Set(mine.blackVertices) == Set(["C7", "G3", "H2"]))
        #expect(Set(mine.whiteVertices) == Set(["D6"]))
        #expect(replay.anomalyIndex == 3)

        // WHAT THE C++ PARSER ACTUALLY DOES: CompactSgf does not support
        // AB/AW placements after the root node AT ALL (see SgfCpp.cpp's
        // buildFrame comment) — setupBoardAndHistTolerant throws internally,
        // caught, and getFinalPosition() degrades to a completely EMPTY
        // position rather than a partial-but-wrong board.
        let operations = SgfOperations(sgf: sgf)
        let theirs = operations.finalStones()
        #expect(theirs.black.isEmpty)
        #expect(theirs.white.isEmpty)

        // moveSize is a simpler pre-CompactSgf tally (real B/W nodes only),
        // so it is unaffected by that failure and still agrees.
        #expect(replay.moveCount == operations.moveSize)

        // DIVERGENCE: the two parsers agree on NEITHER stone set for this
        // out-of-scope input. Swift renders a confident, partially-wrong
        // board (flagged via a non-nil anomalyIndex, which is what makes
        // WatchBrowseModel.isReadable gate this game unreadable on the
        // watch); the C++ side gives up entirely and renders nothing. Both
        // are "wrong" in different ways — pinned here rather than silently
        // accepted, per the mid-game setup scope decision in Fix 2.
    }
}
