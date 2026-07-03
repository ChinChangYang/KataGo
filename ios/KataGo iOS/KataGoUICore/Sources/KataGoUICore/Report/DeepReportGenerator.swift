//
//  DeepReportGenerator.swift
//  KataGoUICore
//
//  Serializes the Deep Report probe sequence over the app's single GTP stream.
//
//  Invariants honored here (see the design spec):
//  - Probes use kata-analyze ONLY (never search-analyze — no stray "play"
//    replies to guard against).
//  - The first probe command implicitly cancels the user's live kata-analyze;
//    live collection is bypassed via gobanState.reportGenerationActive (the
//    GameSession guard), so no waitingForAnalysis edges fire mid-report.
//  - Engine game state is mutated ONLY by the tenuki `play`s, tracked by
//    `outstandingPlays` (never exceeds 1) so every exit path can restore.
//  - All parsing uses nextColor .white so values stay White-perspective
//    (reportAnalysisWinratesAs = WHITE); normalization to the reported side
//    happens exactly once, here, via ReportPerspective.
//

import Foundation

/// Wall-clock budgets for the probe stages; injectable so tests substitute 0.
public struct ReportBudgets: Sendable {
    public let snapshot: TimeInterval
    public let pass: TimeInterval
    public let tenuki: TimeInterval
    public let candidateCount: Int

    public init(snapshot: TimeInterval, pass: TimeInterval,
                tenuki: TimeInterval, candidateCount: Int) {
        self.snapshot = snapshot
        self.pass = pass
        self.tenuki = tenuki
        self.candidateCount = candidateCount
    }

    public static let standard = ReportBudgets(snapshot: ReportConstants.snapshotBudget,
                                               pass: ReportConstants.passBudget,
                                               tenuki: ReportConstants.tenukiBudget,
                                               candidateCount: ReportConstants.candidateCount)
}

/// Injectable wait so tests can feed scripted replies instead of sleeping.
public typealias ReportSleeper = @MainActor (TimeInterval) async throws -> Void

struct ReportError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

@MainActor
public final class DeepReportGenerator {
    private let messageList: MessageList
    private let budgets: ReportBudgets
    private let sleeper: ReportSleeper
    private let collector = ReportCollector()
    private var outstandingPlays = 0
    private var priorObserver: ((String) -> Void)?
    private var reportSideSymbol = "b"

    public init(messageList: MessageList,
                budgets: ReportBudgets = .standard,
                sleeper: @escaping ReportSleeper = { try await Task.sleep(for: .seconds($0)) }) {
        self.messageList = messageList
        self.budgets = budgets
        self.sleeper = sleeper
    }

    public func generate(model: DeepReportModel, gameRecord: GameRecord) async {
        guard let session = messageList.session else {
            model.stage = .failed("No engine session.")
            return
        }
        guard !session.gobanState.reportGenerationActive else { return }

        let sideToMove = session.player.nextColorFromShowBoard
        reportSideSymbol = sideToMove == .black ? "b" : "w"
        seedModel(model, session: session, gameRecord: gameRecord, sideToMove: sideToMove)

        collector.reset()
        outstandingPlays = 0
        priorObserver = session.lineObserver
        let collector = self.collector
        session.lineObserver = { line in collector.ingest(line: line) }
        session.gobanState.reportGenerationActive = true

        do {
            try await runProbes(model: model, session: session, sideToMove: sideToMove)
            restore(session: session, gameRecord: gameRecord)
            if gameRecord.concreteConfig.useLLM {
                model.stage = .narrating
                await ReportNarrator.narrate(model: model,
                                             tone: gameRecord.concreteConfig.tone,
                                             temperature: Double(gameRecord.concreteConfig.temperature))
            }
            model.stage = .complete
        } catch is CancellationError {
            restore(session: session, gameRecord: gameRecord)
            model.stage = .cancelled
        } catch let error as ReportError {
            restore(session: session, gameRecord: gameRecord)
            model.stage = .failed(error.message)
        } catch {
            restore(session: session, gameRecord: gameRecord)
            model.stage = .failed(error.localizedDescription)
        }
    }

    // MARK: - Stages

