//
//  SgfReplayDifferentialTests.swift
//  KataGo AnytimeTests
//
//  The board draws the record position by replaying its SGF in pure Swift,
//  with no engine. This pins that replay to the C++ parser the app itself
//  uses — stones, capture counts, move list and setup stones — so a
//  divergence shows up here rather than as a wrong board on screen.
//
//  Two constructions of the same replay are pinned equal at every index: the
//  bridge-free `SgfHeaderScan` one (all the watch can build) and the
//  `SgfOperations` one built from the C++ parser's placements + move list
//  (what the app builds). Two parsers over one index space would desync, so
//  they are held to be indistinguishable.
//

import Testing
import Foundation
import GoRulesKit
import KataGoAnalysisKit
import KataGoGameStore
@testable import KataGoUICore

struct SgfReplayDifferentialTests {
    struct Fixture: CustomStringConvertible {
        let label: String
        let sgf: String

        var description: String { label }
    }

    /// Every SGF both parsers must agree on, so a fixture added here is
    /// covered by the position AND the move-list/construction tests at once.
    static let fixtures: [Fixture] = [
        Fixture(label: "plain 19x19",
                sgf: "(;FF[4]GM[1]SZ[19]KM[7];B[pd];W[dp];B[dd];W[pp];B[qn];W[nq])"),
        // White's corner stone dies; both parsers must remove it.
        Fixture(label: "corner capture",
                sgf: "(;FF[4]GM[1]SZ[9]KM[7];B[bi];W[ai];B[ah])"),
        Fixture(label: "passes",
                sgf: "(;FF[4]GM[1]SZ[9]KM[7];B[cc];W[];B[gg];W[tt])"),
        Fixture(label: "two-stone handicap",
                sgf: "(;FF[4]GM[1]SZ[19]HA[2]KM[0]AB[pd][dp];W[dd];B[pp])"),
        Fixture(label: "19x9 rectangle",
                sgf: "(;FF[4]GM[1]SZ[19:9]KM[7];B[aa];W[si];B[jd])"),
        // A multi-stone capture: White's two-stone chain on the first line is
        // enclosed and taken.
        Fixture(label: "two-stone capture",
                sgf: "(;FF[4]GM[1]SZ[9]KM[7];B[ah];W[ai];B[bh];W[bi];B[ci])"),
        Fixture(label: "GameRecord.defaultSgf", sgf: GameRecord.defaultSgf),
        // AB[cc:ee] at the root: both parsers expand FF[4] compressed point
        // ranges (SgfHeaderScan.points, cpp/dataio/sgf.cpp's
        // parseSgfLocRectangle), so they should agree.
        Fixture(label: "compressed AB range",
                sgf: "(;FF[4]GM[1]SZ[9]KM[7]AB[cc:ee];W[gg])"),
        // AE[ee] at the root targets a point NEITHER AB nor any move ever
        // touches — deliberately, NOT "AE cancels an AB in the same node"
        // (e.g. AB[cc]AE[cc]): that collides in the C++ side's own
        // Board::setStonesFailIfNoLibs, which rejects ANY duplicate loc across
        // the accumulated root placements regardless of color — an
        // AB-then-AE-same-point root node throws there (caught, empty
        // position), a PRE-EXISTING, unrelated engine limitation. Genuine "AE
        // removes a stone AB just placed" is pinned engine-free instead, in
        // GoRulesKitTests' aeRemovesASetupStoneBeforeAnyMoveIsPlayed.
        Fixture(label: "AE setup removal (non-colliding)",
                sgf: "(;FF[4]GM[1]SZ[9]KM[7]AB[cc][dd]AE[ee];W[gg])"),
        // The rest are raw-import shapes: SGFs as other tools write them,
        // which reach the app unnormalised now that the loadsgf -> printsgf
        // echo is gone. No variations — the two parsers pick a branch by
        // DIFFERENT rules (scan: first child; C++: deepest child), a known
        // divergence that mainline-only records never hit.
        Fixture(label: "raw import: CGoban handicap with tt passes",
                sgf: "(;GM[1]FF[4]CA[UTF-8]AP[CGoban:3]ST[2]RU[Japanese]SZ[19]"
                    + "KM[0.50]HA[3]AB[dd][pd][dp]PW[White]PB[Black]"
                    + ";W[pp];B[qn];W[np];B[tt];W[tt])"),
        // Escaped "]" and a node-shaped run inside a comment: both parsers
        // have to read the value as text and not find moves in it.
        Fixture(label: "raw import: comment with brackets and semicolons",
                sgf: "(;FF[4]GM[1]SZ[9]KM[7];B[cc]C[Good shape; see (;W[gg\\]) and \\] too.]"
                    + ";W[gg];B[dd])"),
        Fixture(label: "raw import: compressed AB range plus AW and passes",
                sgf: "(;FF[4]GM[1]SZ[13]KM[6.5]AB[dd:ee]AW[jj];B[gg];W[];B[])"),
        Fixture(label: "raw import: no SZ property",
                sgf: "(;FF[4]GM[1]KM[0.5]HA[2]AB[pd][dp];W[dd];B[pp];W[cq])"),
    ]

