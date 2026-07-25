//
//  IOSAnalysisService.swift
//  KataGoAnytimeSafariExtIOS
//
//  Serves one analysis request per native message.
//
//  The macOS extension keeps a warm worker thread that sweeps a whole game
//  outward from the cursor and hands results back through a pull-based outbox.
//  That shape does not survive iOS: the Safari native handler is launched on
//  demand and torn down when idle, so nothing may be assumed to live between
//  messages. Here every request is self-contained and idempotent —
//  `.query(moveIndex:)` analyzes exactly the position the reader is looking at
//  and returns it. The whole-game chart is filled lazily by the page as the
//  reader scrubs (plus an optional user-run scan), never by a native sweep.
//
//  Results persist to the App Group after every position, keyed by
//  (sgfHash, moveIndex), so a jetsam kill costs at most the position in flight
//  and revisited positions are instant.
//

import Foundation
import os
import KataGoAnalysisKit
import KataGoGameStore

final class IOSAnalysisService: @unchecked Sendable {
    static let shared = IOSAnalysisService()

    private let lock = NSLock()
    private let log = Logger(subsystem: "chinchangyang.KataGo-iOS.tw.safariweb",
                             category: "service")

    /// SGF text of the game currently spooled to disk, keyed by hash, so
    /// consecutive queries on one game reuse the same temp file.
    private var activeHash: String?
    private var activeSgfPath: String?
    private var activeScan: SgfHeaderScan?

    /// Largest SGF we will accept, so a hostile page cannot balloon the appex.
    private static let maxSgfBytes = 1 << 20

    // MARK: - Entry point

    func handle(_ request: AnalysisRequest) -> AnalysisResponse {
        switch request {
        case let .start(sgf, sgfHash, _, _):
            return start(sgf: sgf, sgfHash: sgfHash)
        case let .query(gameId, moveIndex, _, budget):
            return query(gameId: gameId, moveIndex: moveIndex, budget: budget)
        case .ping:
            // A pure status read: it must NOT start the engine. The panel pings
            // when its engine-details disclosure is opened without a known
            // version, and a curiosity tap must never pull ~55 MB into a
            // process with a hard 80 MB ceiling.
            return .pong(engineState: IOSEngineController.shared.currentState.rawValue)
        case let .openInApp(sgf):
            return openInApp(sgf: sgf)
        case .stop:
            // Abandon whatever is searching. The page sends this on teardown,
            // and (once the panel deepens on dwell) whenever the reader moves
            // on from the position being deepened — a 3 s search that nobody is
            // looking at any more only delays the one they are.
            IOSEngineController.shared.cancelAnalysis()
            return .pong(engineState: IOSEngineController.shared.currentState.rawValue)
        case .poll, .navigate:
            // Sweep-era commands: iOS has no background sweep, so the page
            // drives one .query per position instead.
            return .error(code: .badRequest, message: "unsupported on iOS", retryable: false)
        }
    }

    // MARK: - start

    private func start(sgf: String, sgfHash: String) -> AnalysisResponse {
        guard sgf.utf8.count <= Self.maxSgfBytes else {
            return .error(code: .sgfParse, message: "SGF too large", retryable: false)
        }
        guard let scan = SgfHeaderScan(sgf: sgf) else {
            return .error(code: .sgfParse, message: "could not parse the SGF", retryable: false)
        }
        // The engine launched with a 19x19 NN buffer; anything larger cannot be
        // evaluated (and web Go is 19x19 or smaller in practice).
        guard scan.boardWidth <= 19, scan.boardHeight <= 19 else {
            return .error(code: .boardTooLarge,
                          message: "boards larger than 19x19 are not supported in Safari",
                          retryable: false)
        }

        guard let path = spoolSgf(sgf, sgfHash: sgfHash) else {
            return .error(code: .spoolWrite, message: "could not stage the SGF", retryable: true)
        }

        lock.lock()
        activeHash = sgfHash
        activeSgfPath = path
        activeScan = scan
        lock.unlock()

        // Start the engine now so the boot overlaps the reader getting oriented.
        IOSEngineController.shared.ensureBooting()

        let cached = !loadCache(sgfHash: sgfHash).isEmpty
        return .gameAccepted(gameId: sgfHash,
                             boardWidth: scan.boardWidth,
                             boardHeight: scan.boardHeight,
                             moveCount: scan.moveCount,
                             komi: scan.komi,
                             rules: scan.rules,
                             cached: cached)
    }

