//
//  WatchBoardFrameTests.swift
//  KataGo AnytimeTests
//
//  The one frame both watch worlds render: the iPhone mirror and the watch's
//  own replay of a saved game.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct WatchBoardFrameTests {
    private func snapshot() -> WatchSnapshot {
        var s = WatchSnapshot(boardWidth: 19, boardHeight: 19,
                              blackStones: ["Q16"], whiteStones: ["D4"],
                              toMove: "B", moveNumber: 2,
                              analysisRunning: true,
                              rootWinrateBlack: 0.55, rootScoreLeadBlack: 1.5,
                              candidates: [
                                .init(vertex: "Q4", winrate: 0.56, scoreLead: 1.8,
                                      visits: 100, pv: ["Q4", "D16"]),
                                .init(vertex: "D16", winrate: 0.54, scoreLead: 1.2,
                                      visits: 80, pv: ["D16"]),
                                .init(vertex: "K10", winrate: 0.53, scoreLead: 1.0,
                                      visits: 60, pv: ["K10"]),
                                .init(vertex: "C3", winrate: 0.52, scoreLead: 0.9,
                                      visits: 40, pv: ["C3"]),
                              ],
                              hostTimestamp: Date(timeIntervalSince1970: 1_780_000_000))
        s.hostMoveIndex = 2
        s.hostMoveCount = 7
        return s
    }

    @Test func liveFrameCarriesTheSnapshot() {
        let frame = WatchBoardFrame.live(snapshot: snapshot(), stale: false,
                                         showCandidates: true,
                                         lastMoveVertex: "D4", title: "Game 1")
        #expect(frame.source == .live(stale: false))
        #expect(frame.title == "Game 1")
        #expect(frame.boardWidth == 19)
        #expect(frame.blackStones == ["Q16"])
        #expect(frame.whiteStones == ["D4"])
        #expect(frame.lastMoveVertex == "D4")
        #expect(frame.moveIndex == 2)
        #expect(frame.moveCount == 7)
        #expect(frame.winrateBlack == 0.55)
        #expect(frame.scoreLeadBlack == 1.5)
        #expect(frame.bestMove == nil)
        #expect(frame.comment == nil)
    }

    @Test func liveFrameCapsCandidateDotsAtThree() {
        let frame = WatchBoardFrame.live(snapshot: snapshot(), stale: false,
                                         showCandidates: true,
                                         lastMoveVertex: nil, title: nil)
        // The board draws at most three dots; the moves page keeps the list.
        #expect(frame.candidateVertices == ["Q4", "D16", "K10"])
        #expect(frame.candidates.count == 4)
    }

    @Test func liveFrameHidesCandidatesWhenAsked() {
        let frame = WatchBoardFrame.live(snapshot: snapshot(), stale: true,
                                         showCandidates: false,
                                         lastMoveVertex: nil, title: nil)
        #expect(frame.candidateVertices.isEmpty)
        #expect(frame.source == .live(stale: true))
    }

    @Test func storedFrameCarriesCachedReviewData() {
        let frame = WatchBoardFrame.stored(title: "Kobayashi",
                                           boardWidth: 13, boardHeight: 13,
                                           blackStones: ["D4"], whiteStones: [],
                                           lastMoveVertex: "D4",
                                           moveIndex: 1, moveCount: 40,
                                           winrateBlack: 0.61, scoreLeadBlack: -2.5,
                                           bestMove: "K10", comment: "Solid opening.")
        #expect(frame.source == .stored)
        #expect(frame.title == "Kobayashi")
        #expect(frame.boardWidth == 13)
        #expect(frame.moveIndex == 1)
        #expect(frame.moveCount == 40)
        #expect(frame.winrateBlack == 0.61)
        #expect(frame.scoreLeadBlack == -2.5)
        #expect(frame.bestMove == "K10")
        #expect(frame.comment == "Solid opening.")
        // Nothing analyzes on the watch, so there is never a candidate list.
        #expect(frame.candidates.isEmpty)
        #expect(frame.candidateVertices.isEmpty)
    }

    @Test func storedFrameOmitsNumbersTheRecordNeverCached() {
        let frame = WatchBoardFrame.stored(title: "Study", boardWidth: 9, boardHeight: 9,
                                           blackStones: [], whiteStones: [],
                                           lastMoveVertex: nil,
                                           moveIndex: 0, moveCount: 0,
                                           winrateBlack: nil, scoreLeadBlack: nil,
                                           bestMove: nil, comment: nil)
        // Hidden, never zeroed — the watch must not invent a number.
        #expect(frame.winrateBlack == nil)
        #expect(frame.scoreLeadBlack == nil)
    }

    @Test func scoreTextReadsFromWhicheverSideLeads() {
        #expect(WatchBoardFrame.scoreText(3.5) == "B+3.5")
        #expect(WatchBoardFrame.scoreText(-3.5) == "W+3.5")
        #expect(WatchBoardFrame.scoreText(0) == "B+0.0")
    }
}
