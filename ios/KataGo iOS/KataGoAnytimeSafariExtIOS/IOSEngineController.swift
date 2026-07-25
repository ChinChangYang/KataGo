//
//  IOSEngineController.swift
//  KataGoAnytimeSafariExtIOS
//
//  Owns the in-process KataGo engine inside the iOS Safari appex.
//
//  iOS forbids the macOS extension's model (spawning the `katago-engine`
//  child): app extensions cannot posix_spawn/fork. So the engine is linked and
//  run IN-PROCESS here, under a hard 80 MB `ActiveHard` jetsam cap — a device
//  spike established the exact configuration below, which peaks at ~55 MB:
//
//    • CoreML/ANE only, `[100]`. MLX/GPU is disqualified: it charges the whole
//      forward pass to phys_footprint (~279 MB measured, vs 93 MB for CoreML)
//      and its boot never completed under Safari's compositor.
//    • The tiny b24c64 net. Net SIZE turned out to be irrelevant to footprint
//      (b6c64 and b24c64 measured within 0.5 MB), so the stronger net is free.
//      An 18-block net is impossible: 93 MB compressed on disk alone exceeds
//      the entire process budget.
//    • 1 search thread, batch 1, 19x19 NN buffer (web Go is <= 19x19; the
//      default 37 wastes ~4x the activation memory). `requireExactNNLen` stays
//      FALSE so 9x9/13x13 reuse a sub-region instead of throwing.
//    • No human-SL net (it is a play-time feature and would add ~99 MB).
//    • The appex bundles its OWN default_gtp.cfg with nnCacheSizePowerOfTwo=9
//      and nnMutexPoolSizePowerOfTwo=8. The GTP defaults (2^20 / 2^16) cost
//      20 MB of table at boot plus ~23 MB of accumulated entries at runtime.
//    • Every kata-analyze is preceded by a maxVisits cap. A bare kata-analyze
//      searches unbounded and its tree + cache grow until jetsam kills us.
//
//  Boot costs a few seconds (CoreML converts the net on a cold container), so
//  it runs on a dedicated thread and requests return `.warmingUp` until ready
//  rather than blocking a native message past Safari's patience.
//

import Foundation
import os
import KataGoAnalysisKit
import KataGoSwift
import KataGoUICore

final class IOSEngineController: @unchecked Sendable {
    static let shared = IOSEngineController()

    enum State: String {
        case cold
        case booting
        case ready
        case failed
    }

    /// Per-position visit budget. Small on purpose: the panel analyzes the one
    /// position the reader is looking at, and a scrub should feel instant.
    static let defaultVisits = 32

    /// Hard wall for one analyze pass, so a stalled engine can never hold a
    /// native message open indefinitely.
    private static let analyzeWallSeconds: Double = 6

    private let lock = NSLock()
    private var state: State = .cold
    private let log = Logger(subsystem: "chinchangyang.KataGo-iOS.tw.safariweb",
                             category: "engine")

    var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// The engine's `version` reply, verbatim. Nil until an engine has actually
    /// booted in THIS process — deliberately not persisted, so the panel never
    /// claims a version for an engine that isn't running.
    private var version: String?

    var engineVersion: String? {
        lock.lock(); defer { lock.unlock() }
        return version
    }

    /// Display name for the bundled net. Deliberately STABLE: it is known
    /// without the engine and must read the same before and after boot, because
    /// a line that mutates from a file name into an engine string once the
    /// first analysis lands is jarring. The engine's own exact net identity
    /// (including the training step) is already shown verbatim in the version
    /// line, so nothing is lost by naming the model the way the rest of the
    /// product does. Resolved from the shared registry so it cannot drift from
    /// the file that is actually bundled.
    var engineModelName: String {
        NeuralNetworkModel.allCases
            .first { $0.fileName == Self.modelFileName }?
            .title
            ?? Self.modelResource
    }

    private static var modelFileName: String { "\(modelResource).\(modelExtension)" }

    /// Kick off the boot if it has not started. Returns immediately; callers
    /// poll `currentState`.
    func ensureBooting() {
        lock.lock()
        guard state == .cold else { lock.unlock(); return }
        state = .booting
        lock.unlock()

        let driver = Thread { [weak self] in self?.boot() }
        driver.stackSize = 1 << 20
        driver.name = "katago-safari-driver"
        driver.start()
    }

