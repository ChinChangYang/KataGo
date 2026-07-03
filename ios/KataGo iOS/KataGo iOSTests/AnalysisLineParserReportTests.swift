//
//  AnalysisLineParserReportTests.swift
//  KataGo AnytimeTests
//
//  Parser extensions for the Deep Analysis Report: raw ownership floats,
//  rootInfo winrate/scoreLead, and the movesOwnership no-collision pin.
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct AnalysisLineParserReportTests {
    // 2x2 board fixtures. Ownership order: y from height-1 down, x 0..<width.
    private let base = "info move A1 visits 10 winrate 0.55 scoreLead 2.5 utilityLcb 0.3 order 0 pv A1"

    @Test func rawOwnershipIsUndigitized() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        let msg = base + " ownership 0.13 -0.87 0.42 -0.11 ownershipStdev 0.0 0.0 0.0 0.0"
        let r = parser.parse(message: msg)
        #expect(r.rawOwnership.count == 4)
        #expect(abs(r.rawOwnership[0] - 0.13) < 1e-4)   // NOT rounded to 1/5 steps
        #expect(abs(r.rawOwnership[1] - (-0.87)) < 1e-4)
        // Digitized units still produced unchanged alongside.
        #expect(r.ownershipUnits.count == 4)
    }

    @Test func rawOwnershipEmptyWhenAbsent() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        let r = parser.parse(message: base)
        #expect(r.rawOwnership.isEmpty)
    }

    @Test func rawOwnershipNotFlippedForBlack() {
        // Perspective contract: rawOwnership stays as-emitted even when Black moves.
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .black)
        let msg = base + " ownership 0.13 -0.87 0.42 -0.11 ownershipStdev 0.0 0.0 0.0 0.0"
        let r = parser.parse(message: msg)
        #expect(abs(r.rawOwnership[0] - 0.13) < 1e-4)
    }

    @Test func rootInfoParsedWhitePerspective() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        let msg = base + " rootInfo visits 512 utility 0.2 winrate 0.61 scoreMean 3.1 scoreStdev 10.0 scoreLead 3.1 scoreSelfplay 3.4 weight 500.0"
        let r = parser.parse(message: msg)
        #expect(r.rootInfo?.visits == 512)
        #expect(abs((r.rootInfo?.winrate ?? 0) - 0.61) < 1e-4)
        #expect(abs((r.rootInfo?.scoreLead ?? 0) - 3.1) < 1e-4)
    }

    @Test func rootInfoFlippedForBlack() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .black)
        let msg = base + " rootInfo visits 512 utility 0.2 winrate 0.61 scoreMean 3.1 scoreStdev 10.0 scoreLead 3.1 scoreSelfplay 3.4 weight 500.0"
        let r = parser.parse(message: msg)
        #expect(abs((r.rootInfo?.winrate ?? 0) - 0.39) < 1e-4)   // 1 - 0.61
        #expect(abs((r.rootInfo?.scoreLead ?? 0) - (-3.1)) < 1e-4)
    }

    @Test func rootInfoNilWhenAbsent() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        #expect(parser.parse(message: base).rootInfo == nil)
    }

    @Test func movesOwnershipDoesNotCorruptRootOwnership() {
        // PIN: 'movesOwnership' (capital O) must not satisfy the case-sensitive
        // /ownership / regex. The root grid must win, undigitized values intact.
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        let msg = base + " movesOwnership 0.9 0.9 0.9 0.9"
                       + " rootInfo visits 512 utility 0.2 winrate 0.61 scoreMean 3.1 scoreStdev 10.0 scoreLead 3.1 scoreSelfplay 3.4 weight 500.0"
                       + " ownership 0.13 -0.87 0.42 -0.11 ownershipStdev 0.0 0.0 0.0 0.0"
        let r = parser.parse(message: msg)
        #expect(abs(r.rawOwnership[0] - 0.13) < 1e-4)   // root grid, not 0.9
        #expect(r.ownershipUnits.count == 4)
    }
}
