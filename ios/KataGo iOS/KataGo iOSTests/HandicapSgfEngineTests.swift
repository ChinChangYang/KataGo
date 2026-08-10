//
//  HandicapSgfEngineTests.swift
//  KataGo AnytimeTests
//
//  The handicap SGF builder's output, replayed through the C++ engine's
//  own SGF parser (SgfHelper, linked in this test host): frame 0 of the
//  GIF-frame walk is the setup position, so this proves the engine sees
//  exactly the stones BoardHandicapPoints placed, plus the komi.
//

import Testing
import KataGoGameStore
@testable import KataGoUICore

struct HandicapSgfEngineTests {
    /// GTP vertex ("Q16") for a top-left-origin (x, y): column letters skip
    /// "I", rows count up from the bottom edge.
    private func gtpVertex(x: Int, y: Int, height: Int) -> String {
        let letters = Array("ABCDEFGHJKLMNOPQRSTUVWXYZ")
        return "\(letters[x])\(height - y)"
    }

    @Test("engine setup position matches the placement rule", arguments: [
        [19, 19, 9], [19, 19, 2], [13, 13, 5], [9, 13, 4],
    ])
    func engineSetupMatchesPlacement(scenario: [Int]) throws {
        let (width, height, handicap) = (scenario[0], scenario[1], scenario[2])
        let sgf = try #require(GameRecord.makeSgf(width: width, height: height, komi: 0.5,
                                                  ruleString: "japanese", handicap: handicap))
        let frames = SgfHelper(sgf: sgf).gifFrames()
        let setup = try #require(frames.first)
        let expected = Set(
            BoardHandicapPoints.points(width: width, height: height, count: handicap)
                .map { gtpVertex(x: $0.x, y: $0.y, height: height) })
        #expect(Set(setup.blackStones) == expected)
        #expect(setup.whiteStones.isEmpty)
        #expect(SgfOperations(sgf: sgf).rules.komi == 0.5)
    }
}
