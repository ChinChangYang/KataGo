//
//  LastMoveKeyTests.swift
//  KataGo AnytimeTests
//
//  The shared ghost-anchor derivation key (extracted from VisionRootView so
//  the tvOS screens reuse it). SGF fixtures use the engine's own coordinate
//  conventions; derive() walks the C++ parser, available in this test host.
//

import Testing
@testable import KataGoUICore

struct LastMoveKeyTests {
    // A 9x9 game: B E5, W C3. SZ first, then the moves.
    private let sgf = "(;FF[4]GM[1]SZ[9];B[ee];W[cg])"

    @Test("lastPoint is the last played move at the given index")
    func lastPointFollowsIndex() {
        let atTip = LastMoveKey(sgf: sgf, index: 2)
        #expect(atTip.lastPoint != nil)
        let afterFirst = LastMoveKey(sgf: sgf, index: 1)
        #expect(afterFirst.lastPoint != nil)
        #expect(atTip.lastPoint != afterFirst.lastPoint)
    }

    @Test("An empty board has no last point")
    func emptyBoardHasNoPoint() {
        #expect(LastMoveKey(sgf: sgf, index: 0).lastPoint == nil)
    }

    @Test("A trailing pass has no last point")
    func passHasNoPoint() {
        let withPass = "(;FF[4]GM[1]SZ[9];B[ee];W[])"
        #expect(LastMoveKey(sgf: withPass, index: 2).lastPoint == nil)
    }

    @Test("Equality is by sgf + index (the onChange trigger contract)")
    func equalitySemantics() {
        #expect(LastMoveKey(sgf: sgf, index: 1) == LastMoveKey(sgf: sgf, index: 1))
        #expect(LastMoveKey(sgf: sgf, index: 1) != LastMoveKey(sgf: sgf, index: 2))
        #expect(LastMoveKey(sgf: sgf, index: 1) != LastMoveKey(sgf: sgf + " ", index: 1))
    }
}
