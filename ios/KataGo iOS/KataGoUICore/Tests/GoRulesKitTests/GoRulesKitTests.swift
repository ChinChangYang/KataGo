//
//  GoRulesKitTests.swift
//  GoRulesKitTests
//
//  Standalone (engine-free) tests for the pure-Swift rules engine: capture
//  mechanics, ko/superko, suicide, phase machine, scoring across rulesets,
//  and the iMessage wire codec. The differential tests against the C++
//  engine live in the app test target; these lock in hand-computed cases.
//

import Foundation
import Testing
@testable import GoRulesKit
import KataGoGameStore

struct GoBoardTests {
    @Test func singleStoneCaptureRemovesStoneAndCounts() throws {
        var game = try GoGame(width: 5, height: 5, rules: .chinese)
        for move in [
            GoMove.play(GoPoint(x: 1, y: 1)), .play(GoPoint(x: 2, y: 1)),
            .play(GoPoint(x: 2, y: 0)), .play(GoPoint(x: 0, y: 0)),
            .play(GoPoint(x: 3, y: 1)), .play(GoPoint(x: 4, y: 4)),
            .play(GoPoint(x: 2, y: 2)),
        ] {
            try game.play(move)
        }
        #expect(game.board.color(at: GoPoint(x: 2, y: 1)) == .empty)
        #expect(game.board.numWhiteCaptures == 1)
        #expect(game.board.numBlackCaptures == 0)
    }

    @Test func simpleKoIsBannedImmediatelyAndOnlyImmediately() throws {
        var board = GoBoard(width: 5, height: 5)
        for p in [(2, 1), (1, 2), (2, 3)] {
            board.placeSetupStone(at: GoPoint(x: p.0, y: p.1), color: .black)
        }
        for p in [(2, 2), (3, 1), (4, 2), (3, 3)] {
            board.placeSetupStone(at: GoPoint(x: p.0, y: p.1), color: .white)
        }
        try board.play(at: GoPoint(x: 3, y: 2), color: .black, multiStoneSuicideLegal: false)
        #expect(board.color(at: GoPoint(x: 2, y: 2)) == .empty)
        #expect(board.koLoc == board.index(of: GoPoint(x: 2, y: 2)))
        #expect(board.isLegal(at: GoPoint(x: 2, y: 2), color: .white, multiStoneSuicideLegal: false) == false)
        // Any other move lifts the simple-ko ban.
        try board.play(at: GoPoint(x: 0, y: 0), color: .white, multiStoneSuicideLegal: false)
        #expect(board.koLoc == nil)
        #expect(board.isLegal(at: GoPoint(x: 2, y: 2), color: .white, multiStoneSuicideLegal: false))
    }

    @Test func singleStoneSuicideIsAlwaysIllegal() {
        var board = GoBoard(width: 2, height: 2)
        board.placeSetupStone(at: GoPoint(x: 0, y: 1), color: .black)
        board.placeSetupStone(at: GoPoint(x: 1, y: 0), color: .black)
        #expect(board.isLegal(at: GoPoint(x: 0, y: 0), color: .white, multiStoneSuicideLegal: true) == false)
        #expect(board.isLegal(at: GoPoint(x: 0, y: 0), color: .white, multiStoneSuicideLegal: false) == false)
    }

