//
//  WatchBoardFrameTests.swift
//  KataGo AnytimeTests
//
//  The one frame the watch renders: a position it replayed itself from its
//  own copy of a saved game.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct WatchBoardFrameTests {
    private func frame(title: String? = "Study",
                       width: Int = 19, height: Int = 19,
                       moveIndex: Int = 3, moveCount: Int = 40,
                       winrateBlack: Float? = 0.5, scoreLeadBlack: Float? = 0,
                       bestMove: String? = nil,
                       comment: String? = nil) -> WatchBoardFrame {
        WatchBoardFrame(title: title, boardWidth: width, boardHeight: height,
                        blackStones: [], whiteStones: [], lastMoveVertex: nil,
                        moveIndex: moveIndex, moveCount: moveCount,
                        winrateBlack: winrateBlack, scoreLeadBlack: scoreLeadBlack,
                        bestMove: bestMove, comment: comment)
    }

    @Test func aFrameCarriesTheCachedReviewData() {
        let frame = WatchBoardFrame(title: "Kobayashi",
                                    boardWidth: 13, boardHeight: 13,
                                    blackStones: ["D4"], whiteStones: [],
                                    lastMoveVertex: "D4",
                                    moveIndex: 1, moveCount: 40,
                                    winrateBlack: 0.61, scoreLeadBlack: -2.5,
                                    bestMove: "K10", comment: "Solid opening.")
        #expect(frame.title == "Kobayashi")
        #expect(frame.boardWidth == 13)
        #expect(frame.blackStones == ["D4"])
        #expect(frame.lastMoveVertex == "D4")
        #expect(frame.moveIndex == 1)
        #expect(frame.moveCount == 40)
        #expect(frame.winrateBlack == 0.61)
        #expect(frame.scoreLeadBlack == -2.5)
        #expect(frame.bestMove == "K10")
        #expect(frame.comment == "Solid opening.")
    }

    @Test func aFrameOmitsNumbersTheRecordNeverCached() {
        // Hidden, never zeroed — the watch must not invent a number.
        let frame = frame(winrateBlack: nil, scoreLeadBlack: nil)
        #expect(frame.winrateBlack == nil)
        #expect(frame.scoreLeadBlack == nil)
    }

    @Test func bestMoveMarkIsNoneWhenTheToggleIsOff() {
        #expect(frame(bestMove: "K10").bestMoveMark(showBestMove: false) == .none)
        #expect(frame(bestMove: "K10").bestMoveVertex(showBestMove: false) == nil)
    }

    /// Analysis coverage is whatever the phone happened to look at, so most
    /// indices cache nothing.
    @Test func bestMoveMarkIsNoneWhenTheRecordCachedNothing() {
        #expect(frame(bestMove: nil).bestMoveMark(showBestMove: true) == .none)
    }

    @Test func bestMoveMarkIsDrawableForARealVertex() {
        let f = frame(bestMove: "K10")
        #expect(f.bestMoveMark(showBestMove: true) == .drawable("K10"))
        #expect(f.bestMoveVertex(showBestMove: true) == "K10")
    }

    /// The case the Review page has to spell out in words. `Coordinate.move`
    /// really does return the literal "pass", and near the end of a scored
    /// game passing IS the engine's best move — so a well-reviewed record has
    /// cached passes at exactly the indices a user scrubs to last. The board
    /// cannot draw one, so it must not be reported as drawable.
    @Test func bestMoveMarkIsUnrenderableForAPass() {
        let f = frame(bestMove: "pass")
        #expect(f.bestMoveMark(showBestMove: true) == .unrenderable("pass"))
        #expect(f.bestMoveVertex(showBestMove: true) == nil)
    }

    /// Anything the board's own parser rejects is unrenderable, not silently
    /// dropped: 'I' is skipped in GTP columns, and a vertex can outrun a
    /// smaller board if a record was ever written against a different size.
    @Test(arguments: ["I5", "T19", "", "Z99", "AA1"])
    func bestMoveMarkIsUnrenderableForAnythingTheBoardCannotParse(vertex: String) {
        // 9x9: the rightmost column is 'J' and the top row is 9.
        let f = frame(width: 9, height: 9, bestMove: vertex)
        #expect(f.bestMoveMark(showBestMove: true) == .unrenderable(vertex))
        #expect(f.bestMoveVertex(showBestMove: true) == nil)
    }

    @Test func scoreTextReadsFromWhicheverSideLeads() {
        #expect(WatchBoardFrame.scoreText(3.5) == "B+3.5")
        #expect(WatchBoardFrame.scoreText(-3.5) == "W+3.5")
        #expect(WatchBoardFrame.scoreText(0) == "B+0.0")
    }

    /// Every input here is exactly representable in Float, so the rounding
    /// boundaries are deterministic rather than dependent on binary
    /// approximation of the literal.
    @Test func winratePercentRoundsHalvesAwayFromZero() {
        #expect(WatchBoardFrame.winratePercentText(0) == "0%")
        #expect(WatchBoardFrame.winratePercentText(0.375) == "38%")
        #expect(WatchBoardFrame.winratePercentText(0.5) == "50%")
        #expect(WatchBoardFrame.winratePercentText(0.625) == "63%")
        #expect(WatchBoardFrame.winratePercentText(1) == "100%")
    }

    /// A win rate a hair under 1 must read 100%, not 99% — the watch reports
    /// what the record cached, and truncation would understate a won game.
    @Test func winratePercentRoundsRatherThanTruncates() {
        #expect(WatchBoardFrame.winratePercentText(0.999) == "100%")
    }
}
