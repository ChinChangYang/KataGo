//
//  MoveLegalityTests.swift
//  GoRulesKitTests
//
//  Strict legality for a NEW move at a record position — kata-check-move's
//  reasons decided without the engine — layered over SgfReplay's TOLERANT
//  replay, which these tests also pin as untouched.
//

import Foundation
import Testing
@testable import GoRulesKit
import KataGoAnalysisKit
import KataGoGameStore

struct MoveLegalityTests {
    private typealias Move = SgfReplay.RecordedMove

    private static func black(_ x: Int, _ y: Int) -> Move { Move(color: .black, point: GoPoint(x: x, y: y)) }
    private static func white(_ x: Int, _ y: Int) -> Move { Move(color: .white, point: GoPoint(x: x, y: y)) }
    private static let blackPass = Move(color: .black, point: nil)
    private static let whitePass = Move(color: .white, point: nil)

    private func point(_ x: Int, _ y: Int) -> GoPoint { GoPoint(x: x, y: y) }

    /// The 5x5 ko from GoBoardTests: Black's stone at (3,2) takes White's at
    /// (2,2), leaving (2,2) the simple-ko point with White to move at index 1.
    private static func koReplay(then moves: [Move]) -> SgfReplay {
        SgfReplay(width: 5, height: 5,
                  setupBlack: [GoPoint(x: 2, y: 1), GoPoint(x: 1, y: 2), GoPoint(x: 2, y: 3)],
                  setupWhite: [GoPoint(x: 2, y: 2), GoPoint(x: 3, y: 1),
                               GoPoint(x: 4, y: 2), GoPoint(x: 3, y: 3)],
                  moves: [black(3, 2)] + moves)
    }

    /// Black fills three points of a 2x2 board while White passes; a fourth
    /// Black stone is a multi-stone suicide that empties the board again.
    private static let fillingMoves: [Move] = [
        black(0, 0), whitePass, black(0, 1), whitePass, black(1, 0), whitePass,
    ]

    // MARK: - Always / never

    @Test("A pass is legal in every situation, even where the point is banned")
    func passIsAlwaysLegal() {
        var r = Self.koReplay(then: [])
        for koRule in [KoRule.simple, .positional, .situational] {
            let ctx = r.legalityContext(at: 1, koRule: koRule, multiStoneSuicideLegal: false)
            #expect(ctx.check(point: point(2, 2), color: .white) != .legal)
            #expect(ctx.check(point: nil, color: .white) == .legal)
            #expect(ctx.check(point: nil, color: .black) == .legal)
        }
        #expect(MoveLegality.legal.reason == nil)
        #expect(MoveLegality.legal.canPlayAnyway == false)
    }

    @Test("Out of bounds and occupied points are refused for either colour and never playable anyway")
    func outOfBoundsAndOccupied() {
        var r = Self.koReplay(then: [])
        let ctx = r.legalityContext(at: 1, koRule: .positional, multiStoneSuicideLegal: false)
        for p in [point(-1, 0), point(5, 0), point(0, 5), point(0, -1)] {
            #expect(ctx.check(point: p, color: .white) == .outOfBounds)
            #expect(ctx.check(point: p, color: .black) == .outOfBounds)
        }
        #expect(MoveLegality.outOfBounds.reason == "out_of_bounds")
        #expect(MoveLegality.outOfBounds.canPlayAnyway == false)

        // (3,2) holds Black's stone, (3,1) White's: occupied for either colour.
        for p in [point(3, 2), point(3, 1)] {
            #expect(ctx.check(point: p, color: .black) == .occupied)
            #expect(ctx.check(point: p, color: .white) == .occupied)
        }
        #expect(MoveLegality.occupied.reason == "occupied")
        #expect(MoveLegality.occupied.canPlayAnyway == false)
    }

    // MARK: - Simple ko

