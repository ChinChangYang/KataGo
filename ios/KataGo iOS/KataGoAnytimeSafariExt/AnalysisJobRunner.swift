//
//  AnalysisJobRunner.swift
//  KataGoAnytimeSafariExt
//
//  The native analysis service behind the wire schema. One instance per appex
//  process; every request must be servable even if this is a brand-new
//  process (Safari recycles the appex freely), which is why completed results
//  are persisted incrementally to the App Group and `start` is idempotent by
//  sgfHash.
//
//  Concurrency model (mirrors the KataGoEngineProcess house pattern):
//  `@unchecked Sendable` with ALL mutable state guarded by `condition`. The
//  engine conversation is blocking-synchronous by nature (NSCondition line
//  reads), so it runs on one dedicated worker thread that owns the
//  ExtensionEngineController exclusively; request handlers only mutate the
//  guarded queue state and signal the worker. Navigation preemption is
//  between-position (a position costs a few seconds at most).
//

import Foundation
import AppKit
import KataGoAnalysisKit
import KataGoGameStore
import os.log

private let runnerLog = Logger(subsystem: "chinchangyang.KataGo-iOS.tw.safari",
                               category: "runner")

final class AnalysisJobRunner: @unchecked Sendable {
    static let shared = AnalysisJobRunner()

    private struct Game {
        let sgfHash: String
        let sgfPath: URL
        let scan: SgfHeaderScan
        var budget: AnalysisBudget
        var planner: SweepPlanner
        var outbox: AnalysisOutbox
        var sweepActive: Bool
        var pendingDeepen: (moveIndex: Int, budget: AnalysisBudget)?
    }

    private let condition = NSCondition()
    private var game: Game?
    private var workerStarted = false
    private var lastRequestAt = Date()

    private let groupID = "group.chinchangyang.KataGo-iOS.tw"
    private let maxBoardEdge = 19
    private let sweepWallCap: TimeInterval = 3
    private let deepenWallCap: TimeInterval = 6
    private let idleReapAfter: TimeInterval = 300

    // MARK: - Request entry (any thread)

    func handle(_ request: AnalysisRequest) -> AnalysisResponse {
        condition.lock()
        lastRequestAt = Date()
        condition.unlock()

        switch request {
        case let .start(sgf, sgfHash, currentMoveIndex, budget):
            return start(sgf: sgf, sgfHash: sgfHash,
                         currentMoveIndex: currentMoveIndex, budget: budget)
        case let .poll(gameId, sinceSeq):
            return poll(gameId: gameId, sinceSeq: sinceSeq)
        case let .navigate(gameId, moveIndex):
            return requestDeepen(gameId: gameId, moveIndex: moveIndex,
                                 budgetOverride: nil, recenter: true)
        case let .query(gameId, moveIndex, _, budget):
            return requestDeepen(gameId: gameId, moveIndex: moveIndex,
                                 budgetOverride: budget, recenter: false)
        case let .stop(gameId):
            return stopSweep(gameId: gameId)
        case .ping:
            condition.lock()
            defer { condition.unlock() }
            return .pong(engineState: workerEngineStateDescription)
        case let .openInApp(sgf):
            return openInApp(sgf: sgf)
        }
    }

    // MARK: - Commands