    private func boot() {
        // A failed Core ML prediction must not take Safari's extension process
        // down: degrade and flag it, and `analyze` discards the affected pass.
        CoreMLComputeHandle.inferenceFailurePolicy = .degrade

        // The bridge's output buffer is process-global; drop anything a prior
        // engine left behind so the handshake reads OUR engine's reply.
        KataGoHelper.clearOutputBuffer()

        guard let modelPath = Bundle.main.path(forResource: Self.modelResource,
                                               ofType: Self.modelExtension) else {
            log.error("b24c64 net missing from the appex bundle")
            lock.lock(); state = .failed; lock.unlock()
            return
        }

        // runGtp blocks running the GTP loop, so it owns its own thread.
        let engineThread = Thread {
            KataGoHelper.runGtp(modelPath: modelPath,
                                deviceAssignments: [100],   // CoreML/ANE only
                                numSearchThreads: 1,
                                nnMaxBatchSize: 1,
                                maxBoardSizeForNNBuffer: 19,
                                includeHumanNet: false)
        }
        engineThread.stackSize = 8 << 20
        engineThread.name = "katago-safari-gtp"
        engineThread.start()

        // Model weights load before `version` answers. On a cold container this
        // also pays the CoreML convert+compile. The reply is the engine's own
        // identity string (e.g. "1.16.3+b24c64-s8526915840") — the panel shows
        // it verbatim, so capture it rather than discarding it.
        let start = DispatchTime.now()
        let reportedVersion = driveUntilResponse("version")
        let bootMillis = Double(DispatchTime.now().uptimeNanoseconds
                                &- start.uptimeNanoseconds) / 1_000_000
        lock.lock(); version = reportedVersion; lock.unlock()

        lock.lock(); state = .ready; lock.unlock()
        log.log("engine ready in \(Int(bootMillis), privacy: .public) ms")
    }

    private static let modelResource = "lionffen_b24c64_3x3_v3_12300"
    private static let modelExtension = "bin.gz"

    // MARK: - Analysis

    /// Analyze one position of an SGF already written to `sgfPath`.
    /// `moveIndex` counts moves played from the empty board.
    /// Returns nil if the engine produced no analysis before the wall.
    func analyze(sgfPath: String,
                 moveIndex: Int,
                 scan: SgfHeaderScan,
                 visits: Int) -> (parsed: ParsedAnalysis, toMove: PlayerColor)? {
        // `loadsgf <file> N` yields the position BEFORE move N, i.e. with N-1
        // moves played — so the position after `moveIndex` moves is N = index+1.
        driveUntilResponse("loadsgf \(quoted(sgfPath)) \(moveIndex + 1)")

        // MANDATORY cap — see the file header.
        driveUntilResponse("kata-set-param maxVisits \(visits)")

        let toMove = colorToMove(at: moveIndex, scan: scan)
        let parser = AnalysisLineParser(boardWidth: scan.boardWidth,
                                        boardHeight: scan.boardHeight,
                                        nextColor: toMove)

        // Ownership off: the iOS overlay is winrate-only, and skipping the grid
        // keeps both the message size and the cached payload small.
        KataGoHelper.sendCommand(AnalysisCommand.analyze(interval: 20,
                                                         maxMoves: 12,
                                                         ownership: false))

        var latest: String?
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(Self.analyzeWallSeconds * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let line = KataGoHelper.getMessageLine()
            guard !line.isEmpty else { continue }
            if line.hasPrefix("info ") {
                latest = line
                // One report that already reached the visit cap is all we need.
                if let root = parser.parse(message: line).rootInfo,
                   root.visits >= visits {
                    break
                }
            } else if line.hasPrefix("?") {
                break   // engine rejected the command
            }
        }

        KataGoHelper.sendCommand(AnalysisCommand.stop)
        drainUntilTerminator()

        // A prediction that faulted mid-search leaves the tree holding values
        // derived from an unwritten buffer — report nothing rather than a
        // plausible-looking number.
        if CoreMLComputeHandle.consumeInferenceFailure() {
            log.error("discarding analysis: a Core ML prediction failed")
            return nil
        }

        guard let latest else { return nil }
        return (parser.parse(message: latest), toMove)
    }

    /// Whose turn it is after `moveIndex` moves, from the SGF's own move
    /// colors (handicap games do not simply alternate from Black).
    private func colorToMove(at moveIndex: Int, scan: SgfHeaderScan) -> PlayerColor {
        if moveIndex < scan.moveColors.count {
            return scan.moveColors[moveIndex]
        }
        if let last = scan.moveColors.last {
            return last == .black ? .white : .black
        }
        return .black
    }

    // MARK: - GTP plumbing

    private func quoted(_ path: String) -> String {
        // GTP splits on whitespace; app-group container paths can contain
        // spaces, so hand the engine a quoted path.
        return path.contains(" ") ? "\"\(path)\"" : path
    }

    /// Send a command and return its GTP payload — the text after the leading
    /// "=" — or nil when the engine answered with an error ("?").
    @discardableResult
    private func driveUntilResponse(_ command: String) -> String? {
        KataGoHelper.sendCommand(command)
        return drainUntilTerminator()
    }

    @discardableResult
    private func drainUntilTerminator() -> String? {
        while true {
            let line = KataGoHelper.getMessageLine()
            if line.hasPrefix("?") { return nil }
            if line.hasPrefix("=") {
                let payload = line.dropFirst()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return payload.isEmpty ? nil : payload
            }
        }
    }
}