    @Test("The immediate ko retake is banned, a pass lifts it, and the tolerant replay still plays it")
    func simpleKoRetake() {
        var r = Self.koReplay(then: [Self.whitePass, Self.blackPass])
        let taken = r.legalityContext(at: 1, koRule: .simple, multiStoneSuicideLegal: false)
        #expect(taken.toMove == .white)
        #expect(taken.board.koLoc == taken.board.index(of: point(2, 2)))
        #expect(taken.check(point: point(2, 2), color: .white) == .ko)
        #expect(MoveLegality.ko.reason == "ko")
        #expect(MoveLegality.ko.canPlayAnyway)
        // The ban is one point; anywhere else is fine.
        #expect(taken.check(point: point(0, 0), color: .white) == .legal)

        // White's recorded pass clears the ko point ...
        let afterWhitePass = r.legalityContext(at: 2, koRule: .simple, multiStoneSuicideLegal: false)
        #expect(afterWhitePass.board.koLoc == nil)
        #expect(afterWhitePass.check(point: point(2, 2), color: .white) == .legal)
        // ... and once Black has passed too, White is to move and may retake.
        let whiteToMove = r.legalityContext(at: 3, koRule: .simple, multiStoneSuicideLegal: false)
        #expect(whiteToMove.toMove == .white)
        #expect(whiteToMove.check(point: point(2, 2), color: .white) == .legal)

        // The replay's tolerance is untouched: the SAME retake, recorded as
        // the very next move, is played rather than refused — the engine's
        // `play` accepts it, so the feed and the board must too.
        var recorded = Self.koReplay(then: [Self.white(2, 2)])
        let position = recorded.position(at: 2)
        #expect(recorded.refusedIndices.isEmpty)
        #expect(position.whiteVertices.contains(point(2, 2).gtpVertex(boardHeight: 5)))
        #expect(!position.blackVertices.contains(point(3, 2).gtpVertex(boardHeight: 5)))
    }

    // MARK: - Suicide

    @Test("A lone-stone suicide is never playable; a multi-stone suicide follows the rule and may be played anyway")
    func suicide() {
        // The corner (0,0) walled by Black at (1,0) and (0,1): a White stone
        // there is alone with no liberty.
        let wall = [point(1, 0), point(0, 1)]
        var lone = SgfReplay(width: 3, height: 3, setupBlack: wall, setupWhite: [point(2, 2)], moves: [])
        for allowed in [false, true] {
            let ctx = lone.legalityContext(at: 0, koRule: .simple, multiStoneSuicideLegal: allowed)
            #expect(ctx.check(point: point(0, 0), color: .white) == .suicide(multiStone: false))
        }
        #expect(MoveLegality.suicide(multiStone: false).reason == "suicide")
        #expect(MoveLegality.suicide(multiStone: false).canPlayAnyway == false)
        // No "Play Anyway" because the tolerant replay refuses exactly this move.
        var recorded = SgfReplay(width: 3, height: 3, setupBlack: wall, setupWhite: [point(2, 2)],
                                 moves: [Self.white(0, 0)])
        _ = recorded.position(at: 1)
        #expect(recorded.isRefused(0))

        // The GoBoardTests shape: Black's (0,0) sealed by White; a Black stone
        // at (1,0) joins it into a two-stone chain with no liberty.
        var joined = SgfReplay(width: 3, height: 3, setupBlack: [point(0, 0)],
                               setupWhite: [point(2, 0), point(0, 1), point(1, 1), point(2, 1)],
                               moves: [])
        let forbidden = joined.legalityContext(at: 0, koRule: .simple, multiStoneSuicideLegal: false)
        #expect(forbidden.check(point: point(1, 0), color: .black) == .suicide(multiStone: true))
        #expect(MoveLegality.suicide(multiStone: true).reason == "suicide")
        #expect(MoveLegality.suicide(multiStone: true).canPlayAnyway)
        let allowed = joined.legalityContext(at: 0, koRule: .simple, multiStoneSuicideLegal: true)
        #expect(allowed.check(point: point(1, 0), color: .black) == .legal)
    }

    // MARK: - Superko

    @Test("Emptying the 2x2 board again is superko under positional, legal under simple, a new situation under situational")
    func wholeBoardRepetition() {
        var r = SgfReplay(width: 2, height: 2, moves: Self.fillingMoves)
        let clearing = point(1, 1)

        let positional = r.legalityContext(at: 6, koRule: .positional, multiStoneSuicideLegal: true)
        #expect(positional.toMove == .black)
        #expect(positional.check(point: clearing, color: .black) == .superko)
        #expect(MoveLegality.superko.reason == "superko")
        #expect(MoveLegality.superko.canPlayAnyway)
        // Passes do not clear the history: the four distinct positions.
        #expect(positional.koHashes.count == 4)

        let simple = r.legalityContext(at: 6, koRule: .simple, multiStoneSuicideLegal: true)
        #expect(simple.check(point: clearing, color: .black) == .legal)
        #expect(simple.koHashes.isEmpty)

        // Same stones, other side to move: the empty board only ever existed
        // with Black to move, and after the clearing suicide it is White's.
        let situational = r.legalityContext(at: 6, koRule: .situational, multiStoneSuicideLegal: true)
        #expect(situational.check(point: clearing, color: .black) == .legal)
        // Every position with each side to move — the passes count.
        #expect(situational.koHashes.count == 7)
    }