    private func start(sgf: String, sgfHash: String, currentMoveIndex: Int,
                       budget: AnalysisBudget) -> AnalysisResponse {
        guard sgf.utf8.count <= 2_000_000 else {
            return .error(code: .badRequest, message: "SGF too large", retryable: false)
        }
        guard let scan = SgfHeaderScan(sgf: sgf) else {
            return .error(code: .sgfParse, message: "not an SGF game", retryable: false)
        }
        guard scan.boardWidth <= maxBoardEdge, scan.boardHeight <= maxBoardEdge else {
            return .error(code: .boardTooLarge,
                          message: "boards larger than \(maxBoardEdge)×\(maxBoardEdge) are not supported yet",
                          retryable: false)
        }

        condition.lock()
        defer { condition.unlock() }

        if var existing = game, existing.sgfHash == sgfHash {
            // Idempotent restart of the same game: refresh budget/center only.
            existing.budget = budget
            existing.planner.recenter(on: currentMoveIndex)
            existing.sweepActive = !existing.planner.isComplete
            game = existing
            condition.signal()
            return accepted(for: existing, cached: existing.outbox.lastSeq > 0)
        }
        if let existing = game, !existing.planner.isComplete,
           Date().timeIntervalSince(lastPollAt) < 15 {
            // Another live tab is mid-sweep on a different game; make the
            // newcomer retry instead of thrashing the engine between games.
            return .error(code: .busy, message: "another game is being analyzed",
                          retryable: true)
        }

        let sgfPath = FileManager.default.temporaryDirectory
            .appending(path: "kga-\(sgfHash.prefix(24)).sgf")
        do {
            try sgf.write(to: sgfPath, atomically: true, encoding: .utf8)
        } catch {
            return .error(code: .badRequest, message: "cannot stage SGF: \(error)",
                          retryable: true)
        }

        var planner = SweepPlanner(moveCount: scan.moveCount, currentIndex: currentMoveIndex)
        var outbox = AnalysisOutbox()
        if let cached = loadCache(sgfHash: sgfHash) {
            for entry in cached.entries {
                let stamped = outbox.append(entry)
                planner.markCompleted(stamped.moveIndex)
            }
        }
        let fresh = Game(sgfHash: sgfHash, sgfPath: sgfPath, scan: scan,
                         budget: budget, planner: planner, outbox: outbox,
                         sweepActive: !planner.isComplete,
                         pendingDeepen: (currentMoveIndex, budget))
        game = fresh
        ensureWorker()
        condition.signal()
        return accepted(for: fresh, cached: outbox.lastSeq > 0)
    }

    private func accepted(for game: Game, cached: Bool) -> AnalysisResponse {
        .gameAccepted(gameId: game.sgfHash,
                      boardWidth: game.scan.boardWidth,
                      boardHeight: game.scan.boardHeight,
                      moveCount: game.scan.moveCount,
                      komi: game.scan.komi,
                      rules: game.scan.rules,
                      cached: cached)
    }

    private var lastPollAt = Date.distantPast

    private func poll(gameId: String, sinceSeq: Int) -> AnalysisResponse {
        condition.lock()
        defer { condition.unlock() }
        lastPollAt = Date()
        guard let game, game.sgfHash == gameId else {
            return .error(code: .unknownGame, message: "no such game in this process",
                          retryable: true)
        }
        return .results(gameId: game.sgfHash,
                        nextSeq: game.outbox.lastSeq,
                        sweepDone: game.planner.done,
                        sweepTotal: game.planner.total,
                        moves: game.outbox.entries(after: sinceSeq))
    }

    private func requestDeepen(gameId: String, moveIndex: Int,
                               budgetOverride: AnalysisBudget?,
                               recenter: Bool) -> AnalysisResponse {
        condition.lock()
        defer { condition.unlock() }
        guard var current = game, current.sgfHash == gameId else {
            return .error(code: .unknownGame, message: "no such game in this process",
                          retryable: true)
        }
        let clamped = min(max(0, moveIndex), current.scan.moveCount)
        if recenter { current.planner.recenter(on: clamped) }
        current.pendingDeepen = (clamped, budgetOverride ?? current.budget)
        game = current
        ensureWorker()
        condition.signal()
        return .results(gameId: current.sgfHash,
                        nextSeq: current.outbox.lastSeq,
                        sweepDone: current.planner.done,
                        sweepTotal: current.planner.total,
                        moves: [])
    }

    private func stopSweep(gameId: String) -> AnalysisResponse {
        condition.lock()
        defer { condition.unlock() }
        guard var current = game, current.sgfHash == gameId else {
            return .error(code: .unknownGame, message: "no such game in this process",
                          retryable: true)
        }
        current.sweepActive = false
        current.pendingDeepen = nil
        game = current
        return .results(gameId: current.sgfHash,
                        nextSeq: current.outbox.lastSeq,
                        sweepDone: current.planner.done,
                        sweepTotal: current.planner.total,
                        moves: [])
    }

