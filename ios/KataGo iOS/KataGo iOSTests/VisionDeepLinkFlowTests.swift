//
//  VisionDeepLinkFlowTests.swift
//  KataGo AnytimeTests
//
//  A widget tap on visionOS waits for ONE thing: a resolved selection. It used
//  to wait for the engine too — which meant a tap during a multi-minute Core ML
//  compile sat latched until the handshake landed. The board no longer waits for
//  the engine, so neither does a link to it.
//

import Testing
import KataGoUICore

struct VisionDeepLinkFlowTests {
    @Test func noPendingLinkIsNothingPendingEitherWay() {
        // Both drain sites call this unconditionally (the onChange, and the
        // post-boot drain), so "no link" must be inert in both states.
        for hasResolvedSelection in [false, true] {
            #expect(VisionDeepLinkFlow.disposition(
                hasPending: false,
                hasResolvedSelection: hasResolvedSelection) == .nothingPending)
        }
    }

    @Test func linkDuringEngineLaunchAppliesOnceSelectionExists() {
        // The boot mounts a game BEFORE the handshake, so by the time the model
        // is compiling there is a selection — and the tap must land on the board
        // at once rather than waiting minutes for an engine it does not need.
        #expect(VisionDeepLinkFlow.disposition(
            hasPending: true, hasResolvedSelection: true) == .apply)
    }

    @Test func linkBeforeSelectionResolvedStaysLatched() {
        // The one genuine wait: the very first frames of a cold launch, before
        // `resolveAndMountCurrentGame` has picked a record. The resolver itself
        // consumes the latch (a widget tap overrides the default selection), so
        // applying it here would race that consumption.
        #expect(VisionDeepLinkFlow.disposition(
            hasPending: true, hasResolvedSelection: false) == .keepLatched)
    }
}
