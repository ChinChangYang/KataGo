//
//  WatchBoardTitle.swift
//  KataGoGameStore
//
//  What the board page's navigation title says.
//
//  The watch board fills its whole page, so the title is the only chrome left
//  that can report status without covering stones — and after this change it is
//  the ONLY thing reporting it. That is why the precedence lives here, in one
//  testable place, rather than inline in a view: the watch target has no test
//  bundle, so a rule spelled out there cannot be tested at all.
//

import Foundation

public enum WatchBoardTitle {
    /// The live mirror's title. Precedence, highest first:
    ///
    ///   1. `Offline`   — the phone has stopped sending frames
    ///   2. cursor mode (`sharedCursorAvailable`):
    ///      a. `→ 5/50`    — a scrub is waiting on the phone to confirm
    ///      b. `3/50`      — parked behind the host's position
    ///      c. `Live`
    ///   3. ring mode:
    ///      a. `3 behind`  — parked behind the newest frame received
    ///      b. `Live`
    ///
    /// Staleness outranks a pending scrub deliberately. `WatchLiveModel.scrub`
    /// gates on `sharedCursorAvailable` (`!isStale && isReachable`), so a
    /// pending target can survive INTO a stale state but can never be created
    /// in one — and once the phone is unreachable it will never be confirmed.
    /// Reporting `→ 5/50` there would promise an arrival that cannot happen.
    ///
    /// The pending-target branch is nested inside `sharedCursorAvailable` for
    /// a related reason: `pendingTarget` is phase-derived (`WatchSharedCursor`)
    /// and is cleared only by confirmation or a 5s timeout, so it can outlive
    /// a reachability drop for up to that timeout — leaving `stale == false`,
    /// `sharedCursorAvailable == false`, and a stale `pendingTarget` all true
    /// at once. In that state the board renders RING mode (it selects
    /// `peek.current`, not the host cursor frame), so reporting the pending
    /// target would print a host-mainline index beside a ring-buffer board:
    /// two different coordinate spaces. The on-board pill this title replaces
    /// nested its own pending-target branch inside the same cursor-mode check.
    public static func live(stale: Bool,
                            pendingTarget: Int?,
                            hostMoveIndex: Int?,
                            hostMoveCount: Int?,
                            sharedCursorAvailable: Bool,
                            movesBehindLive: Int) -> String {
        if stale { return "Offline" }
        if sharedCursorAvailable {
            if let pendingTarget { return "→ \(pendingTarget)/\(hostMoveCount ?? 0)" }
            // A pre-v1.1 phone sends no cursor at all, so an absent index is
            // "no position to report", not "position zero".
            guard let hostMoveIndex, let hostMoveCount,
                  hostMoveIndex < hostMoveCount else { return "Live" }
            return "\(hostMoveIndex)/\(hostMoveCount)"
        }
        return movesBehindLive > 0 ? "\(movesBehindLive) behind" : "Live"
    }

    /// A stored game's title: the scrub counter while the Crown is moving, the
    /// game's name once it settles.
    public static func stored(name: String, index: Int, count: Int,
                              showsCounter: Bool) -> String {
        showsCounter ? "\(index)/\(count)" : name
    }
}