    private func runProbes(model: DeepReportModel,
                           session: GameSession,
                           sideToMove: PlayerColor) async throws {
        let width = model.boardWidth
        let height = model.boardHeight
        let parser = AnalysisLineParser(boardWidth: width, boardHeight: height, nextColor: .white)
        let mySymbol = sideToMove == .black ? "b" : "w"
        let oppSymbol = sideToMove == .black ? "w" : "b"

        // Stage 1: snapshot (zero mutation) — candidates, PVs, root + subtree ownership.
        model.stage = .snapshot
        send("kata-set-param maxVisits \(GtpCommandBuilder.unboundedMaxVisits)", stage: nil)
        send("kata-analyze interval \(ReportConstants.probeInterval) maxmoves \(ReportConstants.probeMaxMoves) ownership true movesOwnership true rootInfo true",
             stage: .snapshot)
        try await sleeper(budgets.snapshot)
        try checkEngineError()
        send("stop", stage: nil)
        guard let snapshotLine = collector.latestLine(for: .snapshot) else {
            throw ReportError("The engine produced no analysis for this position.")
        }
        let snapshot = parser.parse(message: snapshotLine)
        guard let rootInfo = snapshot.rootInfo else {
            throw ReportError("The engine's analysis carried no root values.")
        }
        let position = PositionSummary(
            winrate: ReportPerspective.winrate(rootInfo.winrate, for: sideToMove),
            scoreLead: ReportPerspective.score(rootInfo.scoreLead, for: sideToMove),
            visits: rootInfo.visits)
        model.position = position
        model.candidates = buildCandidates(from: snapshot, position: position,
                                           sideToMove: sideToMove, width: width, height: height)

        // Stage 2: pass probe (zero mutation) — opponent to move on the same board.
        model.stage = .passProbe
        send("kata-analyze \(oppSymbol) interval \(ReportConstants.probeInterval) maxmoves \(ReportConstants.probeMaxMoves) ownership true rootInfo true",
             stage: .passProbe)
        try await sleeper(budgets.pass)
        try checkEngineError()
        send("stop", stage: nil)
        if let passLine = collector.latestLine(for: .passProbe) {
            let passParsed = parser.parse(message: passLine)
            model.passComparison = buildPassComparison(passParsed: passParsed,
                                                       snapshot: snapshot,
                                                       sideToMove: sideToMove,
                                                       best: model.candidates.first,
                                                       width: width, height: height)
        }

        // Stage 3: tenuki probes — play the candidate, analyze with the SAME side
        // to move (= opponent ignored it), undo. The only state mutation.
        for (index, candidate) in model.candidates.enumerated() {
            guard candidate.vertex != "pass" else { continue }
            model.stage = .tenuki(index)
            send("play \(mySymbol) \(candidate.vertex)", stage: nil)
            outstandingPlays = 1
            send("kata-analyze \(mySymbol) interval \(ReportConstants.probeInterval) maxmoves \(ReportConstants.probeMaxMoves) ownership true rootInfo true",
                 stage: .tenuki(index))
            try await sleeper(budgets.tenuki)
            try checkEngineError()
            send("stop", stage: nil)
            send("undo", stage: nil)
            outstandingPlays = 0
            if let line = collector.latestLine(for: .tenuki(index)) {
                let parsed = parser.parse(message: line)
                model.candidates[index].tenuki = buildTenuki(parsed: parsed,
                                                             sideToMove: sideToMove,
                                                             width: width, height: height)
            }
        }
    }

    // MARK: - Builders (White-perspective in, side-to-move out)

    private func buildCandidates(from snapshot: ParsedAnalysis,
                                 position: PositionSummary,
                                 sideToMove: PlayerColor,
                                 width: Int, height: Int) -> [CandidateReport] {
        rankedEntries(in: snapshot, width: width, height: height)
            .prefix(budgets.candidateCount)
            .map { vertex, info in
                let winrate = ReportPerspective.winrate(info.winrate, for: sideToMove)
                let scoreLead = ReportPerspective.score(info.scoreLead, for: sideToMove)
                return CandidateReport(
                    vertex: vertex,
                    visits: info.visits,
                    winrate: winrate,
                    scoreLead: scoreLead,
                    winrateDelta: winrate - position.winrate,
                    scoreLeadDelta: scoreLead - position.scoreLead,
                    pv: info.pv,
                    ownershipDelta: OwnershipDelta.grid(base: snapshot.rawOwnership,
                                                        probe: info.movesOwnership ?? [],
                                                        width: width, height: height),
                    tenuki: nil)
            }
    }

    private func buildPassComparison(passParsed: ParsedAnalysis,
                                     snapshot: ParsedAnalysis,
                                     sideToMove: PlayerColor,
                                     best: CandidateReport?,
                                     width: Int, height: Int) -> PassComparison? {
        guard let rootInfo = passParsed.rootInfo,
              let punishment = rankedEntries(in: passParsed, width: width, height: height).first
        else { return nil }
        let winrate = ReportPerspective.winrate(rootInfo.winrate, for: sideToMove)
        let scoreLead = ReportPerspective.score(rootInfo.scoreLead, for: sideToMove)
        // Best-candidate subtree ownership minus the pass scenario's root
        // ownership: what playing (vs passing) does to each point.
        let bestOwnership = bestCandidateOwnership(snapshot: snapshot, best: best, width: width, height: height)
        let delta = OwnershipDelta.grid(base: passParsed.rawOwnership,
                                        probe: bestOwnership,
                                        width: width, height: height)
        return PassComparison(
            punishmentVertex: punishment.vertex,
            winrate: winrate,
            scoreLead: scoreLead,
            winrateDeltaVsBest: (best?.winrate ?? winrate) - winrate,
            scoreLeadDeltaVsBest: (best?.scoreLead ?? scoreLead) - scoreLead,
            ownershipDelta: delta,
            contestedPoints: OwnershipDelta.contestedPoints(in: delta, width: width, height: height))
    }