    @Test func multiStoneSuicideFollowsTheRule() {
        var board = GoBoard(width: 3, height: 3)
        // White surrounds the top-left two points; black stones at (0,0)
        // group with a played (1,0) into a 0-liberty chain.
        board.placeSetupStone(at: GoPoint(x: 0, y: 0), color: .black)
        board.placeSetupStone(at: GoPoint(x: 2, y: 0), color: .white)
        board.placeSetupStone(at: GoPoint(x: 0, y: 1), color: .white)
        board.placeSetupStone(at: GoPoint(x: 1, y: 1), color: .white)
        board.placeSetupStone(at: GoPoint(x: 2, y: 1), color: .white)
        #expect(board.isLegal(at: GoPoint(x: 1, y: 0), color: .black, multiStoneSuicideLegal: false) == false)
        #expect(board.isLegal(at: GoPoint(x: 1, y: 0), color: .black, multiStoneSuicideLegal: true))
        var suicideBoard = board
        try? suicideBoard.play(at: GoPoint(x: 1, y: 0), color: .black, multiStoneSuicideLegal: true)
        #expect(suicideBoard.color(at: GoPoint(x: 0, y: 0)) == .empty)
        #expect(suicideBoard.color(at: GoPoint(x: 1, y: 0)) == .empty)
        #expect(suicideBoard.numBlackCaptures == 2)
    }
}

struct GoGameSuperkoTests {
    /// Black fills the whole 2x2 board; the 4-stone suicide clears it,
    /// recreating the empty starting position — but with White to move.
    private func playBoardClearingCycle(rules: GoRules) throws -> GoGame {
        var game = try GoGame(width: 2, height: 2, rules: rules)
        try game.play(.play(GoPoint(x: 0, y: 0)))
        try game.play(.pass)
        try game.play(.play(GoPoint(x: 0, y: 1)))
        try game.play(.pass)
        try game.play(.play(GoPoint(x: 1, y: 0)))
        try game.play(.pass)
        return game
    }

    @Test func positionalSuperkoBansRecreatingAnyPosition() throws {
        let rules = GoRules(koRule: .positional, scoringRule: .area, multiStoneSuicideLegal: true)
        let game = try playBoardClearingCycle(rules: rules)
        #expect(game.isLegal(.play(GoPoint(x: 1, y: 1))) == false)
    }

    @Test func situationalSuperkoAllowsSamePositionDifferentMover() throws {
        let rules = GoRules(koRule: .situational, scoringRule: .area, multiStoneSuicideLegal: true)
        var game = try playBoardClearingCycle(rules: rules)
        // The empty board only ever existed with Black to move; after the
        // clearing suicide it is White's turn, so situational allows it.
        #expect(game.isLegal(.play(GoPoint(x: 1, y: 1))))
        try game.play(.play(GoPoint(x: 1, y: 1)))
        #expect(game.board.grid.allSatisfy { $0 == .empty })
    }

    @Test func simpleKoRuleIgnoresWholeBoardRepetition() throws {
        let rules = GoRules(koRule: .simple, scoringRule: .area, multiStoneSuicideLegal: true)
        let game = try playBoardClearingCycle(rules: rules)
        #expect(game.isLegal(.play(GoPoint(x: 1, y: 1))))
    }
}

struct GoGamePhaseTests {
    @Test func twoPassesEnterScoringAndDisputeResumes() throws {
        var game = try GoGame(width: 5, height: 5, rules: .chinese)
        try game.play(.play(GoPoint(x: 2, y: 2)))
        try game.play(.pass)
        try game.play(.pass)
        #expect(game.phase == .scoring)
        game.toggleDead(at: GoPoint(x: 2, y: 2))
        #expect(game.markedDead.count == 1)
        game.resumePlay()
        #expect(game.phase == .playing)
        #expect(game.markedDead.isEmpty)
        // Alternation continued through the passes: Black moved, passed —
        // after White's pass it is Black's turn again.
        #expect(game.toMove == .white)
    }

    @Test func resignationFinishesTheGame() throws {
        var game = try GoGame(width: 9, height: 9, rules: .japanese)
        try game.play(.play(GoPoint(x: 4, y: 4)))
        game.resign(by: .white)
        #expect(game.phase == .finished(GoGameResult(kind: .resignation(winner: .black))))
        #expect(GoGameResult(kind: .resignation(winner: .black)).shortText == "B+R")
    }