    // MARK: - query (the single-position workhorse)

    private func query(gameId: String, moveIndex: Int, budget: AnalysisBudget) -> AnalysisResponse {
        lock.lock()
        let hash = activeHash
        let path = activeSgfPath
        let scan = activeScan
        lock.unlock()

        guard hash == gameId, let path, let scan else {
            // The appex was recycled and lost the game. Restart is idempotent:
            // the page re-sends `start` (served from cache) and retries.
            return .error(code: .unknownGame, message: "send start first", retryable: true)
        }
        guard moveIndex >= 0, moveIndex <= scan.moveCount else {
            return .error(code: .badRequest, message: "move index out of range", retryable: false)
        }

        // Cache first — a revisited position must not re-run the engine.
        var cache = loadCache(sgfHash: gameId)
        if let hit = cache[String(moveIndex)] {
            return .results(gameId: gameId, nextSeq: hit.seq,
                            sweepDone: cache.count, sweepTotal: scan.moveCount + 1,
                            moves: [hit])
        }

        let engine = IOSEngineController.shared
        engine.ensureBooting()
        switch engine.currentState {
        case .cold, .booting:
            // Retryable: the cold CoreML convert must not block a native message.
            return .error(code: .warmingUp, message: "starting the engine", retryable: true)
        case .failed:
            return .error(code: .engineDown, message: "the engine failed to start", retryable: false)
        case .ready:
            break
        }

        guard let (parsed, toMove) = engine.analyze(sgfPath: path,
                                                    moveIndex: moveIndex,
                                                    scan: scan,
                                                    visits: visits(for: budget)),
              let root = parsed.rootInfo else {
            // A CoreML prediction fault or a stalled search lands here rather
            // than crashing the extension.
            return .error(code: .engineDown, message: "analysis unavailable", retryable: true)
        }

        let analysis = makeMoveAnalysis(parsed: parsed, root: root,
                                        toMove: toMove, scan: scan, moveIndex: moveIndex)
        cache[String(moveIndex)] = analysis
        saveCache(cache, sgfHash: gameId)

        return .results(gameId: gameId, nextSeq: analysis.seq,
                        sweepDone: cache.count, sweepTotal: scan.moveCount + 1,
                        moves: [analysis])
    }

    private func visits(for budget: AnalysisBudget) -> Int {
        // Deliberately far below the macOS sweep budgets: this engine runs
        // under an 80 MB cap and a scrub should feel immediate.
        switch budget {
        case .fast: 16
        case .normal: IOSEngineController.defaultVisits   // 32
        case .deep: 64
        }
    }

