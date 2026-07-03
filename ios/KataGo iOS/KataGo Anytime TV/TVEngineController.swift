//
//  TVEngineController.swift
//  KataGo Anytime TV
//
//  Owner of the tvOS engine lifecycle: the initial launch (with the
//  persisted, crash-safe backend) and in-process restarts onto a different
//  backend (the Settings picker and the CoreML-vs-MLX benchmark). The GTP
//  engine is a one-shot blocking thread; "restart" = GTP "quit" → old thread
//  ends → park the read loop → spawn a new thread → re-run the version
//  handshake (the sole reader while it runs) → resume the read loop. The
//  quit sequencing mirrors the proven iOS flow (ConfigView.quitEngine →
//  ModelRunnerView.startKataGoThread).
//
//  Crash safety: TVSettingsStore.pendingEngineBackend is armed before every
//  spawn and cleared only when the version handshake succeeds — if a backend
//  kills the process (the MLX memory budget on tvOS is uncharacterized), the
//  next launch boots plain CoreML.
//

import Foundation
import KataGoUICore

@Observable
@MainActor
final class TVEngineController {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case stopping
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var currentBackend: TVEngineBackend = .coreML

    @ObservationIgnored private var session: GameSession?
    @ObservationIgnored private var engineLifecycle: EngineLifecycle?
    @ObservationIgnored private var runLoopExit: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var readLoopPark: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var engineThreadExit: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var engineThreadRunning = false

    func configure(session: GameSession, engineLifecycle: EngineLifecycle) {
        self.session = session
        self.engineLifecycle = engineLifecycle
    }

    /// Cold start (replaces the old bare-runGtp body of startEngineIfNeeded).
    func startInitial() {
        guard phase == .idle, let engineLifecycle else { return }
        let backend = TVSettingsStore.resolveLaunchBackendApplyingRecovery()
        currentBackend = backend
        TVSettingsStore.pendingEngineBackend = backend
        engineLifecycle.reset()
        spawnEngineThread(backend: backend)
        phase = .starting
    }

    /// Called by TVRootView once the cold-start version handshake succeeds.
    func noteInitialHandshakeComplete() {
        TVSettingsStore.pendingEngineBackend = nil
        phase = .running
    }

    /// The read loop reports each `session.run` exit here, then parks until a
    /// restart has finished the handshake (during which `initialize` must be
    /// the bridge's only reader).
    func noteRunLoopExited() async {
        runLoopExit?.resume()
        runLoopExit = nil
        await withCheckedContinuation { continuation in
            readLoopPark = continuation
        }
    }

    /// Quit the running engine and bring it back on `newBackend`. Returns
    /// true when the new engine answered the version handshake.
    @discardableResult
    func restart(to newBackend: TVEngineBackend, persistOnSuccess: Bool) async -> Bool {
        guard phase == .running, let session, let engineLifecycle else { return false }
        phase = .stopping

        // Stop any streaming search, then quit. Mirror the iOS timing: give
        // the loop a second to drain replies, flip its condition, then push a
        // fake line through the bridge to unpark a blocked getline.
        session.messageList.appendAndSend(command: "stop")
        session.messageList.appendAndSend(command: "quit")
        try? await Task.sleep(for: .seconds(1))
        let exited: Void? = await withTimeout(seconds: 10) { [weak self] in
            await withCheckedContinuation { continuation in
                self?.runLoopExit = continuation
                session.stopRequested = true
                KataGoHelper.sendMessage("\n")
            }
        }
        guard exited != nil else {
            phase = .failed("The engine did not shut down.")
            return false
        }

        // CRITICAL: also wait for the ENGINE THREAD itself to finish.
        // MainCmds::gtp keeps tearing down (deleting the engine, NN cleanup)
        // after its reply stream goes quiet; spawning the next runGtp while
        // the old one is still inside that epilogue overlaps two engines on
        // the process-global bridge state and dies with a C++ fatalError
        // (observed as a voluntary exit(1) on the simulator). An idle engine
        // tears down in milliseconds, but one that has just run a search or
        // benchmark has been observed taking ~2 minutes — allow for it.
        let threadEnded: Void? = await withTimeout(seconds: 240) { [weak self] in
            await self?.waitForEngineThreadExit()
        }
        guard threadEnded != nil else {
            phase = .failed("The engine did not shut down.")
            return false
        }

        // Spawn the replacement and redo the handshake as the sole reader.
        TVSettingsStore.pendingEngineBackend = newBackend
        engineLifecycle.reset()
        spawnEngineThread(backend: newBackend)
        session.stopRequested = false
        phase = .starting

        // The first MLX start runs the Winograd autotuner — allow minutes.
        let timeout: Double = newBackend == .mlx ? 600 : 120
        let handshake: Bool? = await withTimeout(seconds: timeout) {
            _ = await session.initialize(
                selectedModelTitle: NeuralNetworkModel.builtInModel?.title ?? "",
                engineLifecycle: engineLifecycle,
                config: nil)
            return true
        }

        guard handshake == true else {
            phase = .failed("\(newBackend.displayName) did not come up.")
            // Sentinel stays armed: a jetsam or hang here must boot CoreML
            // next launch. Leave the read loop parked (engine state unknown).
            return false
        }

        TVSettingsStore.pendingEngineBackend = nil
        currentBackend = newBackend
        if persistOnSuccess {
            TVSettingsStore.backend = newBackend
        }
        phase = .running

        // Resume the parked read loop for the new engine.
        readLoopPark?.resume()
        readLoopPark = nil
        return true
    }

    private func spawnEngineThread(backend: TVEngineBackend) {
        engineThreadRunning = true
        // Built-in b18 net, human-SL net skipped. Needs a >512 KB stack
        // (BoardHistory copies) — match the iOS app's 1 MB.
        let thread = Thread { [weak self] in
            KataGoHelper.runGtp(deviceAssignments: backend.deviceAssignments,
                                numSearchThreads: KataGoHelper.mlxNumSearchThreads)
            // MainCmds::gtp returned — the engine is fully torn down.
            Task { @MainActor in self?.noteEngineThreadExited() }
        }
        thread.stackSize = 4096 * 256
        thread.start()
    }

    private func noteEngineThreadExited() {
        engineThreadRunning = false
        engineThreadExit?.resume()
        engineThreadExit = nil
    }

    private func waitForEngineThreadExit() async {
        guard engineThreadRunning else { return }
        await withCheckedContinuation { continuation in
            // Re-check after suspension setup: the thread may have exited
            // between the guard and here (both hops are main-actor, so no —
            // but keep the single-waiter invariant explicit).
            if engineThreadRunning {
                engineThreadExit = continuation
            } else {
                continuation.resume()
            }
        }
    }

    /// Runs `operation` with a wall-clock cap; nil on timeout. The timed-out
    /// operation is cancelled, but a blocking engine wait inside it can only
    /// end when the engine produces output — callers treat nil as fatal for
    /// the current engine generation.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @MainActor () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
