//
//  TVAutoPlayPolicy.swift
//  KataGoUICore
//
//  The per-tick decision for TVReviewScreen's Auto-Play, kept pure so the whole
//  truth table is unit-testable from the iOS test host (the SelfPlayAttract
//  precedent). The TV screen owns only the Task loop that asks this what to do.
//

import Foundation

/// Why the POLICY stopped a running Auto-Play. Deliberately only the two
/// reasons the policy itself can detect: reaching the end is reported through
/// `TVAutoPlayTick.finish`, and the user-driven stops (a timeline step, a pick,
/// aiming, leaving the screen) never go through `tick` at all — the screen calls
/// its stop directly. Adding cases the policy cannot return would be dead code.
public enum TVAutoPlayStopReason: Equatable, Sendable {
    /// A variation is active — the mainline is what replays.
    case branchActive
    /// Thermal pressure on a fanless box.
    case thermal
}

public enum TVAutoPlayTick: Equatable, Sendable {
    /// Step exactly one recorded move forward.
    case advance
    /// Skip this tick: the previous move's board refresh is still in flight.
    case hold
    /// No recorded move is left. `continuesLive` is true only when the recorded
    /// game had NOT already ended, i.e. a live continuation is worth pushing.
    case finish(continuesLive: Bool)
    /// Stop for an interruption.
    case stop(TVAutoPlayStopReason)
}

public enum TVAutoPlayPolicy {
    /// How long the "Continuing live…" beat shows before the handoff push, so
    /// the screen change is announced rather than abrupt.
    public static let handoffBeatSeconds: Double = 2.0

    /// Decide what one Auto-Play tick should do.
    ///
    /// Order is load-bearing:
    /// 1. `isBranchActive` and thermal are hard stops that must not be masked
    ///    by an unsettled board.
    /// 2. `stonesReady` gates everything below it — including the end-of-game
    ///    test, because reporting the end while a move is still landing would
    ///    hand off from a position the engine has not finished applying.
    /// 3. `hasNextMove` is checked BEFORE any call to `forwardMoves`: at the end
    ///    of a game that call executes zero moves but still emits `showboard`
    ///    plus a kata-analyze restart, so a driver that leaned on it being a
    ///    no-op would spam GTP forever.
    public static func tick(hasNextMove: Bool,
                            isBranchActive: Bool,
                            stonesReady: Bool,
                            recordedGameIsFinished: Bool,
                            thermalState: ProcessInfo.ThermalState) -> TVAutoPlayTick {
        if isBranchActive { return .stop(.branchActive) }
        if SelfPlayAttract.shouldStop(thermalState: thermalState) { return .stop(.thermal) }
        guard stonesReady else { return .hold }
        guard hasNextMove else { return .finish(continuesLive: !recordedGameIsFinished) }
        return .advance
    }
}