    // MARK: - Position agreement

    @Test(arguments: fixtures)
    func finalPositionAgrees(fixture: Fixture) throws {
        try expectAgreement(fixture.sgf, fixture.label)
    }

    /// Replay's final position — stones AND capture counts — must equal the
    /// C++ parser's.
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

        let captures = cppCaptureCounts(sgf: sgf)
        #expect(mine.blackCaptures == captures.black, "B stones captured mismatch: \(label)")
        #expect(mine.whiteCaptures == captures.white, "W stones captured mismatch: \(label)")
    }

    /// Capture counts as the C++ replay implies them. For each ply, the stones
    /// of a colour standing before it — plus the stone that ply placed — that
    /// are gone after it. Adding the played stone is what makes a suicide
    /// count, which is exactly what `Board::numBlackCaptures` /
    /// `numWhiteCaptures` do (cpp/game/board.h).
    private func cppCaptureCounts(sgf: String) -> (black: Int, white: Int) {
        let helper = SgfHelper(sgf: sgf)
        let frames = helper.gifFrames()
        guard frames.count > 1 else { return (black: 0, white: 0) }

        var black = 0
        var white = 0
        for index in 1..<frames.count {
            var beforeBlack = Set(frames[index - 1].blackStones)
            var beforeWhite = Set(frames[index - 1].whiteStones)
            if let move = helper.getMove(at: index - 1), !move.location.pass {
                let vertex = GoPoint(x: move.location.x, y: move.location.y)
                    .gtpVertex(boardHeight: helper.ySize)
                if move.player == .black {
                    beforeBlack.insert(vertex)
                } else {
                    beforeWhite.insert(vertex)
                }
            }
            black += beforeBlack.subtracting(Set(frames[index].blackStones)).count
            white += beforeWhite.subtracting(Set(frames[index].whiteStones)).count
        }
        return (black: black, white: white)
    }

    // MARK: - The two constructions

    @Test(arguments: fixtures)
    func scanAndCppMoveListsAgree(fixture: Fixture) throws {
        let scan = try #require(SgfHeaderScan(sgf: fixture.sgf), "scan failed for \(fixture)")
        let operations = SgfOperations(sgf: fixture.sgf)
        try #require(operations.moveSize == scan.moves.count,
                     "move count mismatch: \(fixture)")

        for index in scan.moves.indices {
            let mine = scan.moves[index]
            let theirs = try #require(operations.getMove(at: index),
                                      "C++ has no move \(index): \(fixture)")
            #expect((theirs.player == .black) == (mine.color == .black),
                    "colour mismatch at \(index): \(fixture)")
            if let point = mine.point {
                #expect(!theirs.location.pass, "pass mismatch at \(index): \(fixture)")
                #expect(theirs.location.x == point.x && theirs.location.y == point.y,
                        "point mismatch at \(index): \(fixture)")
            } else {
                #expect(theirs.location.pass, "expected a pass at \(index): \(fixture)")
            }
        }

        var fromScan = SgfReplay(scan: scan)
        var fromCpp = try cppReplay(sgf: fixture.sgf)
        #expect(fromCpp.width == fromScan.width, "width mismatch: \(fixture)")
        #expect(fromCpp.height == fromScan.height, "height mismatch: \(fixture)")
        #expect(fromCpp.moveCount == fromScan.moveCount, "move count mismatch: \(fixture)")
        for index in 0...fromScan.moveCount {
            #expect(fromCpp.position(at: index) == fromScan.position(at: index),
                    "positions diverge at index \(index): \(fixture)")
        }
        #expect(fromCpp.refusedIndices == fromScan.refusedIndices,
                "refusals diverge: \(fixture)")
    }

    /// The replay built the way the app builds it: geometry, setup stones and
    /// moves all from the C++ parser, never from the bridge-free scan.
    private func cppReplay(sgf: String) throws -> SgfReplay {
        let operations = SgfOperations(sgf: sgf)
        let placements = operations.placements()
        func points(_ kind: Placement.Kind) -> [GoPoint] {
            placements.filter { $0.kind == kind }.map { GoPoint(x: $0.x, y: $0.y) }
        }
        let moves = try (0..<(operations.moveSize ?? 0)).map { index -> SgfReplay.RecordedMove in
            let move = try #require(operations.getMove(at: index))
            return SgfReplay.RecordedMove(
                color: move.player == .black ? .black : .white,
                point: move.location.pass
                    ? nil
                    : GoPoint(x: move.location.x, y: move.location.y))
        }
        return SgfReplay(width: operations.xSize, height: operations.ySize,
                         setupBlack: points(.black),
                         setupWhite: points(.white),
                         setupEmpty: points(.removal),
                         moves: moves)
    }

    // MARK: - Documented divergence

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

        // The placements bridge reads the ROOT node only (Sgf::getPlacements),
        // so it reports no setup at all here rather than hoisting the mid-game
        // AB the way the scan does. That is the same divergence seen from the
        // other side, and the reason this fixture is not in `fixtures`.
        #expect(operations.placements().isEmpty)

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
