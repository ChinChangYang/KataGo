//
//  AnalysisCandidateMovesTests.swift
//  KataGo iOSTests
//
//  Pins Analysis.candidateMoves — the ordered top-N feed for the tvOS
//  best-moves list: visits-descending order (the search's own ranking),
//  deterministic tie-breaks (Dictionary iteration order must never leak into
//  the UI), GTP vertex conversion including pass, and the limit cap. Values
//  stay in the side-to-move perspective `info` uses, so a row shows the same
//  numbers as the board overlay.
//

import Testing
@testable import KataGoUICore

@MainActor
struct AnalysisCandidateMovesTests {

    private func makeInfo(visits: Int, winrate: Float = 0.5,
                          scoreLead: Float = 0, utilityLcb: Float = 0) -> AnalysisInfo {
        AnalysisInfo(visits: visits, winrate: winrate,
                     scoreLead: scoreLead, utilityLcb: utilityLcb)
    }

    @Test("Candidates come out visits-descending with GTP vertex labels")
    func ordersByVisits() {
        let analysis = Analysis()
        analysis.info = [
            BoardPoint(x: 3, y: 3): makeInfo(visits: 50, winrate: 0.48, scoreLead: -1.5),
            BoardPoint(x: 15, y: 15): makeInfo(visits: 100, winrate: 0.55, scoreLead: 2.0),
            BoardPoint(x: 2, y: 16): makeInfo(visits: 10, winrate: 0.40, scoreLead: -3.0),
        ]

        let candidates = analysis.candidateMoves(width: 19, height: 19)

        #expect(candidates.map(\.vertex) == ["Q16", "D4", "C17"])
        #expect(candidates.map(\.visits) == [100, 50, 10])
        #expect(candidates.first?.winrate == 0.55)
        #expect(candidates.first?.scoreLead == 2.0)
    }

    @Test("Equal visits tie-break on utilityLcb, then vertex — deterministic")
    func tieBreaksDeterministically() {
        let analysis = Analysis()
        analysis.info = [
            BoardPoint(x: 3, y: 3): makeInfo(visits: 100, utilityLcb: 0.1),
            BoardPoint(x: 15, y: 15): makeInfo(visits: 100, utilityLcb: 0.3),
            // Same visits and utility as D4: falls back to the vertex ordering.
            BoardPoint(x: 15, y: 3): makeInfo(visits: 100, utilityLcb: 0.1),
        ]

        let candidates = analysis.candidateMoves(width: 19, height: 19)

        #expect(candidates.map(\.vertex) == ["Q16", "D4", "Q4"])
    }

    @Test("A pass candidate converts to the playable \"pass\" vertex")
    func passConverts() {
        let analysis = Analysis()
        analysis.info = [
            BoardPoint.pass(width: 19, height: 19): makeInfo(visits: 30),
            BoardPoint(x: 15, y: 15): makeInfo(visits: 100),
        ]

        let candidates = analysis.candidateMoves(width: 19, height: 19)

        #expect(candidates.map(\.vertex) == ["Q16", "pass"])
    }

    @Test("The limit caps the list")
    func limitCaps() {
        let analysis = Analysis()
        for x in 0..<8 {
            analysis.info[BoardPoint(x: x, y: 9)] = makeInfo(visits: 100 - x)
        }

        #expect(analysis.candidateMoves(width: 19, height: 19, limit: 4).count == 4)
        #expect(analysis.candidateMoves(width: 19, height: 19).count == 5)
    }

    @Test("No analysis data yields an empty list")
    func emptyInfo() {
        #expect(Analysis().candidateMoves(width: 19, height: 19).isEmpty)
    }
}
