//
//  AppEngineControllerTests.swift
//  KataGo AnytimeTests
//
//  The decisions `AppEngineController` makes, tested where they are decidable:
//  as pure functions. The controller's other half — spawn, quit, park the read
//  loop, wait for the engine thread, handshake — drives the process-global C++
//  bridge and cannot be exercised in a unit test without launching a real
//  engine, so it is deliberately not faked here. What IS pinned is every rule
//  a reader would otherwise have to take on trust:
//
//    • a chosen net whose file has gone falls back to the built-in AND says so;
//    • an exit nobody asked for is a failure with BOTH ways out;
//    • an exit we asked for is not a failure at all;
//    • `restart` is reachable from `.failed` (that is what Retry is);
//    • Held is a ready-engine state, and it clears itself.
//

import Foundation
import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct AppEngineControllerTests {
    private var builtIn: NeuralNetworkModel { NeuralNetworkModel.builtInModel! }
    private var downloaded: NeuralNetworkModel {
        NeuralNetworkModel.allCases.first { !$0.builtIn }!
    }

    // MARK: - Missing file -> built-in + note

    @Test func aMissingModelFileFallsBackToTheBuiltInAndSaysSo() {
        let resolved = AppEngineController.resolveLaunchModel(downloaded,
                                                              fileExists: { _ in false })
        #expect(resolved.model.builtIn)
        #expect(resolved.note == "\(downloaded.title) was removed — using the built-in network")
    }

    @Test func aPresentModelFileLaunchesItselfWithNothingToSay() {
        let resolved = AppEngineController.resolveLaunchModel(downloaded,
                                                              fileExists: { _ in true })
        #expect(resolved.model.title == downloaded.title)
        #expect(resolved.note == nil)
    }

    @Test func theBuiltInNetNeverConsultsTheDisk() {
        // It is bundled. Asking the file system about it would be both wrong
        // (its bytes are in the app, not in Documents) and a way to fall back
        // to itself with a nonsense note attached.
        let resolved = AppEngineController.resolveLaunchModel(builtIn, fileExists: { _ in
            Issue.record("the built-in net must not hit the file system")
            return false
        })
        #expect(resolved.model.builtIn)
        #expect(resolved.note == nil)
    }

    // MARK: - Thread exit -> failed, with both ways out

    @Test func anExitNobodyAskedForIsAFailureWithBothWaysOut() {
        let outcome = AppEngineController.exitOutcome(fatalError: "Out of memory",
                                                      stopWasRequested: false)
        #expect(outcome.disposition == .failed(reason: "Out of memory"))
        // Retry relaunches the same net; Choose model is the way out of a net
        // that cannot load at all. iOS is the only platform that can offer both.
        #expect(outcome.actions == [.retry, .chooseModel])
    }

    @Test func anExitWithNoDiagnosableCauseStillNamesSomething() {
        let outcome = AppEngineController.exitOutcome(fatalError: nil,
                                                      stopWasRequested: false)
        #expect(outcome.disposition == .failed(reason: EngineExitDisposition.defaultReason))
        #expect(outcome.actions == [.retry, .chooseModel])
    }

    @Test func anExitWeAskedForOffersNothingBecauseNothingWentWrong() {
        let outcome = AppEngineController.exitOutcome(fatalError: "Out of memory",
                                                      stopWasRequested: true)
        #expect(outcome.disposition == .expected)
        #expect(outcome.actions.isEmpty)
    }

    // MARK: - restart is reachable from .failed

    @Test func restartIsAllowedFromRunningAndFromFailed() {
        #expect(AppEngineController.canRestart(from: .running))
        // This is Retry. Without it a failed launch would be terminal and the
        // only way back would be to relaunch the app.
        #expect(AppEngineController.canRestart(from: .failed("The engine did not come up.")))
    }

    @Test func restartIsRefusedWhileNothingIsRunningOrAlreadyStopping() {
        #expect(!AppEngineController.canRestart(from: .idle))
        #expect(!AppEngineController.canRestart(from: .starting))
        #expect(!AppEngineController.canRestart(from: .stopping))
    }

    // MARK: - Held
    //
    // The rule itself moved to the package (`EngineHeldRule`, pinned by
    // `EngineHeldRuleTests`) and `AppEngineController.heldAvailability` — its
    // duplicate — is gone. Nothing iOS-specific is left to pin here.

    // MARK: - Timeouts

    @Test func aRestartWaitsAsLongForTheEngineAsAColdBootDoes() {
        // On iOS a RESTART is where a cold Core ML compile happens: before the
        // board mounted independently, picking a net tore the whole tree down
        // and came back through the boot path, so an uncompiled net got the full
        // launch budget. Every model switch and every Retry takes the restart
        // path now, and a shorter bound there would report "did not come up"
        // for an engine that was still compiling.
        #expect(AppEngineController.restartHandshakeTimeout
                == GameSession.defaultHandshakeTimeout)
    }

    // MARK: - The teardown waits
    //
    // `waitUntilSettled` moved to the package (`EngineRestartRules.untilSettled`,
    // pinned by `EngineRestartRulesTests` at the bottom of this file) and this
    // controller's private twin is gone. The four tests that lived here were
    // verbatim duplicates of those.

    // MARK: - Heavy Core ML work in a picker that now sits over a live engine

    @Test func compileAndClearAreOfferedOnlyWhenNoEngineIsUsingTheCache() {
        #expect(AppEngineController.allowsHeavyCoreMLWork(.absent))
        #expect(AppEngineController.allowsHeavyCoreMLWork(.failed(reason: "boom")))
        // A host that injects no status behaves exactly as it did before the
        // status existed.
        #expect(AppEngineController.allowsHeavyCoreMLWork(nil))

        #expect(!AppEngineController.allowsHeavyCoreMLWork(.launching))
        #expect(!AppEngineController.allowsHeavyCoreMLWork(.ready))
        // Held is a RUNNING engine that simply cannot take this board; its
        // compiled artifacts are still in use.
        #expect(!AppEngineController.allowsHeavyCoreMLWork(.held(maxBoardLength: 19)))
    }
}

