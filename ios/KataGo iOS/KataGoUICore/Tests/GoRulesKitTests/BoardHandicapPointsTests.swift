//
//  BoardHandicapPointsTests.swift
//  GoRulesKitTests
//
//  Locks in BoardHandicapPoints (KataGoGameStore) and its GoGame delegation:
//  the full 2-9 ladder, small-board caps, rectangles/layout-free boards, and
//  the SGF coordinate mapper.
//

import Testing
import KataGoGameStore
import GoRulesKit

struct BoardHandicapPointsTests {
    @Test("19x19 supports the full 2-9 ladder in conventional order")
    func nineteenFullLadder() {
        for n in 2...9 {
            #expect(BoardHandicapPoints.points(width: 19, height: 19, count: n).count == n)
        }
        let two = BoardHandicapPoints.points(width: 19, height: 19, count: 2)
        #expect(two.map { [$0.x, $0.y] } == [[15, 3], [3, 15]])
    }

    @Test("9x9 and 13x13 cap at five stones")
    func smallSquaresCapAtFive() {
        for size in [9, 13] {
            #expect(BoardHandicapPoints.maxCount(width: size, height: size) == 5)
            #expect(BoardHandicapPoints.points(width: size, height: size, count: 5).count == 5)
            for n in 6...9 {
                #expect(BoardHandicapPoints.points(width: size, height: size, count: n).isEmpty)
            }
        }
    }

    @Test("rectangles and layout-free boards")
    func rectanglesAndEmptyDomains() {
        #expect(BoardHandicapPoints.maxCount(width: 9, height: 13) == 5)
        #expect(BoardHandicapPoints.points(width: 9, height: 13, count: 4).count == 4)
        #expect(BoardHandicapPoints.points(width: 9, height: 13, count: 6).isEmpty)
        #expect(BoardHandicapPoints.maxCount(width: 8, height: 8) == 0)
        #expect(BoardHandicapPoints.maxCount(width: 5, height: 5) == 0)
        #expect(BoardHandicapPoints.maxCount(width: 2, height: 19) == 0)
    }

    @Test("GoGame delegation is byte-identical")
    func delegationMatchesGoGame() {
        for (w, h, n) in [(19, 19, 9), (19, 19, 2), (13, 13, 5), (9, 13, 4), (9, 9, 6)] {
            let a = BoardHandicapPoints.points(width: w, height: h, count: n).map { [$0.x, $0.y] }
            let b = GoGame.handicapPoints(width: w, height: h, count: n).map { [$0.x, $0.y] }
            #expect(a == b)
        }
    }

    @Test("SGF coordinates")
    func sgfCoordinates() {
        #expect(BoardHandicapPoints.sgfCoordinate(x: 0, y: 0) == "aa")
        #expect(BoardHandicapPoints.sgfCoordinate(x: 15, y: 3) == "pd")
        #expect(BoardHandicapPoints.sgfCoordinate(x: 3, y: 15) == "dp")
        #expect(BoardHandicapPoints.sgfCoordinate(x: 26, y: 0) == "Aa")
        #expect(BoardHandicapPoints.sgfCoordinate(x: 52, y: 0) == nil)
    }
}