    private func openInApp(sgf: String) -> AnalysisResponse {
        guard let spoolDir = GameDeepLink.messagesHandoffDirectory() else {
            return .error(code: .spoolWrite, message: "App Group unavailable",
                          retryable: false)
        }
        let fileName = UUID().uuidString + ".sgf"
        do {
            try FileManager.default.createDirectory(at: spoolDir,
                                                    withIntermediateDirectories: true)
            try sgf.write(to: spoolDir.appending(path: fileName),
                          atomically: true, encoding: .utf8)
        } catch {
            return .error(code: .spoolWrite, message: String(describing: error),
                          retryable: true)
        }
        let url = GameDeepLink.importSgfURL(fileName: fileName)
        var opened = false
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            opened = error == nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return opened ? .opened
                      : .error(code: .openFailed, message: "could not launch the app",
                               retryable: true)
    }

    // MARK: - Worker thread

    private var engineStateForDisplay: String = ExtensionEngineController.State.cold.rawValue
    private var workerEngineStateDescription: String { engineStateForDisplay }

    private func ensureWorker() {
        guard !workerStarted else { return }
        workerStarted = true
        Thread.detachNewThread { [weak self] in
            Thread.current.name = "kga.analysis.worker"
            self?.workerLoop()
        }
    }

    private func workerLoop() {
        let controller = ExtensionEngineController(supportDirectory: supportDirectory())
        var loadedGameHash: String?

        while true {
            // Wait for work: a pending deepen or an active sweep position.
            condition.lock()
            var job: (hash: String, sgfPath: URL, scan: SgfHeaderScan,
                      index: Int, phase: MoveAnalysis.Phase, budget: AnalysisBudget)?
            while job == nil {
                if let current = game {
                    if let deepen = current.pendingDeepen {
                        job = (current.sgfHash, current.sgfPath, current.scan,
                               deepen.moveIndex, .deepen, deepen.budget)
                        game?.pendingDeepen = nil
                    } else if current.sweepActive, let next = current.planner.nextIndex() {
                        job = (current.sgfHash, current.sgfPath, current.scan,
                               next, .sweep, current.budget)
                    }
                }
                if job == nil {
                    let idle = Date().timeIntervalSince(lastRequestAt)
                    if idle > idleReapAfter, controller.state == .ready {
                        condition.unlock()
                        controller.shutdown()
                        loadedGameHash = nil
                        condition.lock()
                        engineStateForDisplay = controller.state.rawValue
                    }
                    _ = condition.wait(until: Date().addingTimeInterval(60))
                }
            }
            condition.unlock()
            guard let job else { continue }

            let ready = controller.ensureReady()
            condition.lock()
            engineStateForDisplay = controller.state.rawValue
            condition.unlock()
            guard ready else {
                runnerLog.error("engine failed to come up; parking sweep")
                condition.lock()
                game?.sweepActive = false
                condition.unlock()
                continue
            }
            if loadedGameHash != job.hash { loadedGameHash = nil }

            if let result = analyzePosition(job: job, controller: controller) {
                loadedGameHash = job.hash
                condition.lock()
                if var current = game, current.sgfHash == job.hash {
                    let stamped = current.outbox.append(result)
                    current.planner.markCompleted(stamped.moveIndex)
                    if current.planner.isComplete { current.sweepActive = false }
                    game = current
                    condition.unlock()
                    persistCache(for: job.hash)
                } else {
                    condition.unlock()
                }
            } else {
                // loadsgf refused or the engine died mid-position: mark the
                // index done so the sweep cannot spin on a poison position.
                condition.lock()
                if var current = game, current.sgfHash == job.hash {
                    current.planner.markCompleted(job.index)
                    if current.planner.isComplete { current.sweepActive = false }
                    game = current
                }
                condition.unlock()
            }
        }
    }

