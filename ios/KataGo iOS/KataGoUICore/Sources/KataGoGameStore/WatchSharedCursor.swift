import Foundation
import Observation

/// State machine for the v1.1 shared cursor: the Crown proposes a host
/// mainline index; after a debounce the target is sent to the iPhone; the
/// cursor then waits for a snapshot whose hostMoveIndex confirms it (or a
/// timeout). Pure transitions — the watch app owns the actual timers and
/// WCSession traffic — so this is unit-testable off-device.
@Observable
@MainActor
public final class WatchSharedCursor {
    /// Crown settle time before a goTo is sent.
    public static let debounce: TimeInterval = 0.3
    /// How long a sent goTo may wait for its confirming frame.
    public static let confirmTimeout: TimeInterval = 5.0

    // Named `Verdict`, not `Observation`: a nested type named `Observation`
    // inside an `@Observable` class collides with the `Observation` module
    // that the macro's generated code references unqualified (the nested
    // type shadows the module in lookup), which fails to compile.
    public enum Verdict: Equatable, Sendable {
        case confirmed, waiting, timedOut
    }

    private enum Phase: Equatable {
        case idle
        case debouncing(target: Int)
        case awaitingConfirm(target: Int, sentAt: Date)
    }
    private var phase: Phase = .idle

    public init() {}

    public var pendingTarget: Int? {
        switch phase {
        case .idle: return nil
        case .debouncing(let t), .awaitingConfirm(let t, _): return t
        }
    }

    /// Crown moved. Returns true when the caller should (re)start its
    /// debounce timer (a repeat of the same debouncing target does not).
    public func propose(target: Int) -> Bool {
        if case .debouncing(let t) = phase, t == target { return false }
        phase = .debouncing(target: target)
        return true
    }

    /// Debounce fired: the target to send now, or nil if superseded/absent.
    /// Moves to awaitingConfirm.
    public func takeDue(now: Date) -> Int? {
        guard case .debouncing(let target) = phase else { return nil }
        phase = .awaitingConfirm(target: target, sentAt: now)
        return target
    }

    /// A snapshot frame arrived (or the clock ticked). nil = nothing pending.
    public func observe(hostIndex: Int?, now: Date) -> Verdict? {
        guard case .awaitingConfirm(let target, let sentAt) = phase else {
            if case .debouncing = phase { return .waiting }
            return nil
        }
        if hostIndex == target { phase = .idle; return .confirmed }
        if now.timeIntervalSince(sentAt) > Self.confirmTimeout { phase = .idle; return .timedOut }
        return .waiting
    }

    /// Rejection or transport failure: forget the pending target.
    public func abandon() { phase = .idle }
}
