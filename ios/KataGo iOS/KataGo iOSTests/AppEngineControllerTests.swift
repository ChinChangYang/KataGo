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

    @Test func aBoardBiggerThanTheEngineHoldsAReadyEngine() {
        #expect(AppEngineController.heldAvailability(current: .ready,
                                                     boardWidth: 37,
                                                     boardHeight: 37,
                                                     maxBoardLength: 19)
                == .held(maxBoardLength: 19))
    }

    @Test func aBoardThatFitsReleasesTheHold() {
        #expect(AppEngineController.heldAvailability(current: .held(maxBoardLength: 19),
                                                     boardWidth: 19,
                                                     boardHeight: 19,
                                                     maxBoardLength: 19)
                == .ready)
    }

    @Test func heldNeverOverwritesLaunchingAbsentOrFailed() {
        // Held answers "this engine cannot take THIS board". An engine that is
        // still loading, absent or dead has a more important thing to say, and
        // overwriting it would lose the Retry / Choose model buttons with it.
        for availability: EngineAvailability in [.launching,
                                                 .absent,
                                                 .failed(reason: "boom")] {
            #expect(AppEngineController.heldAvailability(current: availability,
                                                         boardWidth: 37,
                                                         boardHeight: 37,
                                                         maxBoardLength: 19)
                    == availability)
        }
    }

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

    // MARK: - The teardown waits are bounded, and give up rather than hang

    @Test func aWaitThatSettlesReturnsTrue() async {
        let settled = await AppEngineController.waitUntilSettled(
            timeout: 5, pollInterval: .milliseconds(10)) { true }
        #expect(settled)
    }

    @Test func aReadLoopThatNeverParksGivesUpInsteadOfHanging() async {
        // The failure this pins: a `CheckedContinuation` cannot observe
        // cancellation, and `withTaskGroup` awaits its remaining children after
        // `cancelAll()` — so parking on one would hold a restart in `.stopping`
        // forever, with no phase, no status and no Retry. It has to time out on
        // its own.
        let start = Date()
        let settled = await AppEngineController.waitUntilSettled(
            timeout: 0.3, pollInterval: .milliseconds(10)) { false }
        let elapsed = Date().timeIntervalSince(start)

        #expect(!settled)
        #expect(elapsed >= 0.3)
        #expect(elapsed < 5, "the wait ran long past its own deadline")
    }

    @Test func anEngineThreadThatExitsLateIsStillObserved() async {
        // The ordinary case: the party settles part-way through the wait.
        let box = SettlingFlag()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            box.value = true
        }
        let settled = await AppEngineController.waitUntilSettled(
            timeout: 5, pollInterval: .milliseconds(10)) { box.value }
        #expect(settled)
    }

    @Test func aCancelledWaitGivesUpAtOnce() async {
        // The caller's own bound has to be able to end this, or a 240 s thread
        // wait would outlive the restart that started it.
        let start = Date()
        let task = Task { @MainActor in
            await AppEngineController.waitUntilSettled(
                timeout: 240, pollInterval: .milliseconds(10)) { false }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let settled = await task.value
        #expect(!settled)
        #expect(Date().timeIntervalSince(start) < 5)
    }

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

    @Test func anUnknownBoardSizeIsNeverHeld() {
        // No game selected: there is no board to refuse.
        #expect(AppEngineController.heldAvailability(current: .ready,
                                                     boardWidth: 0,
                                                     boardHeight: 0,
                                                     maxBoardLength: 19)
                == .ready)
    }
}

/// A mutable flag the poll predicate can read. A plain `var` captured by the
/// predicate closure would be copied at capture time.
@MainActor
private final class SettlingFlag {
    var value = false
}
