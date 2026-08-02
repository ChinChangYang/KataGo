//
//  WatchStoredAnalysisTests.swift
//  KataGo AnytimeTests
//
//  Offline, the watch shows only the review data the phone already cached at
//  that exact index — hidden, never zeroed, where it cached nothing.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct WatchStoredAnalysisTests {
    @Test func readsEveryFieldAtTheIndex() {
        let analysis = WatchStoredAnalysis.at(index: 3,
                                              winRates: [3: 0.62],
                                              scoreLeads: [3: 2.5],
                                              bestMoves: [3: "Q16"],
                                              comments: [3: "Territory-first."])
        #expect(analysis.winrateBlack == 0.62)
        #expect(analysis.scoreLeadBlack == 2.5)
        #expect(analysis.bestMove == "Q16")
        #expect(analysis.comment == "Territory-first.")
    }

    @Test func anUnanalyzedIndexYieldsNothing() {
        let analysis = WatchStoredAnalysis.at(index: 9,
                                              winRates: [3: 0.62],
                                              scoreLeads: [3: 2.5],
                                              bestMoves: [3: "Q16"],
                                              comments: [3: "Territory-first."])
        #expect(analysis == WatchStoredAnalysis(winrateBlack: nil, scoreLeadBlack: nil,
                                                bestMove: nil, comment: nil))
    }

    @Test func nilDictionariesYieldNothing() {
        let analysis = WatchStoredAnalysis.at(index: 0, winRates: nil, scoreLeads: nil,
                                              bestMoves: nil, comments: nil)
        #expect(analysis.winrateBlack == nil)
        #expect(analysis.scoreLeadBlack == nil)
        #expect(analysis.bestMove == nil)
        #expect(analysis.comment == nil)
    }

    @Test func partialCoverageFillsOnlyWhatExists() {
        // The phone caches these dictionaries independently; a comment can
        // exist at an index with no win rate.
        let analysis = WatchStoredAnalysis.at(index: 5, winRates: nil, scoreLeads: nil,
                                              bestMoves: nil, comments: [5: "Ko fight."])
        #expect(analysis.comment == "Ko fight.")
        #expect(analysis.winrateBlack == nil)
    }

    @Test func anEmptyCommentIsTreatedAsAbsent() {
        let analysis = WatchStoredAnalysis.at(index: 1, winRates: nil, scoreLeads: nil,
                                              bestMoves: nil, comments: [1: "   "])
        #expect(analysis.comment == nil)
    }
}
