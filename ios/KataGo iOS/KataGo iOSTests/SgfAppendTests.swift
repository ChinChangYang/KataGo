//
//  SgfAppendTests.swift
//  KataGo AnytimeTests
//
//  `SgfAppend` writes a played move into the record in Swift, in place of the
//  engine's `printsgf` rewrite. Every case is judged by the app's own parser:
//  after appending, `SgfOperations` must read `n + 1` moves, the first `n`
//  unchanged, and the new one where the GTP vertex says — so a divergence
//  between the writer and the reader shows up here rather than as a stone
//  landing on the wrong point once the engine is gone. On a forked record the
//  oracle's own `getMove(at:)` says which line the app shows (its parser takes
//  the deepest child, the first on a tie), and the append must land on it.
//

import Testing
import Foundation
@testable import KataGoUICore

struct SgfAppendTests {
    // MARK: - Oracle

    private enum Expected {
        case point(x: Int, y: Int)
        case pass
    }

    /// The oracle's move list; nil when the C++ parser refuses the text.
    private static func moves(of sgf: String) -> [Move]? {
        let operations = SgfOperations(sgf: sgf)
        guard let size = operations.moveSize else { return nil }
        return (0..<size).compactMap { operations.getMove(at: $0) }
    }

    private static func same(_ a: Move, _ b: Move) -> Bool {
        a.player == b.player
            && a.location.pass == b.location.pass
            && a.location.x == b.location.x
            && a.location.y == b.location.y
    }

    private static func isMove(_ move: Move?, _ player: Player, x: Int, y: Int) -> Bool {
        guard let move else { return false }
        return move.player == player && !move.location.pass && move.location.x == x && move.location.y == y
    }

    /// Parens outside property values: `(` minus `)`. Zero means closed.
    private static func parenBalance(_ sgf: String) -> Int {
        var depth = 0
        var inValue = false
        var escaped = false
        for character in sgf {
            if inValue {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "]" {
                    inValue = false
                }
            } else if character == "[" {
                inValue = true
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
            }
        }
        return depth
    }

