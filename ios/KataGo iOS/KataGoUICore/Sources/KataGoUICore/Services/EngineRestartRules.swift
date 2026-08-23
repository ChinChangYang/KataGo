//
//  EngineRestartRules.swift
//  KataGoUICore
//
//  The three decisions every in-process engine controller has to make while it
//  swaps one engine for another, as pure functions the test bundle can reach.
//  The controllers themselves live in app targets (iOS `AppEngineController`,
//  visionOS `VisionEngineController`, tvOS `TVEngineController`), which no test
//  bundle links — so a rule that stays inside one of them is a rule nothing can
//  pin, and every one of these has a failure mode that is invisible from the
//  outside: a restart wedged in `.stopping` forever, a Retry that is refused,
//  or an engine that comes up with nobody reading its replies.
//

import Foundation

public enum EngineRestartRules {
    /// Waits until `isSettled()` reports true, or gives up after `timeout`
    /// seconds. Returns whether it settled.
    ///
    /// POLLED on purpose. The obvious implementation — park on a
    /// `CheckedContinuation` and let the party that settles resume it — cannot
    /// be bounded: a continuation never observes cancellation, and wrapping it
    /// in a task group does not help, because a group awaits its remaining
    /// children after `cancelAll()`. One party that never settles would then
    /// hang the caller forever, which for a restart means no phase, no status
    /// and no Retry. `Task.sleep` DOES observe cancellation, so this shape is
    /// bounded twice over: by its own deadline and by the caller's.
    /// `@MainActor` because the state it polls is main-actor state (a read-loop
    /// park flag, an engine-thread flag), and a hop per poll would let those
    /// change between the check and the caller acting on the answer.
    @MainActor
    public static func untilSettled(timeout: Double,
                                    pollInterval: Duration,
                                    isSettled: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isSettled() {
            guard !Task.isCancelled, Date() < deadline else { return false }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return false
            }
        }
        return true
    }

    /// The phases a controller can be in, without its associated failure text.
    /// A shared vocabulary purely so `canRestart` can be pinned; each host keeps
    /// its own richer `Phase`.
    public enum PhaseKind: Equatable, Sendable {
        case idle, starting, running, stopping, failed
    }

    /// Whether a restart may begin.
    ///
    /// `.failed` is included deliberately: that is the status line's Retry
    /// button. Without it a failed launch would be terminal and the only way
    /// back would be to quit the app. `.starting`/`.stopping` are refused —
    /// interrupting an in-flight handshake breaks the bridge's sole-reader rule
    /// — and `.idle` means the boot has not run yet, which is not a restart.
    public static func canRestart(from kind: PhaseKind) -> Bool {
        switch kind {
        case .running, .failed: return true
        case .idle, .starting, .stopping: return false
        }
    }

    /// Whether a relaunch may BEGIN, given whether one is already in flight.
    ///
    /// The in-process controllers answer this with their `Phase` (`canRestart`
    /// above), which they move synchronously before awaiting anything. macOS
    /// has no such phase — `MainWindowController.relaunch(model:)` is a
    /// synchronous method that starts a `Task`, and it is reachable from three
    /// places that can fire while an earlier relaunch is still tearing down:
    /// the status line's Retry, the Models window's Play, and the toolbar
    /// dropdown. Two overlapping calls would run two
    /// `stopEngineAndSession()`/`startEngineAndSession()` pairs against ONE
    /// session — two `run()` loops on one transport, and an `engineProcess`
    /// replaced underneath the teardown that is still waiting on it.
    ///
    /// Rejected, not queued: the second caller's model would be the same net in
    /// the common case (Retry double-tapped), and the in-flight relaunch is
    /// already bringing an engine up. A genuinely different choice is one more
    /// click away once it lands.
    public static func shouldBeginRelaunch(isRelaunchInFlight: Bool) -> Bool {
        !isRelaunchInFlight
    }

    /// Whether a successful (re)start has to ARM the host's read loop, given the
    /// generation it is keyed on. Zero means no loop was ever started.
    ///
    /// This is the failure the rule exists for: when a BOOT handshake fails, the
    /// read loop is deliberately never armed (a reader would eat the retry's
    /// `version` reply) — so the Retry that follows has to arm it, or the
    /// replacement engine comes up healthy, the gate opens, the feed goes out,
    /// and NOTHING reads the replies. The board would never report in sync,
    /// plays would be refused and no analysis would ever arrive, while the
    /// status line said everything was fine.
    ///
    /// It must not re-key a loop that already exists: the host's `.task(id:)`
    /// would cancel the parked reader instead of resuming it.
    public static func shouldArmReadLoop(generation: Int) -> Bool {
        generation == 0
    }
}
