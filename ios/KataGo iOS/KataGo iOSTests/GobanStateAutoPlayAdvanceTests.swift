//
//  GobanStateAutoPlayAdvanceTests.swift
//  KataGo iOSTests
//
//  Pins the auto-play replay advance protocol that fixes "auto play randomly
//  misses stones": the play site records the absolute index the board will be
//  at once its showboard round-trips (recordAutoPlayStep), and the advance
//  site ASSIGNS that target (autoPlayAdvancedIndex) instead of incrementing —
//  so a spurious stones.isReady edge (the "? illegal move" reply of a raced
//  duplicate play arrives via resetPendingStatesOnError) can no longer
//  advance currentIndex twice and silently skip an SGF move's `play`.
//  Also pins the showBoardCount clamp: one stray showboard response must not
//  wedge every future board parse (the count must never go negative).
//

import Testing
@testable import KataGoUICore

@MainActor
struct GobanStateAutoPlayAdvanceTests {

    @Test("A recorded step advances to its absolute target")
    func normalStepAdvancesToTarget() {
        let state = GobanState()
        state.recordAutoPlayStep(nextIndex: 6)
        #expect(state.autoPlayAdvancedIndex() == 6)
    }

    @Test("A doubled isReady edge is idempotent — never target+1")
    func doubledEdgeIsIdempotent() {
        let state = GobanState()
        state.recordAutoPlayStep(nextIndex: 6)
        #expect(state.autoPlayAdvancedIndex() == 6)
        // Spurious second edge (error reset / duplicate showboard):
        // re-consuming the target yields the same index, never one more.
        #expect(state.autoPlayAdvancedIndex() == 6)
    }

    @Test("A raced duplicate play re-records the same target")
    func duplicateStalePlayKeepsTarget() {
        let state = GobanState()
        state.recordAutoPlayStep(nextIndex: 6)   // real play of move 5
        state.recordAutoPlayStep(nextIndex: 6)   // stale duplicate firing
        #expect(state.autoPlayAdvancedIndex() == 6)
        #expect(state.autoPlayAdvancedIndex() == 6)
    }

    @Test("Ordinary showboards (not auto-play) never advance")
    func ordinaryShowboardDoesNotAdvance() {
        let state = GobanState()
        #expect(state.autoPlayAdvancedIndex() == nil)
    }

    @Test("clearAutoPlayStep resets the flag and the target")
    func clearResetsBoth() {
        let state = GobanState()
        state.recordAutoPlayStep(nextIndex: 9)
        state.clearAutoPlayStep()
        #expect(state.isAutoPlayed == false)
        #expect(state.autoPlayTargetIndex == nil)
        #expect(state.autoPlayAdvancedIndex() == nil)
    }
}

@MainActor
struct GobanStateShowBoardCountClampTests {

    @Test("A stray response cannot wedge future board parses")
    func strayResponseDoesNotWedge() {
        let state = GobanState()
        #expect(state.showBoardCount == 0)
        // A stray "= MoveNum" reply with nothing outstanding parses as a
        // harmless fresh board (it describes the engine's real position)
        // instead of pushing the count negative.
        #expect(state.consumeShowBoardResponse(response: "= MoveNum: 3, B stones: 2") == true)
        #expect(state.showBoardCount == 0)

        // The next legitimate request/response pair must still parse.
        state.showBoardCount += 1  // sendShowBoardCommand's increment
        #expect(state.consumeShowBoardResponse(response: "= MoveNum: 4, B stones: 2") == true)
    }

    @Test("Coalescing of queued responses is unchanged")
    func balancedCoalescingUnchanged() {
        let state = GobanState()
        state.showBoardCount = 2  // two showboards queued
        #expect(state.consumeShowBoardResponse(response: "= MoveNum: 1, B stones: 1") == false)
        #expect(state.consumeShowBoardResponse(response: "= MoveNum: 1, B stones: 1") == true)
        #expect(state.showBoardCount == 0)
    }

    @Test("Non-board lines are ignored")
    func nonBoardLinesIgnored() {
        let state = GobanState()
        state.showBoardCount = 1
        #expect(state.consumeShowBoardResponse(response: "info move Q16 visits 100") == false)
        #expect(state.showBoardCount == 1)
    }
}