    /// The oracle's reading of the appended record: one move more than the
    /// kept prefix (`n`, or the whole input when `n` overshoots), every kept
    /// move unchanged, the new one as expected, and the tree closed.
    private static func expectAppended(_ output: String?,
                                       to input: String,
                                       afterMoveCount n: Int,
                                       player: Player,
                                       at expected: Expected,
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        guard let output else {
            Issue.record("appending returned nil", sourceLocation: sourceLocation)
            return
        }
        guard let before = moves(of: input) else {
            Issue.record("the oracle cannot read the input", sourceLocation: sourceLocation)
            return
        }
        guard let after = moves(of: output) else {
            Issue.record("the oracle cannot read the output: \(output)", sourceLocation: sourceLocation)
            return
        }
        let kept = min(n, before.count)
        #expect(after.count == kept + 1, "\(output)", sourceLocation: sourceLocation)
        for index in 0..<min(kept, after.count) {
            #expect(same(before[index], after[index]), "move \(index) changed", sourceLocation: sourceLocation)
        }
        #expect(parenBalance(output) == 0, "\(output)", sourceLocation: sourceLocation)
        guard let last = after.last else { return }
        #expect(last.player == player, sourceLocation: sourceLocation)
        switch expected {
        case .pass:
            #expect(last.location.pass, sourceLocation: sourceLocation)
        case .point(let x, let y):
            #expect(!last.location.pass, sourceLocation: sourceLocation)
            #expect(last.location.x == x && last.location.y == y,
                    "got (\(last.location.x), \(last.location.y))",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: - Linear records

    @Test func appendsAtTheTipOfALinearRecord() {
        let sgf = "(;FF[4]GM[1]SZ[19]KM[7.5];B[pd];W[dp])"
        // D16: column D is x 3; row 16 from the bottom is SGF row 19 - 16 = 3.
        let black = SgfAppend.appending(color: "b", vertex: "D16", afterMoveCount: 2, to: sgf, width: 19, height: 19)
        #expect(black == "(;FF[4]GM[1]SZ[19]KM[7.5];B[pd];W[dp];B[dd])")
        Self.expectAppended(black, to: sgf, afterMoveCount: 2, player: .black, at: .point(x: 3, y: 3))

        let oneMove = "(;FF[4]GM[1]SZ[19];B[pd])"
        let white = SgfAppend.appending(color: "W", vertex: "Q4", afterMoveCount: 1, to: oneMove, width: 19, height: 19)
        #expect(white == "(;FF[4]GM[1]SZ[19];B[pd];W[pp])")
        Self.expectAppended(white, to: oneMove, afterMoveCount: 1, player: .white, at: .point(x: 15, y: 15))
    }

    @Test func appendingMidLineDropsTheRest() {
        let sgf = "(;FF[4]GM[1]SZ[19];B[pd];W[dp];B[pp])"
        let out = SgfAppend.appending(color: "w", vertex: "Q3", afterMoveCount: 1, to: sgf, width: 19, height: 19)
        #expect(out == "(;FF[4]GM[1]SZ[19];B[pd];W[pq])")
        Self.expectAppended(out, to: sgf, afterMoveCount: 1, player: .white, at: .point(x: 15, y: 16))
    }

    @Test func passAppendsAsAnEmptyValue() {
        let sgf = "(;FF[4]GM[1]SZ[19];B[pd];W[dp])"
        let out = SgfAppend.appending(color: "b", vertex: "pass", afterMoveCount: 2, to: sgf, width: 19, height: 19)
        #expect(out == "(;FF[4]GM[1]SZ[19];B[pd];W[dp];B[])")
        Self.expectAppended(out, to: sgf, afterMoveCount: 2, player: .black, at: .pass)
    }

    @Test func commentBracketsDoNotShiftTheCut() {
        // A ';', a '(', a ')' and an escaped ']' inside a comment: none of
        // them is structure, so the cut still lands on the second move node.
        let comment = "C[Good shape; see (;W[gg\\]) and \\] too.]"
        let sgf = "(;FF[4]GM[1]SZ[9];B[cc]" + comment + ";W[gg];B[dd])"
        let out = SgfAppend.appending(color: "w", vertex: "E5", afterMoveCount: 1, to: sgf, width: 9, height: 9)
        #expect(out == "(;FF[4]GM[1]SZ[9];B[cc]" + comment + ";W[ee])")
        #expect(out?.contains(comment) == true)
        Self.expectAppended(out, to: sgf, afterMoveCount: 1, player: .white, at: .point(x: 4, y: 4))
        // The escapes survive verbatim: the oracle still reads the comment.
        #expect(SgfOperations(sgf: out ?? "").getComment(at: 1) == "Good shape; see (;W[gg]) and ] too.")
    }

    @Test func whitespaceBetweenNodesIsPreserved() {
        let sgf = "(;FF[4]GM[1]SZ[9]\n;B[cc]\n;W[gg]\n\n)\n"
        let tip = SgfAppend.appending(color: "b", vertex: "D6", afterMoveCount: 2, to: sgf, width: 9, height: 9)
        #expect(tip == "(;FF[4]GM[1]SZ[9]\n;B[cc]\n;W[gg]\n\n;B[dd])")
        Self.expectAppended(tip, to: sgf, afterMoveCount: 2, player: .black, at: .point(x: 3, y: 3))

        let mid = SgfAppend.appending(color: "w", vertex: "D6", afterMoveCount: 1, to: sgf, width: 9, height: 9)
        #expect(mid == "(;FF[4]GM[1]SZ[9]\n;B[cc]\n;W[dd])")
        Self.expectAppended(mid, to: sgf, afterMoveCount: 1, player: .white, at: .point(x: 3, y: 3))
    }

    @Test func rootOnlyRecordGetsItsFirstMove() {
        let sgf = "(;GM[1]FF[4]SZ[9])"
        let out = SgfAppend.appending(color: "B", vertex: "E5", afterMoveCount: 0, to: sgf, width: 9, height: 9)
        #expect(out == "(;GM[1]FF[4]SZ[9];B[ee])")
        Self.expectAppended(out, to: sgf, afterMoveCount: 0, player: .black, at: .point(x: 4, y: 4))
    }

    @Test func countPastTheEndAppendsAtTheTip() {
        let sgf = "(;FF[4]GM[1]SZ[19];B[pd];W[dp])"
        let out = SgfAppend.appending(color: "b", vertex: "D16", afterMoveCount: 10, to: sgf, width: 19, height: 19)
        #expect(out == "(;FF[4]GM[1]SZ[19];B[pd];W[dp];B[dd])")
        Self.expectAppended(out, to: sgf, afterMoveCount: 10, player: .black, at: .point(x: 3, y: 3))
    }

    // MARK: - Variations: the first child is the deepest

    static let forked = "(;GM[1]SZ[19];B[pd](;W[dp];B[pp])(;W[pq]))"

    @Test func variationsBeyondTheCutAreDropped() {
        // Main line: B[pd] W[dp] B[pp]. Cutting after two moves drops B[pp]
        // and the sibling (;W[pq]); the new move follows W[dp] inside the
        // kept variation, which is then closed.
        let out = SgfAppend.appending(color: "b", vertex: "D16", afterMoveCount: 2, to: Self.forked, width: 19, height: 19)
        #expect(out == "(;GM[1]SZ[19];B[pd](;W[dp];B[dd]))")
        Self.expectAppended(out, to: Self.forked, afterMoveCount: 2, player: .black, at: .point(x: 3, y: 3))
    }

    @Test func cuttingAtAVariationsFirstNodeRemovesTheVariation() {
        // The second move node opens the first child, so the cut moves back
        // to its "(" and no empty variation is left behind.
        let out = SgfAppend.appending(color: "w", vertex: "Q3", afterMoveCount: 1, to: Self.forked, width: 19, height: 19)
        #expect(out == "(;GM[1]SZ[19];B[pd];W[pq])")
        Self.expectAppended(out, to: Self.forked, afterMoveCount: 1, player: .white, at: .point(x: 15, y: 16))
    }

    @Test func overshootOnAForkedRecordAppendsAtTheMainLinesTip() {
        let out = SgfAppend.appending(color: "w", vertex: "Q3", afterMoveCount: 10, to: Self.forked, width: 19, height: 19)
        #expect(out == "(;GM[1]SZ[19];B[pd](;W[dp];B[pp];W[pq]))")
        Self.expectAppended(out, to: Self.forked, afterMoveCount: 10, player: .white, at: .point(x: 15, y: 16))
    }

    @Test func nestedForksWithWhitespaceCloseEveryOpenVariation() {
        let sgf = "(;GM[1]SZ[9];B[cc]\n(;W[gg]\n  (;B[dd];W[ee])\n  (;B[ee]))\n(;W[ee]))"
        // The third move node B[dd] is the first node of a nested variation:
        // the cut goes to its "(", and both variations still open are closed.
        let out = SgfAppend.appending(color: "b", vertex: "E5", afterMoveCount: 2, to: sgf, width: 9, height: 9)
        #expect(out == "(;GM[1]SZ[9];B[cc]\n(;W[gg]\n  ;B[ee]))")
        Self.expectAppended(out, to: sgf, afterMoveCount: 2, player: .black, at: .point(x: 4, y: 4))
    }

    // MARK: - Variations: the app's main line is the deepest child

    /// The first variation is one node deep, the second three: the app's
    /// parser shows B[pd] W[pq] B[dd] W[cc], never W[dp].
    static let deeperLater = "(;GM[1]SZ[19];B[pd](;W[dp])(;W[pq];B[dd];W[cc]))"

    @Test func theOracleFollowsTheDeeperLaterVariation() {
        let before = Self.moves(of: Self.deeperLater)
        #expect(before?.count == 4)
        #expect(Self.isMove(before?[1], .white, x: 15, y: 16), "move 1 is W[pq], the deeper second child")
    }

    @Test func appendingFollowsTheDeeperLaterVariation() {
        // n = 2: the cut lands on B[dd] inside the second variation; B[dd],
        // W[cc] and the whole (;W[dp]) variation are gone.
        let two = SgfAppend.appending(color: "b", vertex: "E15", afterMoveCount: 2, to: Self.deeperLater, width: 19, height: 19)
        #expect(two == "(;GM[1]SZ[19];B[pd](;W[pq];B[ee]))")
        Self.expectAppended(two, to: Self.deeperLater, afterMoveCount: 2, player: .black, at: .point(x: 4, y: 4))

        // n = 3: the new move follows B[dd]; only W[cc] and (;W[dp]) go.
        let three = SgfAppend.appending(color: "w", vertex: "E15", afterMoveCount: 3, to: Self.deeperLater, width: 19, height: 19)
        #expect(three == "(;GM[1]SZ[19];B[pd](;W[pq];B[dd];W[ee]))")
        Self.expectAppended(three, to: Self.deeperLater, afterMoveCount: 3, player: .white, at: .point(x: 4, y: 4))

        // n = 1: the cut is at the chosen variation's first node, so both
        // variations are dropped and the new move follows B[pd] directly.
        let one = SgfAppend.appending(color: "w", vertex: "E15", afterMoveCount: 1, to: Self.deeperLater, width: 19, height: 19)
        #expect(one == "(;GM[1]SZ[19];B[pd];W[ee])")
        Self.expectAppended(one, to: Self.deeperLater, afterMoveCount: 1, player: .white, at: .point(x: 4, y: 4))

        // Overshoot: the tip of the deeper line, the shallow sibling gone.
        let tip = SgfAppend.appending(color: "b", vertex: "E15", afterMoveCount: 10, to: Self.deeperLater, width: 19, height: 19)
        #expect(tip == "(;GM[1]SZ[19];B[pd](;W[pq];B[dd];W[cc];B[ee]))")
        Self.expectAppended(tip, to: Self.deeperLater, afterMoveCount: 10, player: .black, at: .point(x: 4, y: 4))
    }

    @Test func aTieBetweenVariationsFollowsTheFirst() {
        let sgf = "(;GM[1]SZ[19];B[pd](;W[dp];B[pp])(;W[pq];B[dd]))"
        #expect(Self.isMove(Self.moves(of: sgf)?[1], .white, x: 3, y: 15), "move 1 is W[dp], the first of two equal children")
        let two = SgfAppend.appending(color: "b", vertex: "E15", afterMoveCount: 2, to: sgf, width: 19, height: 19)
        #expect(two == "(;GM[1]SZ[19];B[pd](;W[dp];B[ee]))")
        Self.expectAppended(two, to: sgf, afterMoveCount: 2, player: .black, at: .point(x: 4, y: 4))
        let tip = SgfAppend.appending(color: "w", vertex: "E15", afterMoveCount: 10, to: sgf, width: 19, height: 19)
        #expect(tip == "(;GM[1]SZ[19];B[pd](;W[dp];B[pp];W[ee]))")
        Self.expectAppended(tip, to: sgf, afterMoveCount: 10, player: .white, at: .point(x: 4, y: 4))
    }

    @Test func depthCountsNodesThatAreNotMoves() {
        // Both children hold one move, but the second has a comment node as
        // well, so it is the deeper one and the line the app shows.
        let sgf = "(;GM[1]SZ[9];B[cc](;W[dd])(;W[ee];C[note]))"
        #expect(Self.isMove(Self.moves(of: sgf)?[1], .white, x: 4, y: 4), "move 1 is W[ee], the child with more nodes")
        let two = SgfAppend.appending(color: "b", vertex: "G3", afterMoveCount: 2, to: sgf, width: 9, height: 9)
        #expect(two == "(;GM[1]SZ[9];B[cc](;W[ee];C[note];B[gg]))")
        Self.expectAppended(two, to: sgf, afterMoveCount: 2, player: .black, at: .point(x: 6, y: 6))
        let one = SgfAppend.appending(color: "w", vertex: "G3", afterMoveCount: 1, to: sgf, width: 9, height: 9)
        #expect(one == "(;GM[1]SZ[9];B[cc];W[gg])")
        Self.expectAppended(one, to: sgf, afterMoveCount: 1, player: .white, at: .point(x: 6, y: 6))
    }

    @Test func aLongerEarlierSiblingIsDroppedSoTheParserCannotSwitchLines() {
        // The second child is deeper (4 vs 3), so the app shows it. Cutting
        // it down to two nodes would leave it SHORTER than the first child;
        // had that sibling stayed in the text, the parser would switch to it
        // and the appended move would vanish from the shown line.
        let sgf = "(;GM[1]SZ[19];B[pd](;W[dp];B[aa];W[bb])(;W[pq];B[dd];W[cc];B[ee]))"
        #expect(Self.isMove(Self.moves(of: sgf)?[1], .white, x: 15, y: 16))
        let out = SgfAppend.appending(color: "b", vertex: "F14", afterMoveCount: 2, to: sgf, width: 19, height: 19)
        #expect(out == "(;GM[1]SZ[19];B[pd](;W[pq];B[ff]))")
        Self.expectAppended(out, to: sgf, afterMoveCount: 2, player: .black, at: .point(x: 5, y: 5))
    }

    @Test func theDeeperChildIsChosenAtEveryLevel() {
        // Two forks deep: the second grandchild (three nodes) beats the first
        // (one), so the app shows B[cc] W[dd] B[ff] W[gg] B[hh]. Every
        // variation still open on that path is closed after the new move.
        let sgf = "(;GM[1]SZ[9];B[cc]\n(;W[dd]\n  (;B[ee])\n  (;B[ff];W[gg];B[hh]))\n(;W[ii]))"
        #expect(Self.isMove(Self.moves(of: sgf)?[2], .black, x: 5, y: 5), "move 2 is B[ff], the deeper grandchild")
        let three = SgfAppend.appending(color: "w", vertex: "A1", afterMoveCount: 3, to: sgf, width: 9, height: 9)
        #expect(three == "(;GM[1]SZ[9];B[cc]\n(;W[dd]\n  (;B[ff];W[ai])))")
        Self.expectAppended(three, to: sgf, afterMoveCount: 3, player: .white, at: .point(x: 0, y: 8))
        let two = SgfAppend.appending(color: "b", vertex: "A1", afterMoveCount: 2, to: sgf, width: 9, height: 9)
        #expect(two == "(;GM[1]SZ[9];B[cc]\n(;W[dd]\n  ;B[ai]))")
        Self.expectAppended(two, to: sgf, afterMoveCount: 2, player: .black, at: .point(x: 0, y: 8))
    }

    // MARK: - Nodes that are not moves

    @Test func aCommentNodeIsNotAMove() {
        let sgf = "(;GM[1]SZ[9];B[cc];C[note];W[gg])"
        let tip = SgfAppend.appending(color: "b", vertex: "D6", afterMoveCount: 2, to: sgf, width: 9, height: 9)
        #expect(tip == "(;GM[1]SZ[9];B[cc];C[note];W[gg];B[dd])")
        Self.expectAppended(tip, to: sgf, afterMoveCount: 2, player: .black, at: .point(x: 3, y: 3))

        // The comment node stands before the second move node, so it is kept.
        let mid = SgfAppend.appending(color: "w", vertex: "D6", afterMoveCount: 1, to: sgf, width: 9, height: 9)
        #expect(mid == "(;GM[1]SZ[9];B[cc];C[note];W[dd])")
        Self.expectAppended(mid, to: sgf, afterMoveCount: 1, player: .white, at: .point(x: 3, y: 3))
    }

    @Test func aMidGameSetupNodeIsNotAMove() {
        let sgf = "(;GM[1]SZ[9];B[cc];AB[ee][ff];W[gg])"
        #expect(Self.moves(of: sgf)?.count == 2, "the app's parser reads past a setup node: two moves")

        let tip = SgfAppend.appending(color: "b", vertex: "D6", afterMoveCount: 2, to: sgf, width: 9, height: 9)
        #expect(tip == "(;GM[1]SZ[9];B[cc];AB[ee][ff];W[gg];B[dd])")
        Self.expectAppended(tip, to: sgf, afterMoveCount: 2, player: .black, at: .point(x: 3, y: 3))

        // The setup node precedes the second move node, so it stays.
        let mid = SgfAppend.appending(color: "w", vertex: "D6", afterMoveCount: 1, to: sgf, width: 9, height: 9)
        #expect(mid == "(;GM[1]SZ[9];B[cc];AB[ee][ff];W[dd])")
        Self.expectAppended(mid, to: sgf, afterMoveCount: 1, player: .white, at: .point(x: 3, y: 3))

        let first = SgfAppend.appending(color: "b", vertex: "D6", afterMoveCount: 0, to: sgf, width: 9, height: 9)
        #expect(first == "(;GM[1]SZ[9];B[dd])")
        Self.expectAppended(first, to: sgf, afterMoveCount: 0, player: .black, at: .point(x: 3, y: 3))
    }

    @Test func aMoveInTheRootNodeCountsButCannotBeCutBefore() {
        let sgf = "(;GM[1]SZ[9]B[cc];W[gg])"
        #expect(SgfAppend.appending(color: "b", vertex: "D6", afterMoveCount: 0, to: sgf, width: 9, height: 9) == nil)
        let out = SgfAppend.appending(color: "w", vertex: "D6", afterMoveCount: 1, to: sgf, width: 9, height: 9)
        #expect(out == "(;GM[1]SZ[9]B[cc];W[dd])")
        Self.expectAppended(out, to: sgf, afterMoveCount: 1, player: .white, at: .point(x: 3, y: 3))
    }

    // MARK: - Coordinates

    @Test(arguments: [
        (vertex: "A1", width: 19, height: 19, point: "as"),
        (vertex: "T19", width: 19, height: 19, point: "sa"),
        (vertex: "Q16", width: 19, height: 19, point: "pd"),
        (vertex: "q16", width: 19, height: 19, point: "pd"),
        (vertex: "J1", width: 9, height: 9, point: "ii"),
        // Past Z the column letters double up; past row 26 the SGF letter is
        // uppercase.
        (vertex: "AA1", width: 37, height: 37, point: "zK"),
        (vertex: "AM37", width: 37, height: 37, point: "Ka"),
        // A rectangle: the SGF row counts down from the board's own height.
        (vertex: "A1", width: 9, height: 13, point: "am"),
        (vertex: "pass", width: 19, height: 19, point: ""),
        (vertex: "PASS", width: 9, height: 9, point: ""),
        (vertex: "T19", width: 9, height: 9, point: nil),
        (vertex: "A10", width: 9, height: 9, point: nil),
        (vertex: "A0", width: 9, height: 9, point: nil),
        (vertex: "I5", width: 19, height: 19, point: nil),
        (vertex: "Q", width: 19, height: 19, point: nil),
        (vertex: "16", width: 19, height: 19, point: nil),
        (vertex: "", width: 19, height: 19, point: nil),
    ] as [(vertex: String, width: Int, height: Int, point: String?)])
    func sgfPointMapsGtpVertices(_ c: (vertex: String, width: Int, height: Int, point: String?)) {
        #expect(SgfAppend.sgfPoint(vertex: c.vertex, width: c.width, height: c.height) == c.point)
    }

    @Test func largeAndRectangularBoardsRoundTripThroughTheOracle() {
        let big = "(;GM[1]SZ[37])"
        let corner = SgfAppend.appending(color: "b", vertex: "AM37", afterMoveCount: 0, to: big, width: 37, height: 37)
        #expect(corner == "(;GM[1]SZ[37];B[Ka])")
        Self.expectAppended(corner, to: big, afterMoveCount: 0, player: .black, at: .point(x: 36, y: 0))

        let rectangle = "(;GM[1]SZ[9:13])"
        let bottomLeft = SgfAppend.appending(color: "b", vertex: "A1", afterMoveCount: 0, to: rectangle, width: 9, height: 13)
        #expect(bottomLeft == "(;GM[1]SZ[9:13];B[am])")
        let operations = SgfOperations(sgf: bottomLeft ?? "")
        #expect(operations.xSize == 9 && operations.ySize == 13)
        Self.expectAppended(bottomLeft, to: rectangle, afterMoveCount: 0, player: .black, at: .point(x: 0, y: 12))
    }

    @Test func aVertexOffTheBoardIsRefused() {
        #expect(SgfAppend.appending(color: "b", vertex: "T19", afterMoveCount: 0, to: "(;GM[1]SZ[9])", width: 9, height: 9) == nil)
    }

    // MARK: - Refusals

    @Test(arguments: ["hello", "", "   ", "(B[aa])", ";B[aa])", "(;GM[1]C[unterminated"])
    func invalidTextIsRefused(_ text: String) {
        #expect(SgfAppend.appending(color: "b", vertex: "A1", afterMoveCount: 0, to: text, width: 9, height: 9) == nil)
    }

    @Test func badColorOrNegativeCountIsRefused() {
        let sgf = "(;GM[1]SZ[9])"
        #expect(SgfAppend.appending(color: "x", vertex: "A1", afterMoveCount: 0, to: sgf, width: 9, height: 9) == nil)
        #expect(SgfAppend.appending(color: "b", vertex: "A1", afterMoveCount: -1, to: sgf, width: 9, height: 9) == nil)
    }
}
