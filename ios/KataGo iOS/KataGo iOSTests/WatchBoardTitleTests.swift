import Testing
@testable import KataGoGameStore

struct WatchBoardTitleTests {
    /// Every argument that is not under test held at its healthy, at-the-head
    /// value, so each test varies exactly one thing.
    private func live(stale: Bool = false,
                      pendingTarget: Int? = nil,
                      hostMoveIndex: Int? = 50,
                      hostMoveCount: Int? = 50,
                      sharedCursorAvailable: Bool = true,
                      movesBehindLive: Int = 0) -> String {
        WatchBoardTitle.live(stale: stale,
                             pendingTarget: pendingTarget,
                             hostMoveIndex: hostMoveIndex,
                             hostMoveCount: hostMoveCount,
                             sharedCursorAvailable: sharedCursorAvailable,
                             movesBehindLive: movesBehindLive)
    }

    @Test func atTheHostsPositionItSaysLive() {
        #expect(live() == "Live")
    }

    @Test func cursorModeParkedBehindReportsThePosition() {
        #expect(live(hostMoveIndex: 3, hostMoveCount: 50) == "3/50")
    }

    @Test func pendingScrubReportsItsTarget() {
        #expect(live(pendingTarget: 5, hostMoveIndex: 3, hostMoveCount: 50) == "→ 5/50")
    }

    /// Staleness outranks a pending scrub: `WatchLiveModel.scrub` gates on
    /// `sharedCursorAvailable`, so a pending target can survive INTO a stale
    /// state but never be created in one, and it will never be confirmed.
    @Test func staleBeatsAPendingScrub() {
        #expect(live(stale: true, pendingTarget: 5,
                     hostMoveIndex: 3, hostMoveCount: 50) == "Offline")
    }

    @Test func staleBeatsEveryOtherState() {
        #expect(live(stale: true) == "Offline")
        #expect(live(stale: true, hostMoveIndex: 3, hostMoveCount: 50) == "Offline")
        #expect(live(stale: true, sharedCursorAvailable: false,
                     movesBehindLive: 3) == "Offline")
    }

    @Test func ringModeCountsMovesBehind() {
        #expect(live(sharedCursorAvailable: false, movesBehindLive: 3) == "3 behind")
    }

    @Test func ringModeAtTheNewestFrameSaysLive() {
        #expect(live(sharedCursorAvailable: false, movesBehindLive: 0) == "Live")
    }

    /// A v0 phone sends no host cursor at all. Cursor mode must not print
    /// "nil/nil" or fabricate a position.
    @Test func cursorModeWithoutAHostCursorSaysLive() {
        #expect(live(hostMoveIndex: nil, hostMoveCount: nil) == "Live")
    }

    @Test func storedShowsTheCounterOnlyWhileScrubbing() {
        #expect(WatchBoardTitle.stored(name: "Sanren-sei", index: 3, count: 50,
                                       showsCounter: true) == "3/50")
        #expect(WatchBoardTitle.stored(name: "Sanren-sei", index: 3, count: 50,
                                       showsCounter: false) == "Sanren-sei")
    }
}
