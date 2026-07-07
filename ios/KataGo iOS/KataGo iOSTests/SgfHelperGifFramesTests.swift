//
//  SgfHelperGifFramesTests.swift
//  KataGo iOSTests
//

import Testing
@testable import KataGoUICore

/// Per-move frame reconstruction for GIF export. Uses the same capture SGF as
/// `SgfOperationsTests.finalStones_capturedStoneIsRemoved`: on a 9×9 board Black's
/// corner stone A9 is captured once White holds B9 and A8.
struct SgfHelperGifFramesTests {
    private let captureSgf = "(;FF[4]GM[1]SZ[9];B[aa];W[ba];B[gg];W[ab])"

    @Test func gifFrames_hasOneFramePerMovePlusStart() {
        let helper = SgfHelper(sgf: captureSgf)
        #expect(helper.moveSize == 4)
        #expect(helper.gifFrames().count == 5)   // start position + 4 moves
    }

    @Test func gifFrames_startFrameIsEmptyWithNoLastMove() {
        let frames = SgfHelper(sgf: captureSgf).gifFrames()
        #expect(frames[0].blackStones.isEmpty)
        #expect(frames[0].whiteStones.isEmpty)
        #expect(frames[0].lastMove == nil)
    }

    @Test func gifFrames_buildUpTracksEachMove() {
        let frames = SgfHelper(sgf: captureSgf).gifFrames()
        // After B[aa]: lone black corner stone, highlighted.
        #expect(frames[1].blackStones == ["A9"])
        #expect(frames[1].whiteStones.isEmpty)
        #expect(frames[1].lastMove == "A9")
        // After W[ba]: black corner still alive (its A8 liberty is open).
        #expect(frames[2].blackStones == ["A9"])
        #expect(frames[2].whiteStones == ["B9"])
        // After B[gg]: the far stone joins the board.
        #expect(frames[3].blackStones.sorted() == ["A9", "G3"])
        #expect(frames[3].whiteStones == ["B9"])
    }

    @Test func gifFrames_captureRemovesStoneInFinalFrame() {
        let frames = SgfHelper(sgf: captureSgf).gifFrames()
        let last = frames[frames.count - 1]
        // W[ab] fills A9's last liberty → the corner stone is captured.
        #expect(last.blackStones == ["G3"])
        #expect(!last.blackStones.contains("A9"))
        #expect(last.whiteStones.sorted() == ["A8", "B9"])
        #expect(last.lastMove == "A8")
    }

    @Test func gifFrames_finalFrameMatchesFinalPosition() {
        let helper = SgfHelper(sgf: captureSgf)
        let last = helper.gifFrames().last!
        let final = helper.finalPosition()
        #expect(last.blackStones.sorted() == final.blackStones.sorted())
        #expect(last.whiteStones.sorted() == final.whiteStones.sorted())
    }

    @Test func gifFrames_invalidSgf_returnsEmpty() {
        #expect(SgfHelper(sgf: "not a real sgf").gifFrames().isEmpty)
    }

    @Test func gifFrames_handicapStonesShowFromStart() {
        // AB setup stones with no played moves: one start frame holding them.
        let frames = SgfHelper(sgf: "(;FF[4]GM[1]SZ[19]AB[pd][dp])").gifFrames()
        #expect(frames.count == 1)
        #expect(frames[0].blackStones.sorted() == ["D4", "Q16"])
        #expect(frames[0].lastMove == nil)
    }
}
