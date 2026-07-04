import Testing
import Foundation
@testable import KataGoGameStore

@MainActor
struct WatchSharedCursorTests {
    let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func proposeDebouncesAndSendsOnce() {
        let cursor = WatchSharedCursor()
        #expect(cursor.propose(target: 40))          // schedule
        #expect(cursor.propose(target: 39))          // retarget → reschedule
        #expect(!cursor.propose(target: 39))         // same target → no reschedule
        #expect(cursor.pendingTarget == 39)
        #expect(cursor.takeDue(now: t0) == 39)       // debounce fired → send 39
        #expect(cursor.takeDue(now: t0) == nil)      // nothing else due
        #expect(cursor.pendingTarget == 39)          // still pending (awaiting confirm)
    }

    @Test func frameWithTargetIndexConfirms() {
        let cursor = WatchSharedCursor()
        _ = cursor.propose(target: 12)
        _ = cursor.takeDue(now: t0)
        #expect(cursor.observe(hostIndex: 11, now: t0 + 1) == .waiting)
        #expect(cursor.observe(hostIndex: 12, now: t0 + 2) == .confirmed)
        #expect(cursor.pendingTarget == nil)
        #expect(cursor.observe(hostIndex: 12, now: t0 + 3) == nil)   // idle: nothing pending
    }

    @Test func silenceTimesOut() {
        let cursor = WatchSharedCursor()
        _ = cursor.propose(target: 12)
        _ = cursor.takeDue(now: t0)
        #expect(cursor.observe(hostIndex: 3, now: t0 + WatchSharedCursor.confirmTimeout + 1) == .timedOut)
        #expect(cursor.pendingTarget == nil)
    }

    @Test func abandonClearsPendingState() {
        let cursor = WatchSharedCursor()
        _ = cursor.propose(target: 12)
        cursor.abandon()
        #expect(cursor.pendingTarget == nil)
        #expect(cursor.takeDue(now: t0) == nil)
    }

    @Test func retargetWhileAwaitingConfirmSupersedes() {
        let cursor = WatchSharedCursor()
        _ = cursor.propose(target: 12)
        _ = cursor.takeDue(now: t0)
        #expect(cursor.propose(target: 8))           // crown kept turning
        #expect(cursor.takeDue(now: t0 + 1) == 8)
        // The old target's confirmation no longer matters:
        #expect(cursor.observe(hostIndex: 12, now: t0 + 2) == .waiting)
        #expect(cursor.observe(hostIndex: 8, now: t0 + 2) == .confirmed)
    }

    @Test func peekBufferLooksUpByHostIndex() {
        let buffer = WatchPeekBuffer()
        var a = WatchSnapshotTests.makeSnapshot()
        a.hostMoveIndex = 3
        var b = WatchSnapshotTests.makeSnapshot()
        b.blackStones.append("K10")
        b.hostMoveIndex = 4
        buffer.ingest(a); buffer.ingest(b)
        #expect(buffer.entry(forHostIndex: 3)?.hostMoveIndex == 3)
        #expect(buffer.entry(forHostIndex: 4)?.hostMoveIndex == 4)
        #expect(buffer.entry(forHostIndex: 9) == nil)
    }
}
