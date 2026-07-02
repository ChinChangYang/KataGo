//
//  TVAttractMode.swift
//  KataGo Anytime TV
//
//  Idle attract mode: after the library sits untouched for a while, the
//  self-play demo starts on its own (any remote press exits it). tvOS has no
//  app-level idle API, so idleness is inferred from the signals the library
//  actually produces — focus movement between cards, navigation pushes/pops,
//  and scene-phase changes — each of which re-arms a trailing-edge countdown.
//
//  The eligibility decision itself is the pure SelfPlayAttract policy
//  (KataGoUICore, unit-tested); this controller only mirrors the live truth
//  (path emptiness, scene phase) that the policy needs, and re-checks it at
//  fire time — the state may have changed during the countdown.
//

import SwiftUI
import KataGoUICore

@MainActor
@Observable
final class TVAttractModeController {
    /// Mirrors of the root's live state, written by its onChange observers.
    /// Not observation-tracked: nothing renders from them.
    @ObservationIgnored var pathIsEmpty = true
    @ObservationIgnored var sceneIsActive = true

    /// Supplied by TVRootView: pushes the attract self-play route.
    @ObservationIgnored var startAttract: (() -> Void)?

    /// The idle countdown. CoalescedTrigger is trailing-edge — every
    /// `noteUserActivity()` cancels the pending fire and re-arms the full
    /// timeout, which is exactly "idle for N minutes".
    @ObservationIgnored private let idleTrigger =
        CoalescedTrigger(delay: SelfPlayAttract.idleTimeout)

    /// Any user interaction (or becoming eligible again) restarts the countdown.
    func noteUserActivity() {
        idleTrigger.schedule { [weak self] in
            guard let self else { return }
            guard SelfPlayAttract.shouldStart(pathIsEmpty: pathIsEmpty,
                                              sceneIsActive: sceneIsActive,
                                              thermalState: ProcessInfo.processInfo.thermalState,
                                              storeAvailable: TVSampleGameStore.isAvailable) else {
                return
            }
            startAttract?()
        }
    }

    /// Leaving the library (push) or losing the scene cancels the countdown.
    func disarm() {
        idleTrigger.cancel()
    }
}
