//
//  EngineHeldRuleTests.swift
//  KataGo iOSTests
//
//  *Held* is the answer to one question — "can the engine that is RUNNING take
//  a board this big?" — and it is a status line, never a screen: the record
//  position still draws either way. The rule below is the whole of it, shared
//  by every host that has an engine, so a board that is too large is refused
//  the same way on macOS as on iOS.
//
//  The transitions are deliberately narrow: only Ready may become Held, and
//  only Held may become Ready. A launch, a failure and "no model chosen" are
//  all statements about the ENGINE, and a board size must never overwrite one
//  of them — a 37x37 record opened while the engine is still compiling would
//  otherwise replace "Loading engine…" with a board-size complaint and then
//  never go back.
//

import Testing
@testable import KataGoUICore

struct EngineHeldRuleTests {

    // MARK: - Entering the hold

    @Test func aBoardBiggerThanTheBufferHoldsAReadyEngine() {
        #expect(EngineHeldRule.decide(current: .ready,
                                      boardWidth: 37,
                                      boardHeight: 37,
                                      maxBoardLength: 19) == .held(maxBoardLength: 19))
    }

    /// A rectangle is measured on BOTH sides: the NN buffer is square, so a
    /// 19x25 record overflows it just as surely as a 25x25 one.
    @Test func aRectangleIsMeasuredOnBothSides() {
        #expect(EngineHeldRule.decide(current: .ready,
                                      boardWidth: 19,
                                      boardHeight: 25,
                                      maxBoardLength: 19) == .held(maxBoardLength: 19))
    }

    @Test func aBoardExactlyTheSizeOfTheBufferFits() {
        #expect(EngineHeldRule.decide(current: .ready,
                                      boardWidth: 19,
                                      boardHeight: 19,
                                      maxBoardLength: 19) == .ready)
    }

    /// The reported number is the RUNNING engine's cap, because that is what
    /// the user has to change to get their board back.
    @Test func theHoldNamesTheCapThatCausedIt() {
        #expect(EngineHeldRule.decide(current: .ready,
                                      boardWidth: 21,
                                      boardHeight: 21,
                                      maxBoardLength: 13) == .held(maxBoardLength: 13))
    }

    // MARK: - Leaving the hold

    @Test func aBoardThatFitsAgainReleasesTheHold() {
        #expect(EngineHeldRule.decide(current: .held(maxBoardLength: 19),
                                      boardWidth: 9,
                                      boardHeight: 9,
                                      maxBoardLength: 19) == .ready)
    }

    /// A relaunch with a bigger buffer releases the hold on the same board.
    @Test func aBiggerBufferReleasesTheHold() {
        #expect(EngineHeldRule.decide(current: .held(maxBoardLength: 19),
                                      boardWidth: 37,
                                      boardHeight: 37,
                                      maxBoardLength: 37) == .ready)
    }

    /// No game selected is "nothing to measure", not "too large" — otherwise
    /// deselecting would hold an engine that is perfectly able to work.
    @Test func noGameSelectedIsNotTooLarge() {
        #expect(EngineHeldRule.decide(current: .ready,
                                      boardWidth: 0,
                                      boardHeight: 0,
                                      maxBoardLength: 19) == .ready)
        #expect(EngineHeldRule.decide(current: .held(maxBoardLength: 19),
                                      boardWidth: 0,
                                      boardHeight: 0,
                                      maxBoardLength: 19) == .ready)
    }

    // MARK: - The states a board size may never overwrite

    @Test func aLaunchingEngineIsNeverHeld() {
        #expect(EngineHeldRule.decide(current: .launching,
                                      boardWidth: 37,
                                      boardHeight: 37,
                                      maxBoardLength: 19) == .launching)
    }

    @Test func aFailedEngineIsNeverHeld() {
        let failed = EngineAvailability.failed(reason: "The engine stopped.")
        #expect(EngineHeldRule.decide(current: failed,
                                      boardWidth: 37,
                                      boardHeight: 37,
                                      maxBoardLength: 19) == failed)
    }

    @Test func anAbsentEngineIsNeverHeld() {
        #expect(EngineHeldRule.decide(current: .absent,
                                      boardWidth: 37,
                                      boardHeight: 37,
                                      maxBoardLength: 19) == .absent)
    }

    /// Idempotent, which is what lets a host re-apply it from an observer that
    /// its own write re-fires: the second pass must not move.
    @Test func reApplyingTheRuleDoesNotMove() {
        let first = EngineHeldRule.decide(current: .ready,
                                          boardWidth: 37,
                                          boardHeight: 37,
                                          maxBoardLength: 19)
        let second = EngineHeldRule.decide(current: first,
                                           boardWidth: 37,
                                           boardHeight: 37,
                                           maxBoardLength: 19)
        #expect(first == second)
    }
}