    /// Build the wire payload. Winrate-only by design: b24c64 has no reliable
    /// score head, and its ownership is fragile in fights — so scoreLeadB is
    /// reported as 0 and ownership is omitted entirely.
    private func makeMoveAnalysis(parsed: ParsedAnalysis,
                                  root: ParsedRootInfo,
                                  toMove: PlayerColor,
                                  scan: SgfHeaderScan,
                                  moveIndex: Int) -> MoveAnalysis {
        // The parser yields SIDE-TO-MOVE values; the wire contract is always
        // Black's perspective. `utilityLcb` is the deliberate exception — it
        // stays side-to-move because its only consumer is a per-position argmax
        // for the best-move ring, which a flip would invert.
        let candidates = parsed.info
            .sorted { $0.value.visits > $1.value.visits }
            .prefix(Self.maxCandidates)
            .enumerated()
            .map { order, entry in
                Candidate(move: Self.vertex(for: entry.key, scan: scan),
                          visits: entry.value.visits,
                          winrateB: AnalysisMath.blackWinrate(entry.value.winrate, toMove: toMove),
                          scoreLeadB: 0,
                          utilityLcb: entry.value.utilityLcb,
                          order: order,
                          pv: entry.value.pv)
            }

        return MoveAnalysis(seq: moveIndex,
                            moveIndex: moveIndex,
                            phase: .deepen,
                            toMove: toMove.symbol ?? "b",
                            visits: root.visits,
                            winrateB: AnalysisMath.blackWinrate(root.winrate, toMove: toMove),
                            scoreLeadB: 0,
                            candidates: Array(candidates),
                            ownership: nil,
                            played: nil)
    }

    /// The board shows a handful of marks on a phone screen; 12 is plenty and
    /// keeps the cached payload small.
    private static let maxCandidates = 12

    /// GTP vertex for a parser board point ("Q16"; "I" skipped; "pass").
    private static func vertex(for point: BoardPoint, scan: SgfHeaderScan) -> String {
        if point.isPass(width: scan.boardWidth, height: scan.boardHeight) { return "pass" }
        let letters = "ABCDEFGHJKLMNOPQRSTUVWXYZ"
        guard point.x >= 0, point.x < letters.count else { return "pass" }
        let column = letters[letters.index(letters.startIndex, offsetBy: point.x)]
        return "\(column)\(point.y + 1)"
    }

    // MARK: - Open in KataGo Anytime

    /// Spool the SGF into the App Group and hand the page a deep link. iOS
    /// extensions cannot open URLs themselves (no NSWorkspace, no
    /// UIApplication.shared), so the content script performs the navigation.
    private func openInApp(sgf: String) -> AnalysisResponse {
        guard let spoolDir = GameDeepLink.messagesHandoffDirectory() else {
            return .error(code: .spoolWrite, message: "App Group unavailable", retryable: false)
        }
        let fileName = UUID().uuidString + ".sgf"
        do {
            try FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)
            try sgf.write(to: spoolDir.appending(path: fileName), atomically: true, encoding: .utf8)
        } catch {
            return .error(code: .spoolWrite, message: String(describing: error), retryable: true)
        }
        lastHandoffURL = GameDeepLink.importSgfURL(fileName: fileName).absoluteString
        return .opened
    }

    /// Set alongside `.opened`; the handler adds it to the reply so the page
    /// knows where to navigate. (`AnalysisResponse.opened` carries no payload,
    /// and it is shared with macOS, which does its own opening.)
    private(set) var lastHandoffURL: String?

    // MARK: - SGF staging

    private func spoolSgf(_ sgf: String, sgfHash: String) -> String? {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SafariAnalysisSgf", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(sgfHash).sgf")
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return url.path(percentEncoded: false)
        }
        do {
            try sgf.write(to: url, atomically: true, encoding: .utf8)
            return url.path(percentEncoded: false)
        } catch {
            log.error("SGF spool failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - App Group result cache

    private func cacheURL(sgfHash: String) -> URL? {
        guard let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedModelContainer.appGroupID) else { return nil }
        let directory = base.appending(path: "Library/Caches/SafariAnalysisCacheIOS")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(sgfHash)-v1.json")
    }

    private func loadCache(sgfHash: String) -> [String: MoveAnalysis] {
        guard let url = cacheURL(sgfHash: sgfHash),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode([String: MoveAnalysis].self, from: data)
        else { return [:] }
        return payload
    }

    private func saveCache(_ cache: [String: MoveAnalysis], sgfHash: String) {
        guard let url = cacheURL(sgfHash: sgfHash),
              let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
