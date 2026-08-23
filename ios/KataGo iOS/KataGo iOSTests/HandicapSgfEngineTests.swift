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
import Foundation
import GoRulesKit
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

    /// The engine and the board have to agree on who moves first, and for a
    /// handicap game that is White. `set_free_handicap` is what arranges it
    /// engine-side (`gtp.cpp` sets `pla = P_WHITE` after the placement), so the
    /// feed has to choose THAT command and not `set_position`, which would
    /// leave Black to move over an all-Black board.
    @Test("A handicap record is fed the command that leaves White to move",
          arguments: [[19, 19, 9], [19, 19, 2], [13, 13, 5], [9, 13, 4]])
    func feedNextPlayerMatchesRecordToMove(scenario: [Int]) throws {
        let (width, height, handicap) = (scenario[0], scenario[1], scenario[2])
        let sgf = try #require(GameRecord.makeSgf(width: width, height: height, komi: 0.5,
                                                  ruleString: "japanese", handicap: handicap))
        var replay = try #require(RecordReplayBuilder.replay(from: SgfOperations(sgf: sgf)))

        // What the board says.
        #expect(replay.position(at: 0).toMove == .white)

        // What the engine is told.
        let setup = try #require(EngineFeed.setupCommand(replay: &replay))
        #expect(setup.hasPrefix("set_free_handicap "))

        // And the stones are the ones the placement rule chose.
        let expected = Set(
            BoardHandicapPoints.points(width: width, height: height, count: handicap)
                .map { gtpVertex(x: $0.x, y: $0.y, height: height) })
        let fed = Set(setup.dropFirst("set_free_handicap ".count).split(separator: " ").map(String.init))
        #expect(fed == expected)
    }

    /// An even game has no setup at all, so nothing is sent and Black moves
    /// first on both sides.
    @Test("An even record is fed no setup command and leaves Black to move")
    func evenRecordNeedsNoSetup() throws {
        let sgf = try #require(GameRecord.makeSgf(width: 19, height: 19, komi: 7.5,
                                                  ruleString: "japanese", handicap: 0))
        var replay = try #require(RecordReplayBuilder.replay(from: SgfOperations(sgf: sgf)))
        #expect(replay.position(at: 0).toMove == .black)
        #expect(EngineFeed.setupCommand(replay: &replay) == nil)
    }
}
