//
//  VisionEngineController.swift
//  KataGo Anytime Vision
//
//  Owner of the visionOS engine lifecycle: the initial launch and the
//  Max-Board-Size restart (a direct port of TVEngineController's proven
//  quit → park read loop → respawn → handshake sequence, with two Vision
//  deviations: the device assignment stays the ANE-only [100, 100], and the
//  post-restart handshake is `session.handshake` — never `initialize`,
//  which would push default 19x19 config commands at the fresh engine
//  before the root re-mounts the current game).
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

    func startInitial() {
        guard phase == .idle, let engineLifecycle else { return }
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

    /// Quit the running engine and bring it back with the freshly persisted
    /// Max Board Size. Returns true when the new engine answered the version
    /// handshake; the caller re-gates and re-mounts the current game.
    @discardableResult
    func restartEngine() async -> Bool {
        guard phase == .running, let session, let engineLifecycle else { return false }
        phase = .stopping

        // Stop any streaming search, then quit. Give the loop a second to
        // drain replies, flip its condition, then push a fake line through
        // the bridge to unpark a blocked getline.
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
        engineLifecycle.reset()
        spawnEngineThread()
        session.stopRequested = false
        phase = .starting

        let handshake: Bool? = await withTimeout(seconds: 120) {
            _ = await session.handshake(
                selectedModelTitle: NeuralNetworkModel.builtInModel?.title ?? "",
                engineLifecycle: engineLifecycle)
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
        // Read the user's Max Board Size on the MainActor and record what THIS
        // engine is launched with, BEFORE the off-main thread starts (so the
        // gates read a consistent value). `effectiveMaxBoardLength` clamps the
        // choice to the net's nnLen (37); Vision always loads the bundled b18
        // net, so the fallback is defensive only.
        let model = NeuralNetworkModel.builtInModel ?? NeuralNetworkModel.allCases[0]
        maxBoardLength = BackendSettings(model: model).effectiveMaxBoardLength
        let launchedMaxBoardLength = maxBoardLength
        let thread = Thread { [weak self] in
            // CoreML/ANE only — deliberately NOT EngineDeviceAssignments
            // .platformMux, which resolves to [0, 100] (one MLX/GPU server)
            // on a real visionOS device; the GPU belongs to the 90 Hz
            // compositor, so both NN server threads go to the Neural Engine.
            KataGoHelper.runGtp(deviceAssignments: [100, 100],
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