    @Test func handicapGameStartsWithWhiteAndPlacesConventionalStones() throws {
        let game = try GoGame(width: 19, height: 19, rules: .chinese, handicap: 2)
        #expect(game.toMove == .white)
        #expect(game.board.color(at: GoPoint(x: 15, y: 3)) == .black)
        #expect(game.board.color(at: GoPoint(x: 3, y: 15)) == .black)
        #expect(GoGame.handicapPoints(width: 19, height: 19, count: 9).count == 9)
        #expect(GoGame.maxHandicap(width: 19, height: 19) == 9)
        #expect(GoGame.maxHandicap(width: 8, height: 8) == 0)
    }
}

struct GoScoringTests {
    /// Black wall on column 2, White wall on column 3 of a 5x5 board:
    /// Black owns 15 points of area, White 10.
    private func dividedBoardGame(rules: GoRules) throws -> GoGame {
        var game = try GoGame(width: 5, height: 5, rules: rules)
        for y in 0..<5 {
            try game.play(.play(GoPoint(x: 2, y: y)))
            try game.play(.play(GoPoint(x: 3, y: y)))
        }
        return game
    }

    @Test func areaScoringCountsStonesAndTerritory() throws {
        var game = try dividedBoardGame(rules: .chinese)
        try game.play(.pass)
        try game.play(.pass)
        #expect(game.phase == .scoring)
        let score = game.scoreNow()
        // Board: 10 - 15 = -5, komi 7.5 => W+2.5.
        #expect(score.whiteMinusBlack == 2.5)
        game.confirmScore()
        #expect(game.phase == .finished(GoGameResult(kind: .score(whiteMinusBlack: 2.5))))
        #expect(GoGameResult(kind: .score(whiteMinusBlack: 2.5)).shortText == "W+2.5")
    }

    @Test func territoryScoringChillMatchesJapaneseCount() throws {
        var game = try dividedBoardGame(rules: .japanese)
        try game.play(.pass)
        try game.play(.pass)
        // Japanese count: B 10 territory, W 5 territory + 6.5 komi => W+1.5.
        #expect(game.scoreNow().whiteMinusBlack == 1.5)
    }

    @Test func markedDeadStonesAreRemovedBeforeCounting() throws {
        var game = try dividedBoardGame(rules: .chinese)
        try game.play(.play(GoPoint(x: 0, y: 0)))   // Black extra move inside own area
        try game.play(.play(GoPoint(x: 1, y: 1)))   // White invades dead
        try game.play(.pass)
        try game.play(.pass)
        game.toggleDead(at: GoPoint(x: 1, y: 1))
        // Removing the dead invader restores the clean division, with one
        // extra black stone inside black's own area (area scoring: no change).
        #expect(game.scoreNow().whiteMinusBlack == 2.5)
    }

    @Test func buttonGoesToTheFirstPasser() throws {
        let rules = GoRules(koRule: .simple, scoringRule: .area, taxRule: .none,
                            hasButton: true, komi: 7.5)
        var game = try dividedBoardGame(rules: rules)
        try game.play(.pass)    // Black takes the button: -0.5 for White
        try game.play(.pass)    // first ending pass
        #expect(game.phase == .playing)
        try game.play(.pass)    // second ending pass
        #expect(game.phase == .scoring)
        #expect(game.scoreNow().whiteMinusBlack == 2.0)
    }

    @Test func whiteHandicapBonusCountsStones() throws {
        var game = try GoGame(width: 9, height: 9, rules: .chinese, handicap: 2)
        try game.play(.pass)
        try game.play(.pass)
        // Whole board is black area: -81, plus whb N (+2) and komi 7.5.
        #expect(game.scoreNow().whiteMinusBlack == -71.5)
    }