    /// One position: loadsgf to the position BEFORE move index+1 (== after
    /// `index` moves; plain loadsgf for the final position), then a budgeted
    /// kata-analyze, normalized to the wire's Black perspective.
    private func analyzePosition(
        job: (hash: String, sgfPath: URL, scan: SgfHeaderScan,
              index: Int, phase: MoveAnalysis.Phase, budget: AnalysisBudget),
        controller: ExtensionEngineController
    ) -> MoveAnalysis? {
        let loadCommand = job.index < job.scan.moveCount
            ? "loadsgf \(job.sgfPath.path) \(job.index + 1)"
            : "loadsgf \(job.sgfPath.path)"
        guard case .ok = controller.turn(loadCommand) else { return nil }

        let toMove = job.scan.toMove(atMoveIndex: job.index)
        let targetVisits = job.phase == .deepen
            ? job.budget.deepenVisits : job.budget.sweepVisits
        let wallCap = job.phase == .deepen ? deepenWallCap : sweepWallCap
        guard let infoLine = controller.analyze(
            command: AnalysisCommand.analyze(interval: 20, maxMoves: 12),
            targetVisits: targetVisits,
            wallCap: wallCap) else { return nil }

        let parser = AnalysisLineParser(boardWidth: job.scan.boardWidth,
                                        boardHeight: job.scan.boardHeight,
                                        nextColor: toMove)
        let parsed = parser.parse(message: infoLine)
        guard let root = parsed.rootInfo else { return nil }

        // Parser output is side-to-move perspective; the wire is Black's.
        let candidates = parsed.info
            .sorted { $0.value.visits > $1.value.visits }
            .prefix(12)
            .enumerated()
            .map { order, entry in
                Candidate(
                    move: Self.vertex(for: entry.key, scan: job.scan),
                    visits: entry.value.visits,
                    winrateB: AnalysisMath.blackWinrate(entry.value.winrate, toMove: toMove),
                    scoreLeadB: AnalysisMath.blackScoreLead(entry.value.scoreLead, toMove: toMove),
                    order: order,
                    pv: entry.value.pv)
            }

        return MoveAnalysis(
            moveIndex: job.index,
            phase: job.phase,
            toMove: toMove.symbol ?? "b",
            visits: root.visits,
            winrateB: AnalysisMath.blackWinrate(root.winrate, toMove: toMove),
            scoreLeadB: AnalysisMath.blackScoreLead(root.scoreLead, toMove: toMove),
            candidates: Array(candidates),
            ownershipW: parsed.rawOwnership.isEmpty ? nil : parsed.rawOwnership)
    }

    /// GTP vertex for a parser board point ("Q16"; "I" skipped; "pass").
    private static func vertex(for point: BoardPoint, scan: SgfHeaderScan) -> String {
        if point.isPass(width: scan.boardWidth, height: scan.boardHeight) { return "pass" }
        let letters = "ABCDEFGHJKLMNOPQRSTUVWXYZ"
        guard point.x >= 0, point.x < letters.count else { return "pass" }
        let column = letters[letters.index(letters.startIndex, offsetBy: point.x)]
        return "\(column)\(point.y + 1)"
    }

    // MARK: - Persistent cache (App Group)

    private struct CachePayload: Codable {
        var sgfHash: String
        var entries: [MoveAnalysis]
    }

    private func supportDirectory() -> URL? {
        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        let directory = base.appending(path: "Library/Caches/SafariAnalysisCache")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory
    }

    private func cacheURL(sgfHash: String) -> URL? {
        supportDirectory()?.appending(path: "\(sgfHash.prefix(64)).json")
    }

    private func loadCache(sgfHash: String) -> CachePayload? {
        guard let url = cacheURL(sgfHash: sgfHash),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data),
              payload.sgfHash == sgfHash else { return nil }
        return payload
    }

    /// Latest-entry-per-position snapshot, written after every completed
    /// position so an appex kill mid-sweep resumes instead of recomputing.
    private func persistCache(for sgfHash: String) {
        condition.lock()
        guard let current = game, current.sgfHash == sgfHash else {
            condition.unlock()
            return
        }
        var newest: [Int: MoveAnalysis] = [:]
        for index in 0...current.scan.moveCount {
            if let entry = current.outbox.latest(forMoveIndex: index) {
                newest[index] = entry
            }
        }
        condition.unlock()
        let payload = CachePayload(sgfHash: sgfHash,
                                   entries: newest.keys.sorted().compactMap { newest[$0] })
        guard let url = cacheURL(sgfHash: sgfHash),
              let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
