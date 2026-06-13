//
//  AnalysisLineParserTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime

struct AnalysisLineParserTests {
    // Q16 on a 19x19 board: x = Q = 15, y = 16 -> BoardPoint(x: 15, y: 15).
    private let q16 = BoardPoint(x: 15, y: 15)
    // D4: x = D = 3, y = 4 -> BoardPoint(x: 3, y: 3).
    private let d4 = BoardPoint(x: 3, y: 3)

    @Test func whiteKeepsSignsAndParsesFields() {
        let parser = AnalysisLineParser(boardWidth: 19, boardHeight: 19, nextColor: .white)
        let msg = "info move Q16 visits 10 winrate 0.55 scoreLead 2.5 utilityLcb 0.3 order 0 pv Q16"
        let r = parser.parse(message: msg)
        let info = r.info[q16]
        #expect(info?.visits == 10)
        #expect(abs((info?.winrate ?? 0) - 0.55) < 1e-4)
        #expect(abs((info?.scoreLead ?? 0) - 2.5) < 1e-4)
        #expect(abs((info?.utilityLcb ?? 0) - 0.3) < 1e-4)
    }

    @Test func blackFlipsSigns() {
        let parser = AnalysisLineParser(boardWidth: 19, boardHeight: 19, nextColor: .black)
        let msg = "info move Q16 visits 10 winrate 0.55 scoreLead 2.5 utilityLcb 0.3 order 0 pv Q16"
        let info = parser.parse(message: msg).info[q16]
        #expect(abs((info?.winrate ?? 0) - 0.45) < 1e-4)   // 1 - 0.55
        #expect(abs((info?.scoreLead ?? 0) - (-2.5)) < 1e-4)
        #expect(abs((info?.utilityLcb ?? 0) - (-0.3)) < 1e-4)
    }

    @Test func dropsZeroVisitHalfWinrateButKeepsOtherZeroVisit() {
        let parser = AnalysisLineParser(boardWidth: 19, boardHeight: 19, nextColor: .white)
        let msg = "info move Q16 visits 0 winrate 0.5 scoreLead 0 utilityLcb 0 "
                + "info move D4 visits 0 winrate 0.6 scoreLead 1 utilityLcb 1"
        let r = parser.parse(message: msg)
        #expect(r.info[q16] == nil)        // visits 0 && winrate 0.5 -> dropped
        #expect(r.info[d4] != nil)         // visits 0 but winrate 0.6 -> kept
    }

    @Test func firstWinsOnSameKeyCollision() {
        // Two info blocks for the SAME move (Q16) with different values:
        // the first occurrence must win on key collision (not the last).
        let parser = AnalysisLineParser(boardWidth: 19, boardHeight: 19, nextColor: .white)
        let msg = "info move Q16 visits 10 winrate 0.55 scoreLead 1 utilityLcb 0 "
                + "info move Q16 visits 99 winrate 0.10 scoreLead 2 utilityLcb 0"
        let r = parser.parse(message: msg)
        #expect(r.info[q16]?.visits == 10)   // first wins, not 99
    }

    @Test func parsesPassMove() {
        let parser = AnalysisLineParser(boardWidth: 19, boardHeight: 19, nextColor: .white)
        let msg = "info move pass visits 10 winrate 0.5 scoreLead 0 utilityLcb 0"
        let r = parser.parse(message: msg)
        #expect(r.info[BoardPoint.pass(width: 19, height: 19)] != nil)
    }

    @Test func ownershipDigitizesAndOrders() {
        // 2x2 board: 4 ownership values, iterated y from 1..0, x 0..1.
        // mean -> whiteness = (mean+1)/2, digitized to nearest 1/5.
        // mean +1 -> whiteness 1.0 ; mean -1 -> whiteness 0.0.
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        let msg = "info move A1 visits 1 winrate 0.6 scoreLead 0 utilityLcb 0 "
                + "ownership 1.0 -1.0 1.0 -1.0 ownershipStdev 0.0 0.0 0.0 0.0"
        let units = parser.parse(message: msg).ownershipUnits
        #expect(units.count == 4)
        #expect(units[0].point == BoardPoint(x: 0, y: 1))   // first cell: y = height-1, x = 0
        #expect(abs(units[0].whiteness - 1.0) < 1e-4)
        #expect(abs(units[1].whiteness - 0.0) < 1e-4)
    }

    @Test func ownershipCountMismatchYieldsEmpty() {
        let parser = AnalysisLineParser(boardWidth: 2, boardHeight: 2, nextColor: .white)
        // 3 values for a 4-cell board -> rejected.
        let msg = "info move A1 visits 1 winrate 0.6 scoreLead 0 utilityLcb 0 "
                + "ownership 1.0 -1.0 1.0 ownershipStdev 0.0 0.0 0.0"
        #expect(parser.parse(message: msg).ownershipUnits.isEmpty)
    }

    @Test func garbageYieldsEmpty() {
        let parser = AnalysisLineParser(boardWidth: 19, boardHeight: 19, nextColor: .white)
        let r = parser.parse(message: "not an analysis line")
        #expect(r.info.isEmpty)
        #expect(r.ownershipUnits.isEmpty)
    }
}