    @Test func sekiStrippingRemovesDameTouchingTerritory() {
        // Black wall column 2 (5 stones); White column 3 rows 0-3 (4 stones);
        // the right side stays open so every group touches dame.
        var board = GoBoard(width: 5, height: 5)
        for y in 0..<5 { board.placeSetupStone(at: GoPoint(x: 2, y: y), color: .black) }
        for y in 0..<4 { board.placeSetupStone(at: GoPoint(x: 3, y: y), color: .white) }

        let taxNone = GoAreaScorer.areaScoreWhiteMinusBlack(
            board: board, rules: GoRules(scoringRule: .area, taxRule: .none))
        // Everything counts: black 10 + 5 vs white 4 (open region touches both).
        #expect(taxNone.score == -11)

        let taxSeki = GoAreaScorer.areaScoreWhiteMinusBlack(
            board: board, rules: GoRules(scoringRule: .area, taxRule: .seki))
        // Both groups touch dame, so only the stones themselves count.
        #expect(taxSeki.score == -1)
    }

    @Test func groupTaxChargesPerIndependentRegion() {
        // Black alone with two walls: one connected area component => -2.
        var board = GoBoard(width: 7, height: 7)
        for y in 0..<7 {
            board.placeSetupStone(at: GoPoint(x: 2, y: y), color: .black)
            board.placeSetupStone(at: GoPoint(x: 4, y: y), color: .black)
        }
        let none = GoAreaScorer.areaScoreWhiteMinusBlack(
            board: board, rules: GoRules(scoringRule: .area, taxRule: .none))
        #expect(none.score == -49)
        let all = GoAreaScorer.areaScoreWhiteMinusBlack(
            board: board, rules: GoRules(scoringRule: .area, taxRule: .all))
        #expect(all.score == -47)
    }

    @Test func randomPlayoutsKeepStoneAccountingConsistent() throws {
        var rng = SplitMix64RandomNumberGenerator(seed: 0xC0FFEE)
        var game = try GoGame(width: 5, height: 5, rules: .trompTaylor)
        var plays = 0
        for _ in 0..<120 where game.phase == .playing {
            let legal = (0..<25).map { GoPoint(x: $0 % 5, y: $0 / 5) }
                .filter { game.isLegal(.play($0)) }
            guard let choice = legal.randomElement(using: &rng) else { break }
            try game.play(.play(choice))
            plays += 1
        }
        let blackPlays = (plays + 1) / 2
        let whitePlays = plays / 2
        let blackOnBoard = game.board.grid.count(where: { $0 == .black })
        let whiteOnBoard = game.board.grid.count(where: { $0 == .white })
        #expect(blackOnBoard + game.board.numBlackCaptures == blackPlays)
        #expect(whiteOnBoard + game.board.numWhiteCaptures == whitePlays)
    }
}

struct MessageGameCodecTests {
    private func midGame() throws -> MessageGame {
        var game = try GoGame(width: 9, height: 9, rules: .aga)
        try game.play(.play(GoPoint(x: 2, y: 2)))
        try game.play(.play(GoPoint(x: 6, y: 6)))
        try game.play(.play(GoPoint(x: 6, y: 2)))
        return MessageGame(game: game, creatorColor: .black)
    }

    @Test func roundTripsAPlayingGame() throws {
        let original = try midGame()
        let decoded = try MessageGameCodec.decode(MessageGameCodec.url(for: original))
        #expect(decoded.game.board == original.game.board)
        #expect(decoded.game.moves == original.game.moves)
        #expect(decoded.game.phase == .playing)
        #expect(decoded.creatorColor == .black)
        #expect(decoded.game.rules == original.game.rules)
    }

    @Test func roundTripsScoringWithDeadMarks() throws {
        var message = try midGame()
        try message.game.play(.play(GoPoint(x: 4, y: 4)))
        try message.game.play(.pass)
        try message.game.play(.pass)
        message.game.toggleDead(at: GoPoint(x: 4, y: 4))
        let decoded = try MessageGameCodec.decode(MessageGameCodec.url(for: message))
        #expect(decoded.game.phase == .scoring)
        #expect(decoded.game.markedDead == message.game.markedDead)
    }

