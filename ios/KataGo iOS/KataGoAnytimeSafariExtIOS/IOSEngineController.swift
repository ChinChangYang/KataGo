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
//    • The search is bounded by THIS FILE'S read loop and nothing else. GTP's
//      `kata-set-param maxVisits` does NOT bound a kata-analyze: gtp.cpp hands
//      the analysis search `searchFactor = 1e40`, which saturates the visit cap
//      at 2^62 (measured: 651 root visits reached under a cap of 16). So the
//      client-side break below is load-bearing for the 80 MB budget, not a
//      convenience — an unbounded kata-analyze grows its tree until jetsam
//      kills the process, which is exactly how the first spike died.
//
//  Boot costs a few seconds (CoreML converts the net on a cold container), so
//  it runs on a dedicated thread and requests return `.warmingUp` until ready
//  rather than blocking a native message past Safari's patience.
//
//  CONCURRENCY. `SafariWebExtensionHandler` dispatches every native message
//  onto a concurrent queue, so two requests can land at once. The GTP stream is
//  process-global and gtp.cpp aborts a running analysis on ANY input line, so
//  two overlapping conversations would interleave: one call's `loadsgf` silently
//  kills the other's search and the survivor's numbers get attributed to the
//  wrong position. Every conversation therefore runs under `engineLock`.
//  Cancellation deliberately does NOT take that lock — it only bumps a counter,
//  so it can abandon a search that is currently holding it.
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

    /// Outcome of one GTP command. `loadsgf` answers `=` with an EMPTY payload
    /// on success, so "no payload" and "rejected" must not collapse into one
    /// `nil` — a rejected position followed by a successful-looking analysis
    /// silently caches the PREVIOUS position's numbers under the requested key.
    private enum GtpReply {
        case ok(String?)
        case rejected(String?)
        case silent
    }

    /// What one analysis pass may spend.
    ///
    /// Both bounds are enforced HERE, by when this file stops reading and sends
    /// `stop` — the engine can enforce neither. `kata-set-param maxVisits` is
    /// inert for an analysis search (see the file header), and `kata-analyze`
    /// has no time argument at all: it accepts only interval/maxmoves/ownership/
    /// rootInfo/minmoves/pvVisits, and the config's `maxTime` governs genmove.
    enum SearchBudget {
        /// Fixed depth. Used for the whole-game survey, where every point must
        /// be comparable to its neighbours or the chart's blunder badges become
        /// search noise.
        case visits(Int)
        /// Fixed wall-clock time. Used for the position the reader settled on,
        /// where a predictable WAIT matters more than a predictable depth — a
        /// slower device returns fewer visits instead of taking longer.
        case seconds(Double)
    }

    /// Per-position visit budget. Small on purpose: the panel analyzes the one
    /// position the reader is looking at, and a scrub should feel instant.
    static let defaultVisits = 32

    /// Hard wall for one analyze pass, so a stalled engine can never hold a
    /// native message open indefinitely.
    private static let analyzeWallSeconds: Double = 6

    /// Wall for a command that performs no search (loadsgf, kata-set-param,
    /// the post-stop drain). Generous: these are board operations, not evals.
    private static let commandWallSeconds: Double = 10

    /// Wall for the boot handshake. A cold container pays a CoreML convert and
    /// compile here (~3.5 s measured, but a first-ever launch can be far
    /// slower), so this is deliberately long — it exists to turn an engine that
    /// never answers into `.failed` rather than a thread parked forever.
    private static let bootWallSeconds: Double = 180

    /// How long one read waits before the enclosing loop re-checks its own
    /// deadline and its cancellation. Below the 200 ms analysis report interval,
    /// so a cancel is honored within roughly one report.
    private static let readSliceSeconds: Double = 0.1

    private let lock = NSLock()
    private let engineLock = NSLock()
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

    /// Bumped by `cancelAnalysis(gameId:)`. A pass whose snapshot no longer
    /// matches abandons its search and reports nothing.
    ///
    /// Kept PER GAME, not process-wide. One appex process serves every panel on
    /// a page (the content script allows four) and every tab, so a single
    /// counter meant one reader scrubbing away could abandon a different
    /// reader's search — which surfaces to them as "analysis unavailable" and,
    /// mid-scan, blacklists that position for good. No amount of ordering
    /// discipline in one page's JavaScript can prevent that, because the two
    /// pages know nothing about each other.
    private var generationByGame: [String: Int] = [:]

    private func currentGeneration(forGame gameId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return generationByGame[gameId, default: 0]
    }

    /// Abandon the analysis running or queued for one game.
    ///
    /// Takes only `lock`, never `engineLock` — the whole point is to interrupt a
    /// pass that currently holds the engine.
    ///
    /// Scoping by game removes the cross-panel and cross-tab collisions. What it
    /// cannot resolve on its own is a stop for THIS game arriving after the next
    /// pass for the same game has already started, since nothing on the wire
    /// says which pass was meant: the panel closes that by not issuing a query
    /// while its own stop is outstanding. Two panels showing the byte-identical
    /// SGF remain theoretically racy and are not worth a wire field.
    func cancelAnalysis(gameId: String) {
        lock.lock()
        generationByGame[gameId, default: 0] &+= 1
        lock.unlock()
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
        //
        // Held under engineLock so an analysis that arrives mid-boot queues
        // behind the handshake instead of interleaving with it. (Requests are
        // normally turned away with `.warmingUp` before reaching the engine;
        // this closes the window where state flips to .ready in between.)
        engineLock.lock()
        let start = DispatchTime.now()
        let reply = driveUntilResponse("version", wallSeconds: Self.bootWallSeconds)
        let bootMillis = Double(DispatchTime.now().uptimeNanoseconds
                                &- start.uptimeNanoseconds) / 1_000_000
        engineLock.unlock()

        switch reply {
        case let .ok(payload):
            lock.lock(); version = payload; state = .ready; lock.unlock()
            log.log("engine ready in \(Int(bootMillis), privacy: .public) ms")
        case .rejected, .silent:
            // An engine that cannot answer `version` cannot analyze either.
            // Failing here surfaces as "the engine failed to start" instead of
            // leaving every later request to time out one at a time.
            lock.lock(); state = .failed; lock.unlock()
            log.error("engine did not answer version within \(Int(Self.bootWallSeconds), privacy: .public) s")
        }
    }

    private static let modelResource = "lionffen_b24c64_3x3_v3_12300"
    private static let modelExtension = "bin.gz"

    // MARK: - Analysis

    /// Analyze one position of an SGF already written to `sgfPath`.
    /// `moveIndex` counts moves played from the empty board.
    /// Returns nil if the engine produced no usable analysis.
    func analyze(sgfPath: String,
                 moveIndex: Int,
                 scan: SgfHeaderScan,
                 budget: SearchBudget,
                 gameId: String,
                 line: [String] = [],
                 mainline: Bool = true) -> (parsed: ParsedAnalysis, toMove: PlayerColor)? {
        // Snapshot BEFORE queuing on the engine, so a cancel that arrives while
        // this request waits its turn abandons it without running a search.
        let generation = currentGeneration(forGame: gameId)

        engineLock.lock()
        defer { engineLock.unlock() }

        guard generation == currentGeneration(forGame: gameId) else { return nil }

        // GTP splits its command line on whitespace and takes the filename
        // verbatim, so there is no quoting to be had — a path with a space
        // cannot be expressed at all. (The previous code quoted it, which made
        // the quotes part of the filename.) Our spool lives under the appex's
        // temporary directory, whose components are UUIDs and a hex hash, so
        // this is a guard against future callers rather than a live case.
        guard !sgfPath.contains(" ") else {
            log.error("SGF path contains a space; GTP cannot address it")
            return nil
        }

        // Start from a clean fault flag. `CoreMLComputeHandle`'s is process-
        // global and sticky, cleared only by consuming it — and cancellation is
        // a NORMAL exit here, taken before the consume below. Without this, a
        // fault raised during a pass the reader scrubbed away from is inherited
        // by the NEXT position, whose perfectly good result is then discarded;
        // mid-scan that also blacklists the position for the whole session and
        // leaves a permanent hole in the chart.
        _ = CoreMLComputeHandle.consumeInferenceFailure()

        // `loadsgf <file> N` yields the position BEFORE move N, i.e. with N-1
        // moves played — so the position after `moveIndex` moves is N = index+1.
        // Whenever the page sends a line — which is now ALWAYS, main line
        // included — N = 1: the initial position, carrying the SGF's handicap
        // stones, komi and rules but no moves. That is the one position whose
        // meaning does not depend on which line the loader follows, and the
        // moves are then replayed explicitly.
        //
        // This matters beyond variations. `loadsgf <file> N` resolves N against
        // KataGo's own idea of the main line, and `Sgf::getMovesHelper` takes the
        // DEEPEST child at every fork ("Gets the longest child if the sgf has
        // branches"), while WGo — and SgfHeaderScan — take the FIRST. On a file
        // whose variation outruns the main line, addressing by number replays a
        // different game from the one on screen, silently: every move is legal,
        // the colors still alternate, and the wrong winrate lands on the chart.
        let loadIndex = line.isEmpty ? moveIndex + 1 : 1
        guard case .ok = driveUntilResponse("loadsgf \(sgfPath) \(loadIndex)",
                                            wallSeconds: Self.commandWallSeconds) else {
            // Analyzing anyway would search whatever position the engine still
            // holds and report it under the requested index.
            log.error("loadsgf rejected for move index \(moveIndex, privacy: .public)")
            return nil
        }

        // Replay the line. Colors are the page's, taken from the SGF nodes
        // themselves — never inferred by alternation, which handicap, passes and
        // PL[] all break. (KataGo tolerates an out-of-turn play but silently
        // clears move history when it happens, costing the net its recent-move
        // planes; correct colors keep that from firing.)
        for move in line {
            guard case .ok = driveUntilResponse("play \(move)",
                                                wallSeconds: Self.commandWallSeconds) else {
                log.error("engine rejected a replayed move")
                return nil
            }
        }

        // Cosmetic against the engine (see the file header: it does not bound an
        // analysis search) but kept for a depth budget because it costs nothing
        // and keeps the engine's own reported cap consistent with what we intend
        // to spend. A time budget has no visit target to report.
        if case let .visits(target) = budget {
            _ = driveUntilResponse("kata-set-param maxVisits \(target)",
                                   wallSeconds: Self.commandWallSeconds)
        }

        // Inside a variation the side to move follows from the line itself;
        // `scan.moveColors` only knows the main line and would be wrong from the
        // fork onward. Getting this wrong is quiet and nasty: winrateB is
        // flip-invariant so the chart still looks right, but utilityLcb is not,
        // so the best-move ring lands on the WORST candidate.
        // On the main line the scan is authoritative — it knows the color of
        // the NEXT move, which handles an SGF that plays two of a color in a
        // row. Inside a variation it knows nothing past the fork, so the side to
        // move follows from the line itself.
        let toMove = mainline
            ? colorToMove(at: moveIndex, scan: scan)
            : (line.last?.hasPrefix("b") == true ? .white : .black)
        let parser = AnalysisLineParser(boardWidth: scan.boardWidth,
                                        boardHeight: scan.boardHeight,
                                        nextColor: toMove)

        // Ownership off: the iOS overlay is winrate-only, and skipping the grid
        // keeps both the message size and the cached payload small.
        //
        // interval 10 (= 100 ms) rather than the engine's lazier default: the
        // report cadence is the granularity of BOTH the time budget and
        // cancellation, since neither can act between reports.
        KataGoHelper.sendCommand(AnalysisCommand.analyze(interval: 10,
                                                         maxMoves: 12,
                                                         ownership: false))

        // A depth budget still needs a wall, because nothing else bounds it if
        // the engine stalls. A time budget IS its own wall.
        let wallSeconds: Double
        switch budget {
        case .visits: wallSeconds = Self.analyzeWallSeconds
        case let .seconds(seconds): wallSeconds = seconds
        }

        var latest: String?
        var cancelled = false
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(wallSeconds * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if generation != currentGeneration(forGame: gameId) { cancelled = true; break }
            // Bounded: an engine that stops emitting must not wedge this loop.
            // The unbounded read would never return, and the deadline above is
            // only tested BETWEEN lines.
            let line = KataGoHelper.getMessageLine(timeoutSeconds: Self.readSliceSeconds)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("info ") {
                latest = line
                // A depth budget stops as soon as it is met. A time budget keeps
                // reading — the deadline above ends it, and the last report read
                // is the deepest one available.
                if case let .visits(target) = budget,
                   let root = parser.parse(message: line).rootInfo,
                   root.visits >= target {
                    break
                }
            } else if line.hasPrefix("?") {
                break   // engine rejected the command
            }
        }

        KataGoHelper.sendCommand(AnalysisCommand.stop)
        _ = drainUntilTerminator(wallSeconds: Self.commandWallSeconds)

        // An abandoned pass has no result to report: whatever it reached is
        // shallower than asked for, and caching it would make the position look
        // analyzed at a depth it never reached.
        if cancelled { return nil }

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

    /// Send a command and return what the engine answered.
    @discardableResult
    private func driveUntilResponse(_ command: String, wallSeconds: Double) -> GtpReply {
        KataGoHelper.sendCommand(command)
        return drainUntilTerminator(wallSeconds: wallSeconds)
    }

    /// Read until the engine's response terminator, or until `wallSeconds`
    /// passes with no terminator in sight.
    @discardableResult
    private func drainUntilTerminator(wallSeconds: Double) -> GtpReply {
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(wallSeconds * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let line = KataGoHelper.getMessageLine(timeoutSeconds: Self.readSliceSeconds)
            if line.isEmpty { continue }   // blank line, or nothing arrived yet
            if line.hasPrefix("?") {
                return .rejected(Self.payload(of: line))
            }
            if line.hasPrefix("=") {
                return .ok(Self.payload(of: line))
            }
        }
        return .silent
    }

    /// The text after a GTP status character, or nil when there is none.
    private static func payload(of line: String) -> String? {
        let text = line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
