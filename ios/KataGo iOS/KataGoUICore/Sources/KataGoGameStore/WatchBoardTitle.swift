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
    ///   2. `→ 5/50`    — a scrub is waiting on the phone to confirm
    ///   3. `3/50`      — cursor mode, parked behind the host's position
    ///   4. `3 behind`  — ring mode, parked behind the newest frame received
    ///   5. `Live`
    ///
    /// Staleness outranks a pending scrub deliberately. `WatchLiveModel.scrub`
    /// gates on `sharedCursorAvailable` (`!isStale && isReachable`), so a
    /// pending target can survive INTO a stale state but can never be created
    /// in one — and once the phone is unreachable it will never be confirmed.
    /// Reporting `→ 5/50` there would promise an arrival that cannot happen.
    public static func live(stale: Bool,
                            pendingTarget: Int?,
                            hostMoveIndex: Int?,
                            hostMoveCount: Int?,
                            sharedCursorAvailable: Bool,
                            movesBehindLive: Int) -> String {
        if stale { return "Offline" }
        if let pendingTarget { return "→ \(pendingTarget)/\(hostMoveCount ?? 0)" }
        if sharedCursorAvailable {
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