    private func bestCandidateOwnership(snapshot: ParsedAnalysis,
                                        best: CandidateReport?,
                                        width: Int, height: Int) -> [Float] {
        guard let best,
              let entry = rankedEntries(in: snapshot, width: width, height: height)
                  .first(where: { $0.vertex == best.vertex }),
              let movesOwnership = entry.info.movesOwnership
        else { return snapshot.rawOwnership }
        return movesOwnership
    }

    private func buildTenuki(parsed: ParsedAnalysis,
                             sideToMove: PlayerColor,
                             width: Int, height: Int) -> TenukiFollowUp? {
        guard let rootInfo = parsed.rootInfo,
              let reply = rankedEntries(in: parsed, width: width, height: height).first
        else { return nil }
        return TenukiFollowUp(
            vertex: reply.vertex,
            winrate: ReportPerspective.winrate(rootInfo.winrate, for: sideToMove),
            scoreLead: ReportPerspective.score(rootInfo.scoreLead, for: sideToMove),
            visits: rootInfo.visits,
            pv: reply.info.pv)
    }

    /// Candidates ordered strongest-first, mirroring Analysis.candidateMoves:
    /// visits desc, then utilityLcb desc, then vertex. "pass" points convert to
    /// the literal vertex "pass" instead of being dropped.
    private func rankedEntries(in parsed: ParsedAnalysis,
                               width: Int, height: Int) -> [(vertex: String, info: AnalysisInfo)] {
        parsed.info.compactMap { point, info -> (String, AnalysisInfo)? in
            if point == BoardPoint.pass(width: width, height: height) {
                return ("pass", info)
            }
            guard let vertex = Coordinate(x: point.x, y: point.y + 1,
                                          width: width, height: height)?.move else { return nil }
            return (vertex, info)
        }
        .sorted {
            if $0.1.visits != $1.1.visits { return $0.1.visits > $1.1.visits }
            if $0.1.utilityLcb != $1.1.utilityLcb { return $0.1.utilityLcb > $1.1.utilityLcb }
            return $0.0 < $1.0
        }
        .map { (vertex: $0.0, info: $0.1) }
    }

    // MARK: - Plumbing

    private func send(_ command: String, stage: ReportStage?) {
        collector.willSend(stage: stage)
        messageList.appendAndSend(command: command)
    }

    private func checkEngineError() throws {
        if collector.sawError {
            throw ReportError("The engine reported an error while probing.")
        }
    }

    private func seedModel(_ model: DeepReportModel,
                           session: GameSession,
                           gameRecord: GameRecord,
                           sideToMove: PlayerColor) {
        model.stage = .snapshot
        // The spec promises the branch move number while a branch is active —
        // `gameRecord.currentIndex` is frozen at the divergence point then.
        model.moveNumber = session.gobanState.isBranchActive
            ? session.gobanState.branchIndex
            : gameRecord.currentIndex
        model.visitsPerSecondText = session.analysis.visitsPerSecond > 0
            ? session.analysis.visitsPerSecondText : nil
        model.sideToMove = sideToMove
        model.boardWidth = Int(session.board.width)
        model.boardHeight = Int(session.board.height)
        model.blackVertices = vertices(of: session.stones.blackPoints,
                                       width: model.boardWidth, height: model.boardHeight)
        model.whiteVertices = vertices(of: session.stones.whitePoints,
                                       width: model.boardWidth, height: model.boardHeight)

        // A reused model must never show a previous run's results.
        model.position = nil
        model.candidates = []
        model.passComparison = nil
        model.narrative = ""
        model.narrativeUnavailableReason = nil
    }

    private func vertices(of points: [BoardPoint], width: Int, height: Int) -> [String] {
        points.compactMap { Coordinate(x: $0.x, y: $0.y + 1, width: width, height: height)?.move }
    }

    /// Single restore path for every exit: undo any outstanding probe play,
    /// stop whatever streams, hand the line stream back, unfreeze live
    /// collection, and re-arm via the standard post-execution sequence (which
    /// resets the sticky maxVisits before kata-analyze).
    private func restore(session: GameSession, gameRecord: GameRecord) {
        session.lineObserver = priorObserver
        priorObserver = nil
        session.gobanState.reportGenerationActive = false
        messageList.appendAndSend(command: "stop")
        while outstandingPlays > 0 {
            messageList.appendAndSend(command: "undo")
            outstandingPlays -= 1
        }
        // The pass probe (`kata-analyze <opponent>`) persistently flips the
        // engine's root player (AsyncBot keeps the last analyzed pla; a plain
        // kata-analyze reuses bot->getRootPla()). A played-then-undone pass
        // re-anchors the side to move without touching the position: undo
        // makes the undone move's player to-move again. Idempotent on paths
        // whose tenuki undo already restored it; essential when the pass
        // probe was the last engine action (abort mid-pass-probe, or all
        // candidates were "pass").
        messageList.appendAndSend(command: "play \(reportSideSymbol) pass")
        messageList.appendAndSend(command: "undo")
        session.gobanState.sendPostExecutionCommands(config: gameRecord.concreteConfig,
                                                     messageList: messageList,
                                                     player: session.player)
    }
}
