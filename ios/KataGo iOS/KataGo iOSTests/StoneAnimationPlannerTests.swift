//
//  StoneAnimationPlannerTests.swift
//  KataGo AnytimeTests
//

import Foundation
import Testing
@testable import KataGoUICore

struct StoneAnimationPlannerTests {
    private let p = BoardPoint(x: 3, y: 3)
    private let a = BoardPoint(x: 5, y: 5)
    private let b = BoardPoint(x: 6, y: 5)

    @Test func emptyDiffIsNoneAndKeepsQueue() {
        var planner = StoneAnimationPlanner()
        planner.expect(.place(p))

        // An illegal move's showboard echo changes nothing on the board.
        #expect(planner.resolve(additions: [], removals: []) == .none)
        #expect(planner.pending == [.place(p)])
    }

    @Test func placeIntentMatchingAdditionFliesInAndConsumes() {
        var planner = StoneAnimationPlanner()
        planner.expect(.place(p))

        #expect(planner.resolve(additions: [p], removals: []) == .flyIn(p))
        #expect(planner.pending.isEmpty)
    }

    @Test func removeIntentMatchingRemovalFliesAwayAndConsumes() {
        var planner = StoneAnimationPlanner()
        planner.expect(.remove(p))

        #expect(planner.resolve(additions: [], removals: [p]) == .flyAway(p))
        #expect(planner.pending.isEmpty)
    }

    @Test func captureDiffAnimatesOnlyThePlayedStone() {
        var planner = StoneAnimationPlanner()
        planner.expect(.place(p))

        // A play at p capturing a and b: only p flies in.
        #expect(planner.resolve(additions: [p], removals: [a, b]) == .flyIn(p))
        #expect(planner.pending.isEmpty)
    }

    @Test func undoRestoreDiffAnimatesOnlyTheTip() {
        var planner = StoneAnimationPlanner()
        planner.expect(.remove(p))

        // Undoing the capture at p restores a and b: only p flies away.
        #expect(planner.resolve(additions: [a, b], removals: [p]) == .flyAway(p))
        #expect(planner.pending.isEmpty)
    }

    @Test func fifoOrderUnderAutoRepeat() {
        var planner = StoneAnimationPlanner()
        // Two held-L1 undo presses land before the first showboard reply.
        planner.expect(.remove(p))
        planner.expect(.remove(a))

        #expect(planner.resolve(additions: [], removals: [p]) == .flyAway(p))
        #expect(planner.pending == [.remove(a)])
        #expect(planner.resolve(additions: [], removals: [a]) == .flyAway(a))
        #expect(planner.pending.isEmpty)
    }

    @Test func stalePrefixDroppedOnLaterMatch() {
        var planner = StoneAnimationPlanner()
        // The place at a never produced a diff (rejected move); the later
        // undo must still animate and scavenge the stale intent.
        planner.expect(.place(a))
        planner.expect(.remove(p))

        #expect(planner.resolve(additions: [], removals: [p]) == .flyAway(p))
        #expect(planner.pending.isEmpty)
    }

    @Test func unmatchedBatchDiffClearsQueue() {
        var planner = StoneAnimationPlanner()
        planner.expect(.place(p))

        // A game switch re-diffs the whole board; nothing matches.
        #expect(planner.resolve(additions: [a, b], removals: []) == .none)
        #expect(planner.pending.isEmpty)
    }

    @Test func clearEmptiesQueue() {
        var planner = StoneAnimationPlanner()
        planner.expect(.place(p))
        planner.expect(.remove(a))
        planner.clear()
        #expect(planner.pending.isEmpty)
    }

    @Test func capacityDropsOldest() {
        var planner = StoneAnimationPlanner()
        for x in 0..<10 {
            planner.expect(.place(BoardPoint(x: x, y: 0)))
        }
        #expect(planner.pending.count == 8)
        #expect(planner.pending.first == .place(BoardPoint(x: 2, y: 0)))
        #expect(planner.pending.last == .place(BoardPoint(x: 9, y: 0)))
    }

    @Test func koRecaptureAlternationResolvesInOrder() {
        var planner = StoneAnimationPlanner()
        // Ko: play at p captures a; opponent recaptures at a, removing p.
        planner.expect(.place(p))
        #expect(planner.resolve(additions: [p], removals: [a]) == .flyIn(p))
        planner.expect(.place(a))
        #expect(planner.resolve(additions: [a], removals: [p]) == .flyIn(a))
        #expect(planner.pending.isEmpty)
    }

    @Test func newestMatchWinsOverStaleOlderIntent() {
        var planner = StoneAnimationPlanner()
        // A rejected ko attempt left .place(a) queued; the next undo's diff
        // restores the capture at a while removing the tip p. The newer
        // .remove must win — the restore mounts instantly.
        planner.expect(.place(a))
        planner.expect(.remove(p))

        #expect(planner.resolve(additions: [a], removals: [p]) == .flyAway(p))
        #expect(planner.pending.isEmpty)
    }

    @Test func retractRemovesTheMostRecentMatchingIntent() {
        var planner = StoneAnimationPlanner()
        planner.expect(.place(p))
        planner.expect(.remove(p))
        planner.retract(.place(p))
        #expect(planner.pending == [.remove(p)])

        // Retracting something not queued is a no-op.
        planner.retract(.place(a))
        #expect(planner.pending == [.remove(p)])
    }

    @Test func undoThenReplaySamePoint() {
        var planner = StoneAnimationPlanner()
        planner.expect(.remove(p))
        planner.expect(.place(p))

        #expect(planner.resolve(additions: [], removals: [p]) == .flyAway(p))
        #expect(planner.resolve(additions: [p], removals: []) == .flyIn(p))
        #expect(planner.pending.isEmpty)
    }
}