    @Test func roundTripsAConfirmedScore() throws {
        var game = try GoGame(width: 5, height: 5, rules: .chinese)
        try game.play(.play(GoPoint(x: 2, y: 2)))
        try game.play(.pass)
        try game.play(.pass)
        game.confirmScore()
        let message = MessageGame(game: game, creatorColor: .white)
        let decoded = try MessageGameCodec.decode(MessageGameCodec.url(for: message))
        #expect(decoded.game.phase == game.phase)
    }

    @Test func roundTripsAResignation() throws {
        var message = try midGame()
        message.game.resign(by: .white)
        let decoded = try MessageGameCodec.decode(MessageGameCodec.url(for: message))
        #expect(decoded.game.phase == .finished(GoGameResult(kind: .resignation(winner: .black))))
    }

    @Test func roundTripsADisputedResume() throws {
        var message = try midGame()
        try message.game.play(.play(GoPoint(x: 4, y: 4)))
        try message.game.play(.pass)
        try message.game.play(.pass)
        message.game.resumePlay()
        try message.game.play(.play(GoPoint(x: 1, y: 7)))
        let decoded = try MessageGameCodec.decode(MessageGameCodec.url(for: message))
        #expect(decoded.game.phase == .playing)
        #expect(decoded.game.moves == message.game.moves)
    }

    @Test func rejectsATamperedMoveList() throws {
        let message = try midGame()
        var url = MessageGameCodec.url(for: message)
        var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        components.queryItems = components.queryItems?.map { item in
            // Duplicate the first move: replays onto an occupied point.
            item.name == "m" ? URLQueryItem(name: "m", value: item.value! + "22") : item
        }
        url = try #require(components.url)
        #expect(throws: MessageGameCodecError.illegalReplay(moveIndex: 3)) {
            _ = try MessageGameCodec.decode(url)
        }
    }

    @Test func rejectsUnknownVersions() throws {
        let message = try midGame()
        var components = try #require(URLComponents(
            url: MessageGameCodec.url(for: message), resolvingAgainstBaseURL: false))
        components.queryItems = components.queryItems?.map {
            $0.name == "v" ? URLQueryItem(name: "v", value: "99") : $0
        }
        let url = try #require(components.url)
        #expect(throws: MessageGameCodecError.unsupportedVersion) {
            _ = try MessageGameCodec.decode(url)
        }
    }

    @Test func emitsStandardSgfWithHandicapAndRules() throws {
        var game = try GoGame(width: 9, height: 9, rules: .chinese, handicap: 2)
        try game.play(.play(GoPoint(x: 4, y: 4)))   // White (handicap game)
        let sgf = MessageGameCodec.sgf(for: MessageGame(game: game, creatorColor: .black))
        #expect(sgf.hasPrefix("(;GM[1]FF[4]CA[UTF-8]SZ[9]"))
        #expect(sgf.contains("KM[7.5]"))
        #expect(sgf.contains("RU[koSIMPLEscoreAREAtaxNONEsui0whbN]"))
        #expect(sgf.contains("HA[2]AB[gc][cg]"))
        #expect(sgf.hasSuffix(";W[ee])"))
    }

    @Test func gtpVertexMatchesTheStoreParser() {
        let point = GoPoint(x: 0, y: 0)
        #expect(point.gtpVertex(boardHeight: 19) == "A19")
        let parsed = parseVertex("A19", width: 19, height: 19)
        #expect(parsed?.x == 0)
        #expect(parsed?.y == 0)
        let far = GoPoint(x: 27, y: 36)
        let vertex = far.gtpVertex(boardHeight: 37)
        let reparsed = parseVertex(vertex, width: 37, height: 37)
        #expect(reparsed?.x == 27)
        #expect(reparsed?.y == 36)
    }
}

/// Deterministic RNG so the playout test is reproducible.
struct SplitMix64RandomNumberGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
