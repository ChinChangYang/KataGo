//
//  VisionEngineController.swift
//  KataGo Anytime Vision
//
//  Owner of the visionOS engine lifecycle: the initial launch and the
//  full restarts — Max Board Size changes and model activations both go
//  through the same quit → park read loop → respawn → handshake sequence
//  (a direct port of TVEngineController's proven flow, with two Vision
//  deviations: the device assignment stays the ANE-only [100, 100], and the
//  post-restart handshake is `session.handshake` — never `initialize`,
//  which would push default 19x19 config commands at the fresh engine
//  before the root re-mounts the current game). Every spawn arms the
//  ModelRunnerView.pendingLoadModelTitle crash sentinel; the root's
//  lastLoadedModelTitle observer clears it and records the last-good
//  selection once the handshake lands (iOS ModelRunnerView parity).
//

import Foundation
import KataGoUICore

@Observable
@MainActor
final class VisionEngineController {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case stopping
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// The NN-buffer board length the CURRENTLY running engine was launched
    /// with (`maxBoardSizeForNNBuffer`). The board gates and New Game sizing
    /// read this — never the live `BackendSettings` — because a restart can
    /// take minutes to tear down a searched engine, during which the old
    /// buffer is still what the engine serves. 19 is only the pre-spawn
    /// placeholder (and the persisted default): `spawnEngineThread` records
    /// the real launched value before its thread starts.
    private(set) var maxBoardLength = 19

    /// The net the CURRENTLY running (or launching) engine serves. Observable
    /// so the Settings card can key its per-model Max Board Size on it and
    /// the Models card can mark the active row. Set only by startInitial and
    /// restartEngine(loading:), always before the spawn reads it.
    private(set) var activeModel: NeuralNetworkModel =
        NeuralNetworkModel.builtInModel ?? NeuralNetworkModel.allCases[0]

    @ObservationIgnored private var session: GameSession?
    @ObservationIgnored private var engineLifecycle: EngineLifecycle?
    @ObservationIgnored private var modelSelection: ModelSelectionStore?
    @ObservationIgnored private var runLoopExit: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var readLoopPark: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var engineThreadExit: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var engineThreadRunning = false

    func configure(session: GameSession,
                   engineLifecycle: EngineLifecycle,
                   modelSelection: ModelSelectionStore) {
        self.session = session
        self.engineLifecycle = engineLifecycle
        self.modelSelection = modelSelection
    }

    /// Boot with the model the root resolved (VisionModelBootResolver — the
    /// persisted selection, crash-recovered to the built-in when needed).
    func startInitial(model: NeuralNetworkModel) {
        guard phase == .idle, let engineLifecycle else { return }
        activeModel = model
        engineLifecycle.reset()
        spawnEngineThread()
        phase = .starting
    }

    /// Called by VisionRootView once the boot version handshake succeeds.
    func noteInitialHandshakeComplete() {
        phase = .running
    }

    /// The read loop reports each `session.run` exit here, then parks until a
    /// restart has finished the handshake (during which the handshake must be
    /// the bridge's only reader).
    func noteRunLoopExited() async {
        runLoopExit?.resume()
        runLoopExit = nil
        await withCheckedContinuation { continuation in
            readLoopPark = continuation
        }
    }

    /// Quit the running engine and bring it back — with `newModel` when a
    /// model activation drives the restart, or with the same net and the
    /// freshly persisted Max Board Size when nil. Returns true when the new
    /// engine answered the version handshake; the caller re-gates and
    /// re-mounts the current game.
    @discardableResult
    func restartEngine(loading newModel: NeuralNetworkModel? = nil) async -> Bool {
        guard phase == .running, let session, let engineLifecycle else { return false }
        phase = .stopping

        // Stop any streaming search, then quit. Give the loop a second to
        // drain replies, flip its condition, then push a fake line through
        // the bridge to unpark a blocked getline.
        // Lifecycle commands: they go straight to the transport, because the
        // command gate is exactly what a teardown must not be blocked by.
        session.sendLifecycleCommand("stop")
        session.sendLifecycleCommand("quit")
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
        // the process-global bridge state and dies with a C++ fatalError.
        // An idle engine tears down in milliseconds, but one that has just
        // run a search has been observed taking ~2 minutes — allow for it.
        let threadEnded: Void? = await withTimeout(seconds: 240) { [weak self] in
            await self?.waitForEngineThreadExit()
        }
        guard threadEnded != nil else {
            phase = .failed("The engine did not shut down.")
            return false
        }

        // Spawn the replacement and redo the handshake as the sole reader.
        // The model swaps only after the old engine has fully torn down, so
        // every reader of activeModel sees the running engine's net.
        if let newModel {
            activeModel = newModel
        }
        engineLifecycle.reset()
        spawnEngineThread()
        session.stopRequested = false
        phase = .starting

        // The handshake title is what markFirstResponse persists as the
        // last-good selection — it must be the net this engine loads.
        // The handshake carries the SAME 120 s deadline as the wrapper. The
        // wrapper alone is not a bound: it cancels its child, and a task group
        // still awaits a cancelled child, so this could not return until the
        // handshake did. The handshake honours cancellation too — belt and
        // braces, and neither can outlive the other.
        let handshake: Bool? = await withTimeout(seconds: 120) { [self] in
            _ = await session.handshake(
                selectedModelTitle: activeModel.title,
                engineLifecycle: engineLifecycle,
                timeoutSeconds: 120)
            return true
        }

        guard handshake == true else {
            phase = .failed("The engine did not come up.")
            // Leave the read loop parked (engine state unknown).
            return false
        }

        phase = .running

        // Resume the parked read loop for the new engine.
        readLoopPark?.resume()
        readLoopPark = nil
        return true
    }

    private func spawnEngineThread() {
        engineThreadRunning = true
        // Read the active model's Max Board Size on the MainActor and record
        // what THIS engine is launched with, BEFORE the off-main thread
        // starts (so the gates read a consistent value). The per-fileName
        // BackendSettings keys make the buffer per-model automatically;
        // `effectiveMaxBoardLength` clamps the choice to the net's nnLen.
        let model = activeModel
        maxBoardLength = BackendSettings(model: model).effectiveMaxBoardLength
        let launchedMaxBoardLength = maxBoardLength
        // Built-in → nil (runGtp resolves the bundled default_model);
        // downloaded → the Documents file (iOS ModelRunnerView parity).
        let modelPath = model.builtIn ? nil : model.downloadedURL?.path
        // Arm the crash sentinel BEFORE the engine thread starts, for every
        // spawn (boot, model switch, Max-Board-Size restart alike). If the
        // process dies before the handshake's first GTP reply, the surviving
        // value makes the next boot fall back to the built-in net instead of
        // crash-looping (VisionModelBootResolver).
        modelSelection?.pendingLoadModelTitle = model.title
        let thread = Thread { [weak self] in
            // CoreML/ANE only — deliberately NOT EngineDeviceAssignments
            // .platformMux, which resolves to [0, 100] (one MLX/GPU server)
            // on a real visionOS device; the GPU belongs to the 90 Hz
            // compositor, so both NN server threads go to the Neural Engine.
            KataGoHelper.runGtp(modelPath: modelPath,
                                deviceAssignments: [100, 100],
                                numSearchThreads: KataGoHelper.mlxNumSearchThreads,
                                maxBoardSizeForNNBuffer: launchedMaxBoardLength)
            // MainCmds::gtp returned — the engine is fully torn down.
            Task { @MainActor in self?.noteEngineThreadExited() }
        }
        // Needs a >512 KB stack (BoardHistory copies) — match the iOS app's 1 MB.
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