    @Test("Situational superko bans recreating a position with the same side to move")
    func situationalRepeat() {
        // The clearing suicide is RECORDED (the tolerant replay plays it), then
        // White passes: Black to move on an empty board, as at the start.
        var r = SgfReplay(width: 2, height: 2,
                          moves: Self.fillingMoves + [Self.black(1, 1), Self.whitePass])
        let ctx = r.legalityContext(at: 8, koRule: .situational, multiStoneSuicideLegal: true)
        #expect(ctx.toMove == .black)
        #expect(ctx.board.grid.allSatisfy { $0 == .empty })
        // Black at (0,0) with White to move is exactly the situation after move 0.
        #expect(ctx.check(point: point(0, 0), color: .black) == .superko)
        // Black at (1,1) never stood alone on the board.
        #expect(ctx.check(point: point(1, 1), color: .black) == .legal)
    }

    @Test("A colour repeat restarts the ko history, as the engine's makeMove does")
    func colourRepeatRestartsHistory() {
        // Black's second stone follows Black's first with no White move
        // between: Search::makeMove clears BoardHistory, so the empty board
        // drops out of the history and emptying it again is no repetition.
        var r = SgfReplay(width: 2, height: 2, moves: [
            Self.black(0, 0), Self.black(0, 1), Self.whitePass, Self.black(1, 0), Self.whitePass,
        ])
        let ctx = r.legalityContext(at: 5, koRule: .positional, multiStoneSuicideLegal: true)
        #expect(ctx.toMove == .black)
        #expect(ctx.check(point: point(1, 1), color: .black) == .legal)
        #expect(!ctx.koHashes.contains(GoBoard(width: 2, height: 2).posHash))
        // One stone (reseeded before the repeat), two, three.
        #expect(ctx.koHashes.count == 3)
    }

    // MARK: - Setup stones

    @Test("A handicap record starts with White to move and its setup position in the ko history")
    func handicapSetup() {
        var r = SgfReplay(width: 2, height: 2, setupBlack: [point(0, 0)], moves: [
            Self.whitePass, Self.black(0, 1), Self.whitePass, Self.black(1, 0), Self.whitePass,
            Self.black(1, 1), Self.whitePass,
        ])
        let start = r.legalityContext(at: 0, koRule: .situational, multiStoneSuicideLegal: true)
        #expect(start.toMove == .white)
        #expect(start.toMoveColor == .white)
        #expect(start.koHashes == [start.board.situationalHash(toMove: .white)])

        // Black's fourth stone emptied the board and White passed: Black
        // putting the handicap stone back recreates the setup position with
        // White to move — the initial situation, under either superko rule.
        let situational = r.legalityContext(at: 7, koRule: .situational, multiStoneSuicideLegal: true)
        #expect(situational.toMove == .black)
        #expect(situational.board.grid.allSatisfy { $0 == .empty })
        #expect(situational.check(point: point(0, 0), color: .black) == .superko)
        let positional = r.legalityContext(at: 7, koRule: .positional, multiStoneSuicideLegal: true)
        #expect(positional.check(point: point(0, 0), color: .black) == .superko)
        let simple = r.legalityContext(at: 7, koRule: .simple, multiStoneSuicideLegal: true)
        #expect(simple.check(point: point(0, 0), color: .black) == .legal)
    }

    // MARK: - Index handling

    @Test("The context clamps like position(at:) and skips a refused move identically")
    func clampingAndRefusals() {
        // White's first stone lands on Black's: refused, so White is still to
        // move and plays elsewhere.
        var r = SgfReplay(width: 9, height: 9, moves: [Self.black(2, 2), Self.white(2, 2), Self.white(3, 3)])
        let end = r.legalityContext(at: 99, koRule: .positional, multiStoneSuicideLegal: false)
        #expect(r.isRefused(1))
        let position = r.position(at: 99)
        #expect(end.board.gtpVertices(of: .black) == position.blackVertices)
        #expect(end.board.gtpVertices(of: .white) == position.whiteVertices)
        #expect(end.toMove == position.toMove)
        #expect(end.toMove == .black)
        #expect(end.board == r.legalityContext(at: 3, koRule: .positional, multiStoneSuicideLegal: false).board)
        // The refused move was never played: empty, one stone, two stones.
        #expect(end.koHashes.count == 3)

        let start = r.legalityContext(at: -4, koRule: .positional, multiStoneSuicideLegal: false)
        #expect(start.board == GoBoard(width: 9, height: 9))
        #expect(start.toMove == .black)
        #expect(start.koHashes == [0])
    }
}