/// A mutable flag the poll predicate can read. A plain `var` captured by the
/// predicate closure would be copied at capture time.
@MainActor
private final class SettlingFlag {
    var value = false
}

//
//  The same three decisions, as the SHARED rules the other in-process hosts
//  use (`EngineRestartRules`, KataGoUICore). They are pinned here, beside their
//  iOS twin, because the controllers that use them — visionOS
//  `VisionEngineController`, tvOS `TVEngineController` — live in app targets no
//  test bundle links, so a rule left inside one of them is a rule nothing can
//  test. Each has a failure mode that is invisible from the outside: a restart
//  wedged in `.stopping` forever, a Retry that is refused, or an engine that
//  comes up with nobody reading its replies.
//
@MainActor
struct EngineRestartRulesTests {

    // MARK: - The teardown waits are bounded

    @Test func aWaitThatSettlesReturnsTrue() async {
        let settled = await EngineRestartRules.untilSettled(
            timeout: 5, pollInterval: .milliseconds(10)) { true }
        #expect(settled)
    }

    @Test func aWaitThatNeverSettlesGivesUpAtItsDeadline() async {
        // A `CheckedContinuation` cannot observe cancellation, and
        // `withTaskGroup` awaits its remaining children after `cancelAll()` —
        // so parking on one would hold a restart in `.stopping` forever, with
        // no phase, no status and no Retry. It has to time out on its own.
        let start = Date()
        let settled = await EngineRestartRules.untilSettled(
            timeout: 0.3, pollInterval: .milliseconds(10)) { false }
        let elapsed = Date().timeIntervalSince(start)

        #expect(!settled)
        #expect(elapsed >= 0.3)
        #expect(elapsed < 5, "the wait ran long past its own deadline")
    }

    @Test func aPartyThatSettlesLateIsStillObserved() async {
        // The ordinary case: an engine thread that takes a while to tear down.
        let box = SettlingFlag()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            box.value = true
        }
        let settled = await EngineRestartRules.untilSettled(
            timeout: 5, pollInterval: .milliseconds(10)) { box.value }
        #expect(settled)
    }

    @Test func aCancelledWaitGivesUpAtOnce() async {
        // The caller's own bound has to be able to end this, or a 240 s thread
        // wait would outlive the restart that started it.
        let start = Date()
        let task = Task { @MainActor in
            await EngineRestartRules.untilSettled(
                timeout: 240, pollInterval: .milliseconds(10)) { false }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let settled = await task.value
        #expect(!settled)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    // MARK: - When a restart may begin

    @Test func aRestartIsAllowedFromRunningAndFromFailed() {
        #expect(EngineRestartRules.canRestart(from: .running))
        // That clause IS the Retry button. Without it a failed launch would be
        // terminal and the only way back would be to quit the app.
        #expect(EngineRestartRules.canRestart(from: .failed))
    }

    @Test func aRestartIsRefusedMidTransitionAndBeforeTheBoot() {
        // Interrupting an in-flight handshake breaks the bridge's sole-reader
        // rule; `.idle` means the boot has not run, which is not a restart.
        #expect(!EngineRestartRules.canRestart(from: .starting))
        #expect(!EngineRestartRules.canRestart(from: .stopping))
        #expect(!EngineRestartRules.canRestart(from: .idle))
    }

    // MARK: - Arming the read loop

    @Test func aRestartArmsTheReadLoopWhenTheBootNeverDid() {
        // The bug this exists for: a BOOT handshake that fails deliberately
        // leaves the read loop unarmed (a reader would eat the retry's
        // `version` reply), so generation stays 0. The Retry that follows then
        // spawns an engine, opens the gate and sends the feed — and if nothing
        // arms a loop, NOTHING reads the replies: the board never reports in
        // sync, plays are refused, no analysis ever arrives, and the status
        // line claims all is well.
        #expect(EngineRestartRules.shouldArmReadLoop(generation: 0))
    }

    @Test func aRestartNeverReKeysALoopThatAlreadyExists() {
        // The host keys its read loop on this generation, so bumping it would
        // CANCEL the parked reader rather than resume it — the restart's own
        // `readLoopPark.resume()` is what belongs on this path.
        #expect(!EngineRestartRules.shouldArmReadLoop(generation: 1))
        #expect(!EngineRestartRules.shouldArmReadLoop(generation: 7))
    }
}
