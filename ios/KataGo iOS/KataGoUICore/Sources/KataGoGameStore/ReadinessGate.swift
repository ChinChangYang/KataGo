import Foundation

/// Defers an action until a subsystem signals it is ready, so the action never
/// runs against a not-yet-ready dependency.
///
/// On macOS the KataGo engine is a subprocess that finishes its GTP handshake
/// asynchronously. A cold launch can deliver a game selection — via a widget
/// `katago-anytime://` deep link (F14) OR an `.sgf` file-open from Finder (F14b)
/// — before `boardReadiness.isEngineReady` flips true, and the resulting
/// `loadsgf`/rule/`kata-analyze` commands would be sent to a not-yet-ready
/// engine and dropped. The gate stashes the payload until the subsystem is
/// ready; the caller drains it once readiness is signalled.
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
