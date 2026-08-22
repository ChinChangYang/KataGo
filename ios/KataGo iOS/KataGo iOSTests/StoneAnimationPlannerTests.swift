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

    // MARK: - Sound cues

    @Test func flyInCuesSoundAtLanding() {
        #expect(StoneAnimationPlanner.soundCue(effect: .flyIn(p),
                                               additions: 1,
                                               removals: 0,
                                               isInitialSync: false) == .playAfterFlyIn)
    }

    @Test func flyInCuesSoundEvenOnInitialSync() {
        // An intent that survives into the first sync is a real move —
        // the sound follows the animation, not the mount flag.
        #expect(StoneAnimationPlanner.soundCue(effect: .flyIn(p),
                                               additions: 1,
                                               removals: 0,
                                               isInitialSync: true) == .playAfterFlyIn)
    }

    @Test func flyAwayIsSilent() {
        // A stone leaving the board is not a stone hitting it (user
        // feedback: the undo fly-off should make no sound).
        #expect(StoneAnimationPlanner.soundCue(effect: .flyAway(p),
                                               additions: 0,
                                               removals: 1,
                                               isInitialSync: false) == .none)
    }

    @Test func batchDiffCuesOneImmediateSound() {
        // L2/R2 bulk jump: stones changed, nothing animates.
        #expect(StoneAnimationPlanner.soundCue(effect: .none,
                                               additions: 7,
                                               removals: 2,
                                               isInitialSync: false) == .playImmediately)
    }

    @Test func removalOnlyBatchDiffCuesOneImmediateSound() {
        #expect(StoneAnimationPlanner.soundCue(effect: .none,
                                               additions: 0,
                                               removals: 5,
                                               isInitialSync: false) == .playImmediately)
    }

    @Test func initialMountStaysSilent() {
        // Boot, game switch, and board rebuild remounts are not moves.
        #expect(StoneAnimationPlanner.soundCue(effect: .none,
                                               additions: 42,
                                               removals: 0,
                                               isInitialSync: true) == .none)
    }

    @Test func emptyDiffStaysSilent() {
        #expect(StoneAnimationPlanner.soundCue(effect: .none,
                                               additions: 0,
                                               removals: 0,
                                               isInitialSync: false) == .none)
        #expect(StoneAnimationPlanner.soundCue(effect: .none,
                                               additions: 0,
                                               removals: 0,
                                               isInitialSync: true) == .none)
    }

    // MARK: - Capture cues

    @Test func capturingMoveRattlesAtLanding() {
        // The reported bug: a played capture must rattle when the stone
        // seats, not when showboard's counter moves a flight earlier.
        #expect(StoneAnimationPlanner.captureCue(effect: .flyIn(p),
                                                 additions: 1,
                                                 removals: 3) == .atLanding)
    }

    @Test func batchDiffRattlesImmediately() {
        // R2 jump across a capturing move: nothing is in the air, so there
        // is no landing to wait for.
        #expect(StoneAnimationPlanner.captureCue(effect: .none,
                                                 additions: 7,
                                                 removals: 2) == .immediately)
    }

    @Test func remountRattlesImmediatelyRatherThanStayingSilent() {
        // Unlike the click, a boot/switch remount into a game whose capture
        // count rises DOES rattle — a standing user decision, not an
        // oversight. Only its timing ever needed fixing.
        #expect(StoneAnimationPlanner.captureCue(effect: .none,
                                                 additions: 42,
                                                 removals: 0) == .immediately)
    }

    @Test func flyAwayDiffRattlesImmediately() {
        // An undo lowers the counters, so this cue is only a floor — it
        // must never be .atLanding, whose deadline belongs to a fly-in.
        #expect(StoneAnimationPlanner.captureCue(effect: .flyAway(p),
                                                 additions: 0,
                                                 removals: 1) == .immediately)
    }

    // MARK: - Record-owned display

    @Test func recordDrivenDiffWhileNotReadyStillRenders() {
        // The board is record-owned: the stone diff now arrives with the
        // `printsgf` reply, BEFORE the engine's showboard acknowledgement — so
        // while `stones.isReady` is still false. The planner must resolve it
        // exactly as before (it has no notion of readiness, and must not grow
        // one): the stone flies in and clicks on landing.
        var planner = StoneAnimationPlanner()
        planner.expect(.place(p))

        let effect = planner.resolve(additions: [p], removals: [])
        #expect(effect == .flyIn(p))
        #expect(StoneAnimationPlanner.soundCue(effect: effect,
                                               additions: 1,
                                               removals: 0,
                                               isInitialSync: false) == .playAfterFlyIn)
    }

    @Test func playThenAckThenRecordSequence() {
        // One played move, in the order the new command sequence produces it:
        // the play site queues the intent, the record update draws the stone,
        // and the LATER showboard acknowledgement re-syncs an unchanged board.
        // That trailing empty diff must neither re-click nor disturb the queue.
        var planner = StoneAnimationPlanner()
        planner.expect(.place(p))

        #expect(planner.resolve(additions: [p], removals: []) == .flyIn(p))
        #expect(planner.pending.isEmpty)

        let ackEffect = planner.resolve(additions: [], removals: [])
        #expect(ackEffect == .none)
        #expect(planner.pending.isEmpty)
        #expect(StoneAnimationPlanner.soundCue(effect: ackEffect,
                                               additions: 0,
                                               removals: 0,
                                               isInitialSync: false) == .none)
        #expect(StoneAnimationPlanner.captureCue(effect: ackEffect,
                                                 additions: 0,
                                                 removals: 0) == nil)
    }

    @Test func emptyDiffLeavesThePreviousCaptureCueStanding() {
        // showboard writes the stone lists before its "B/W stones captured"
        // lines, so the counter can be observed on a later, empty sync of
        // the same block. nil = keep the capturing diff's cue.
        #expect(StoneAnimationPlanner.captureCue(effect: .none,
                                                 additions: 0,
                                                 removals: 0) == nil)
        #expect(StoneAnimationPlanner.captureCue(effect: .flyIn(p),
                                                 additions: 0,
                                                 removals: 0) == nil)
    }
}
