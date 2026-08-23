//
//  RecoveryDecisionTests.swift
//  KataGo AnytimeTests
//
//  Pins the launch-time recovery contract now that the board never waits for
//  the engine. The decision has four outcomes, and each of them describes a
//  DIFFERENT thing the board shows on its first frame:
//
//    • DEBUG                     -> `.presentPicker`      (board + Absent + sheet)
//    • Release, sentinel armed   -> `.failedLastLaunch`   (board + Failed + Choose model)
//    • Release, title persisted  -> `.autoRestore(title)` (board + Launching)
//    • Release, nothing persisted-> `.autoRestore(builtIn)` — Absent is never
//      shown on Release, so "no choice yet" launches the built-in net rather
//      than asking a question the release build has no screen for.
//
//  Split out of `EngineLifecycleTests` (which keeps the `EngineLifecycle`
//  signal itself) because the two now answer different questions.
//

import Testing
@testable import KataGoUICore

struct RecoveryDecisionTests {
    private let builtIn = "Built-in KataGo Network"
    private let official = "Official KataGo Network"

    @Test func debugPresentsThePicker() {
        // DEBUG is checked FIRST, before the sentinel: the debug build's rule
        // is "always ask", and the nine UI suites depend on the sheet coming up
        // however the previous launch died. A sentinel that survived into a
        // debug launch still gets the picker, exactly as it did before.
        #expect(RecoveryDecision.decide(pendingLoadModelTitle: "",
                                        selectedModelTitle: official,
                                        isDebug: true,
                                        builtInTitle: builtIn) == .presentPicker)
        #expect(RecoveryDecision.decide(pendingLoadModelTitle: official,
                                        selectedModelTitle: official,
                                        isDebug: true,
                                        builtInTitle: builtIn) == .presentPicker)
    }

    @Test func aSurvivingSentinelIsAFailedLaunch() {
        // The previous launch armed the sentinel and never cleared it, i.e. it
        // died between "start loading" and the engine's first GTP reply. Never
        // auto-restore that net — that is how a crash loop is built. Release
        // says so out loud now, instead of silently showing a picker.
        #expect(RecoveryDecision.decide(pendingLoadModelTitle: official,
                                        selectedModelTitle: builtIn,
                                        isDebug: false,
                                        builtInTitle: builtIn)
                == .failedLastLaunch(title: official))
    }

    @Test func aPersistedTitleAutoRestores() {
        #expect(RecoveryDecision.decide(pendingLoadModelTitle: "",
                                        selectedModelTitle: official,
                                        isDebug: false,
                                        builtInTitle: builtIn)
                == .autoRestore(title: official))
    }

    @Test func noPersistedTitleLaunchesTheBuiltIn() {
        // The fresh-install Release path. Absent is never shown on Release, so
        // there is a net to launch even when the user has never chosen one.
        #expect(RecoveryDecision.decide(pendingLoadModelTitle: "",
                                        selectedModelTitle: "",
                                        isDebug: false,
                                        builtInTitle: builtIn)
                == .autoRestore(title: builtIn))
    }
}
