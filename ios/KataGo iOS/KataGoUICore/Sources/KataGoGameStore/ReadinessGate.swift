import Foundation

/// Defers an action until a subsystem signals it is ready, so the action never
/// runs against a not-yet-ready dependency.
///
/// It was written for the macOS engine handshake and is now used for two
/// things: the macOS window controller defers a game selection while a Deep
/// Report is probing (an external trigger must not interleave a feed with the
/// report's `kata-analyze` traffic), and `GobanState.engineSyncGate` remembers
/// that a position change could not be sent because no engine was accepting
/// commands. In both cases the gate stashes the payload; the caller drains it
/// once readiness is signalled, and the newest request wins.
///
/// Generic over `Payload` so the pure defer/drain logic is unit-testable with a
/// trivial value type while the macOS app uses it with a game-selection payload.
public struct ReadinessGate<Payload> {
    /// The payload awaiting a ready signal, if any. Last request wins: a newer
    /// request supersedes an older deferred one.
    public private(set) var pending: Payload?

    public init() {}

    /// Returns `payload` to act on NOW when `isReady`, or `nil` when the request
    /// was deferred — stashed in `pending` for a later `drainWhenReady()`.
    public mutating func request(_ payload: Payload, isReady: Bool) -> Payload? {
        if isReady {
            pending = nil   // drop any stale deferred request; this one wins
            return payload
        }
        pending = payload
        return nil
    }

    /// The subsystem became ready. Returns the deferred payload to act on now
    /// (if any) and clears it so a later readiness cycle can't replay it.
    public mutating func drainWhenReady() -> Payload? {
        defer { pending = nil }
        return pending
    }
}
