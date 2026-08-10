//
//  HandicapSgfTests.swift
//  GoRulesKitTests
//
//  Locks in GameRecord.makeSgf's handicap overload: HA[n]AB[...]PL[W] built
//  from BoardHandicapPoints, delegating to the plain builder at handicap 0
//  and refusing handicaps the board has no star-point layout for.
//

import Testing
import KataGoGameStore

struct HandicapSgfTests {
    @Test("two-stone 19x19 emits HA, AB on the conventional points, PL[W]")
    func nineteenTwoStone() {
        let sgf = GameRecord.makeSgf(width: 19, height: 19, komi: 0.5,
                                     ruleString: "japanese", handicap: 2)
        #expect(sgf == "(;FF[4]GM[1]SZ[19]PB[]PW[]HA[2]AB[pd][dp]PL[W]KM[0.5]RU[japanese])")
    }

    @Test("zero handicap matches the plain builder exactly")
    func zeroHandicapMatchesPlainBuilder() {
        let plain = GameRecord.makeSgf(width: 13, height: 9, komi: 7.0,
                                       ruleString: "chinese")
        let viaHandicap = GameRecord.makeSgf(width: 13, height: 9, komi: 7.0,
                                             ruleString: "chinese", handicap: 0)
        #expect(viaHandicap == plain)
    }

    @Test("AB point count and order match BoardHandicapPoints")
    func pointsMatchPlacementRule() throws {
        let sgf = try #require(GameRecord.makeSgf(width: 9, height: 9, komi: 0.5,
                                                  ruleString: "chinese", handicap: 5))
        let expected = BoardHandicapPoints.points(width: 9, height: 9, count: 5)
            .compactMap { BoardHandicapPoints.sgfCoordinate(x: $0.x, y: $0.y) }
            .map { "[\($0)]" }
            .joined()
        #expect(sgf.contains("HA[5]AB\(expected)PL[W]"))
    }

    @Test("boards without a layout refuse the handicap")
    func unsupportedHandicapIsNil() {
        #expect(GameRecord.makeSgf(width: 9, height: 9, komi: 0.5,
                                   ruleString: "chinese", handicap: 6) == nil)
        #expect(GameRecord.makeSgf(width: 8, height: 8, komi: 0.5,
                                   ruleString: "chinese", handicap: 2) == nil)
        #expect(GameRecord.makeSgf(width: 19, height: 19, komi: 0.5,
                                   ruleString: "chinese", handicap: 1) == nil)
        #expect(GameRecord.makeSgf(width: 19, height: 19, komi: 0.5,
                                   ruleString: "chinese", handicap: 10) == nil)
    }

    @Test("rectangles keep the w:h size field")
    func rectangleSizeField() throws {
        let sgf = try #require(GameRecord.makeSgf(width: 9, height: 13, komi: 0.5,
                                                  ruleString: "aga", handicap: 3))
        #expect(sgf.contains("SZ[9:13]"))
        #expect(sgf.contains("HA[3]"))
    }
}
