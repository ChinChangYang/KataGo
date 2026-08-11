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

    /// Refine's escalated budgets: wall-clock stages scale linearly (visits
    /// scale with time), candidateCount stays fixed.
    public func scaled(by factor: Int) -> ReportBudgets {
        ReportBudgets(snapshot: snapshot * TimeInterval(factor),
                      pass: pass * TimeInterval(factor),
                      tenuki: tenuki * TimeInterval(factor),
                      candidateCount: candidateCount)
    }
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
        guard !session.gobanState.reportGenerationActive else {
            // Settle the stage: a bare return leaves .idle, on which a
            // broadcast cycle's "wait for a landed/settled model" poll loop
            // would spin forever. Harmless on iOS — this guard only trips when
            // another report is genuinely active.
            model.stage = .failed("Another report is active.")
            return
        }

        let sideToMove = session.player.nextColorFromShowBoard
        reportSideSymbol = sideToMove == .black ? "b" : "w"
        seedModel(model, session: session, gameRecord: gameRecord, sideToMove: sideToMove)

        do {
            try await withProbeSession(session: session) {
                try await runProbes(model: model, session: session,
                                    gameRecord: gameRecord, sideToMove: sideToMove)
            }
            await renarrate(model: model, gameRecord: gameRecord)
            model.stage = .complete
        } catch is CancellationError {
            model.stage = .cancelled
        } catch let error as ReportError {
            model.stage = .failed(error.message)
        } catch {
            model.stage = .failed(error.localizedDescription)
        }
    }

    /// The hijack/restore envelope every probe session runs inside: freezes
    /// live analysis collection, routes reply lines into the collector, runs
    /// `body`, and guarantees the single `restore` path on every exit
    /// (success, cancellation, engine error).
    private func withProbeSession(session: GameSession,
                                  body: () async throws -> Void) async throws {
        collector.reset()
        outstandingPlays = 0
        priorObserver = session.lineObserver
        let collector = self.collector
        session.lineObserver = { line in collector.ingest(line: line) }
        session.gobanState.reportGenerationActive = true
        defer { restore(session: session) }
        try await body()
    }

    /// Streams the narrative for the current report data (no engine access —
    /// always called after `restore`). Re-narration replaces the prior text.
    private func renarrate(model: DeepReportModel, gameRecord: GameRecord) async {
        guard gameRecord.concreteConfig.useLLM else { return }
        model.stage = .narrating
        model.narrative = ""
        await ReportNarrator.narrate(model: model,
                                     tone: gameRecord.concreteConfig.tone,
                                     temperature: Double(gameRecord.concreteConfig.temperature))
    }

    // MARK: - Stages

    private func runProbes(model: DeepReportModel,
                           session: GameSession,
                           gameRecord: GameRecord,
                           sideToMove: PlayerColor) async throws {
        let width = model.boardWidth
        let height = model.boardHeight
        let parser = AnalysisLineParser(boardWidth: width, boardHeight: height, nextColor: .white)
        let mySymbol = sideToMove == .black ? "b" : "w"
        let oppSymbol = sideToMove == .black ? "w" : "b"

        // Stage 1: snapshot (zero mutation) — candidates, PVs, root + subtree ownership.
        model.stage = .snapshot
        let snapshot = try await snapshotProbe(budget: budgets.snapshot, parser: parser)
        let position = try applySnapshot(snapshot, model: model, sideToMove: sideToMove,
                                         width: width, height: height)

        // Smart default for the Alternative slot: the game's actually-played
        // next move (when reviewing mid-game and it differs from the best
        // move) beats the engine's #2 pedagogically — "what you played vs.
        // what's best". Visit parity: whichever move fills the slot gets its
        // own forced probe; probe silence falls back to the snapshot cache.
        model.gameMoveVertex = gameMoveVertex(session: session,
                                              gameRecord: gameRecord,
                                              sideToMove: sideToMove)
        try await applyDefaultAlternative(model: model, position: position,
                                          budget: budgets.tenuki,
                                          mySymbol: mySymbol, parser: parser,
                                          sideToMove: sideToMove,
                                          width: width, height: height)

        // Stage 2: pass probe (zero mutation) — opponent to move on the same board.
        try await passStage(model: model, snapshot: snapshot, budget: budgets.pass,
                            oppSymbol: oppSymbol, parser: parser,
                            sideToMove: sideToMove, width: width, height: height)

        // Stage 3: tenuki probes — play the candidate, analyze with the SAME side
        // to move (= opponent ignored it), undo. The only state mutation.
        try await tenukiStage(model: model, budget: budgets.tenuki,
                              mySymbol: mySymbol, parser: parser,
                              sideToMove: sideToMove, width: width, height: height)
    }

    /// refine()'s probe pipeline: the same three stages at scaled budgets,
    /// replacing model sections as each lands — never wiping first. The
    /// Alternative slot is reconstructed around the new snapshot: a picked or
    /// game-move vertex is preserved and re-probed under visit parity; if it
    /// became the best move — or can't be re-analyzed — the slot falls back
    /// to the smart default (also parity-probed) with a notice.
    private func runRefineProbes(model: DeepReportModel,
                                 scaled: ReportBudgets,
                                 sideToMove: PlayerColor) async throws {
        let width = model.boardWidth
        let height = model.boardHeight
        let parser = AnalysisLineParser(boardWidth: width, boardHeight: height, nextColor: .white)
        let mySymbol = sideToMove == .black ? "b" : "w"
        let oppSymbol = sideToMove == .black ? "w" : "b"
        let preservedVertex = model.alternativeSource == .engine
            ? nil : model.candidates.last?.vertex
        let preservedSource = model.alternativeSource

        model.stage = .snapshot
        let snapshot = try await snapshotProbe(budget: scaled.snapshot, parser: parser)
        let position = try applySnapshot(snapshot, model: model, sideToMove: sideToMove,
                                         width: width, height: height)

        if let preserved = preservedVertex {
            if preserved == model.candidates.first?.vertex {
                model.transientNotice = "\(preserved) is now the Best Move — the alternative was reset."
                try await applyDefaultAlternative(model: model, position: position,
                                                  budget: scaled.tenuki, mySymbol: mySymbol,
                                                  parser: parser, sideToMove: sideToMove,
                                                  width: width, height: height)
            } else if try await applyAlternative(vertex: preserved, source: preservedSource,
                                                 budget: scaled.tenuki, model: model,
                                                 position: position, mySymbol: mySymbol,
                                                 parser: parser, sideToMove: sideToMove,
                                                 width: width, height: height) {
                // Preserved pick re-evaluated at the deeper budget (parity).
            } else {
                model.transientNotice = "The engine couldn't re-analyze \(preserved) — the alternative was reset."
                try await applyDefaultAlternative(model: model, position: position,
                                                  budget: scaled.tenuki, mySymbol: mySymbol,
                                                  parser: parser, sideToMove: sideToMove,
                                                  width: width, height: height)
            }
        } else {
            try await applyDefaultAlternative(model: model, position: position,
                                              budget: scaled.tenuki, mySymbol: mySymbol,
                                              parser: parser, sideToMove: sideToMove,
                                              width: width, height: height)
        }

        try await passStage(model: model, snapshot: snapshot, budget: scaled.pass,
                            oppSymbol: oppSymbol, parser: parser,
                            sideToMove: sideToMove, width: width, height: height)
        try await tenukiStage(model: model, budget: scaled.tenuki,
                              mySymbol: mySymbol, parser: parser,
                              sideToMove: sideToMove, width: width, height: height)
    }

    /// Visit parity (CONTEXT.md): evaluate `vertex` with its own forced probe
    /// so its visits land in the Best Move's ballpark; the cached snapshot
    /// entry only backstops a silent engine. Returns false when neither
    /// source can value the vertex (caller keeps the incumbent alternative).
    private func applyAlternative(vertex: String,
                                  source: AlternativeSource,
                                  budget: TimeInterval,
                                  model: DeepReportModel,
                                  position: PositionSummary,
                                  mySymbol: String,
                                  parser: AnalysisLineParser,
                                  sideToMove: PlayerColor,
                                  width: Int, height: Int) async throws -> Bool {
        let probed = try await forcedAlternativeInfo(vertex: vertex, budget: budget,
                                                     mySymbol: mySymbol, parser: parser,
                                                     width: width, height: height)
        let info = probed ?? model.snapshotEntries.first(where: { $0.vertex == vertex })?.info
        guard let info else { return false }
        setAlternative(buildCandidate(vertex: vertex, info: info,
                                      position: position, sideToMove: sideToMove,
                                      baseOwnership: model.snapshotOwnership,
                                      width: width, height: height),
                       source: source, model: model)
        return true
    }

    /// Seeds the Alternative slot with the smart default — the game's
    /// recorded move when it differs from the best move, else the engine's
    /// #2 — and evaluates it under visit parity. When nothing applies
    /// (single-candidate snapshot, or a silent probe with no cache) the
    /// snapshot's own #2 stays.
    private func applyDefaultAlternative(model: DeepReportModel,
                                         position: PositionSummary,
                                         budget: TimeInterval,
                                         mySymbol: String,
                                         parser: AnalysisLineParser,
                                         sideToMove: PlayerColor,
                                         width: Int, height: Int) async throws {
        model.alternativeSource = .engine
        let choice: (vertex: String, source: AlternativeSource)?
        if let gameMove = model.gameMoveVertex, gameMove != model.candidates.first?.vertex {
            choice = (gameMove, .gameMove)
        } else if model.candidates.count > 1 {
            choice = (model.candidates[1].vertex, .engine)
        } else {
            choice = nil
        }
        guard let choice else { return }
        _ = try await applyAlternative(vertex: choice.vertex, source: choice.source,
                                       budget: budget, model: model, position: position,
                                       mySymbol: mySymbol, parser: parser,
                                       sideToMove: sideToMove, width: width, height: height)
    }

    /// Targeted re-probe of a newly picked Alternative on a completed report:
    /// the picked move always gets its own forced-allow probe (visit parity;
    /// the cached snapshot entry only backstops a silent engine), plus its
    /// tenuki follow-up; the snapshot, best-move, and pass sections stay
    /// untouched. A failed or cancelled pick leaves the prior alternative
    /// standing and posts a `transientNotice` instead of failing the report.
    public func repickAlternative(model: DeepReportModel,
                                  gameRecord: GameRecord,
                                  vertex: String) async {
        guard model.stage == .complete,
              let position = model.position,
              let best = model.candidates.first,
              vertex != best.vertex,
              vertex != "pass",
              let session = messageList.session,
              !session.gobanState.reportGenerationActive else { return }

        let sideToMove = model.sideToMove
        reportSideSymbol = sideToMove == .black ? "b" : "w"
        let mySymbol = reportSideSymbol
        let width = model.boardWidth
        let height = model.boardHeight
        let parser = AnalysisLineParser(boardWidth: width, boardHeight: height, nextColor: .white)
        // Deeper reports probe picks at the same depth they were refined to.
        let budget = budgets.tenuki * TimeInterval(model.budgetMultiplier)
        let priorCandidates = model.candidates
        let priorSource = model.alternativeSource
        model.mode = .pick
        model.transientNotice = nil
        model.stage = .tenuki(1)

        do {
            try await withProbeSession(session: session) {
                // A prior gen-move may have left its sticky maxVisits cap
                // behind — every probe session lifts it first.
                send("kata-set-param maxVisits \(GtpCommandBuilder.unboundedMaxVisits)", stage: nil)
                // Visit parity: even a snapshot-ranked pick gets its own
                // probe; the cached entry only backstops a silent engine.
                let info: AnalysisInfo
                if let probed = try await forcedAlternativeInfo(vertex: vertex, budget: budget,
                                                                mySymbol: mySymbol, parser: parser,
                                                                width: width, height: height) {
                    info = probed
                } else if let entry = model.snapshotEntries.first(where: { $0.vertex == vertex }) {
                    info = entry.info
                } else {
                    throw ReportError("The engine couldn't analyze \(vertex) here — it may be an illegal move.")
                }
                var alternative = buildCandidate(vertex: vertex, info: info,
                                                 position: position, sideToMove: sideToMove,
                                                 baseOwnership: model.snapshotOwnership,
                                                 width: width, height: height)
                alternative.tenuki = try await tenukiProbe(
                    vertex: vertex, index: 1, budget: budget,
                    mySymbol: mySymbol, parser: parser,
                    sideToMove: sideToMove, width: width, height: height)
                setAlternative(alternative,
                               source: vertex == model.gameMoveVertex ? .gameMove : .userPick,
                               model: model)
            }
            await renarrate(model: model, gameRecord: gameRecord)
            model.stage = .complete
        } catch {
            model.candidates = priorCandidates
            model.alternativeSource = priorSource
            model.transientNotice = Self.keepAlternativeNotice(for: error)
            model.stage = .complete
        }
    }

    /// Re-runs the whole probe pipeline at the next doubled budget (capped at
    /// `ReportConstants.maxBudgetMultiplier`× base), replacing report sections
    /// in place as each stage lands — a mid-flight cancel or engine error
    /// leaves a valid (possibly mixed-depth) report, never a wiped one. The
    /// picked alternative is preserved and re-probed at the deeper budget;
    /// the multiplier advances only on full success.
    public func refine(model: DeepReportModel, gameRecord: GameRecord) async {
        guard model.stage == .complete,
              let session = messageList.session,
              !session.gobanState.reportGenerationActive else { return }

        let sideToMove = model.sideToMove
        reportSideSymbol = sideToMove == .black ? "b" : "w"
        let multiplier = model.nextBudgetMultiplier
        let scaled = budgets.scaled(by: multiplier)
        model.mode = .refine
        model.transientNotice = nil

        do {
            try await withProbeSession(session: session) {
                try await runRefineProbes(model: model, scaled: scaled, sideToMove: sideToMove)
            }
            await renarrate(model: model, gameRecord: gameRecord)
            model.budgetMultiplier = multiplier
            model.stage = .complete
        } catch {
            model.transientNotice = Self.keepAlternativeNotice(for: error)
            model.stage = .complete
        }
    }

    /// A pick/refine abort must read as "your report survived": the message
    /// explains what didn't happen, never a failure stage.
    private static func keepAlternativeNotice(for error: Error) -> String {
        switch error {
        case is CancellationError:
            return "Cancelled — the previous report was kept."
        case let reportError as ReportError:
            return reportError.message
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Probes

    /// The snapshot analyze (zero board mutation): lifts the sticky maxVisits
    /// cap, streams candidates + PVs + root/subtree ownership, and returns the
    /// last report line. Throws when the engine stays silent.
    private func snapshotProbe(budget: TimeInterval,
                               parser: AnalysisLineParser) async throws -> ParsedAnalysis {
        send("kata-set-param maxVisits \(GtpCommandBuilder.unboundedMaxVisits)", stage: nil)
        send("kata-analyze interval \(ReportConstants.probeInterval) maxmoves \(ReportConstants.probeMaxMoves) ownership true movesOwnership true rootInfo true",
             stage: .snapshot)
        try await sleeper(budget)
        try checkEngineError()
        send("stop", stage: nil)
        // Let a final in-flight report line cross the pipe before reading.
        try await sleeper(ReportConstants.stopGrace)
        guard let line = collector.latestLine(for: .snapshot) else {
            throw ReportError("The engine produced no analysis for this position.")
        }
        return parser.parse(message: line)
    }

    /// Commits a snapshot to the model: position summary, the ranked-entry +
    /// root-ownership caches, and the engine's top candidates.
    private func applySnapshot(_ snapshot: ParsedAnalysis,
                               model: DeepReportModel,
                               sideToMove: PlayerColor,
                               width: Int, height: Int) throws -> PositionSummary {
        guard let rootInfo = snapshot.rootInfo else {
            throw ReportError("The engine's analysis carried no root values.")
        }
        let position = PositionSummary(
            winrate: ReportPerspective.winrate(rootInfo.winrate, for: sideToMove),
            scoreLead: ReportPerspective.score(rootInfo.scoreLead, for: sideToMove),
            visits: rootInfo.visits)
        model.position = position
        // Cache the ranked snapshot candidates + root ownership: the picker's
        // quick-pick marks, and the no-reprobe path for picking one of them.
        model.snapshotEntries = rankedEntries(in: snapshot, width: width, height: height)
            .prefix(ReportConstants.probeMaxMoves)
            .map { SnapshotEntry(vertex: $0.vertex, info: $0.info) }
        model.snapshotOwnership = snapshot.rawOwnership
        model.candidates = buildCandidates(from: snapshot, position: position,
                                           sideToMove: sideToMove, width: width, height: height)
        return position
    }

    /// The pass probe (zero board mutation): opponent to move on the same
    /// board. Replaces the model's pass comparison only when a line landed.
    private func passStage(model: DeepReportModel,
                           snapshot: ParsedAnalysis,
                           budget: TimeInterval,
                           oppSymbol: String,
                           parser: AnalysisLineParser,
                           sideToMove: PlayerColor,
                           width: Int, height: Int) async throws {
        model.stage = .passProbe
        send("kata-analyze \(oppSymbol) interval \(ReportConstants.coldProbeInterval) maxmoves \(ReportConstants.probeMaxMoves) ownership true rootInfo true",
             stage: .passProbe)
        try await sleeper(budget)
        try checkEngineError()
        send("stop", stage: nil)
        // Let a final in-flight report line cross the pipe before reading.
        try await sleeper(ReportConstants.stopGrace)
        if let passLine = collector.latestLine(for: .passProbe) {
            let passParsed = parser.parse(message: passLine)
            model.passComparison = buildPassComparison(passParsed: passParsed,
                                                       snapshot: snapshot,
                                                       sideToMove: sideToMove,
                                                       best: model.candidates.first,
                                                       width: width, height: height)
        }
    }

    /// Tenuki probes for every current candidate.
    private func tenukiStage(model: DeepReportModel,
                             budget: TimeInterval,
                             mySymbol: String,
                             parser: AnalysisLineParser,
                             sideToMove: PlayerColor,
                             width: Int, height: Int) async throws {
        for (index, candidate) in model.candidates.enumerated() {
            guard candidate.vertex != "pass" else { continue }
            model.stage = .tenuki(index)
            model.candidates[index].tenuki = try await tenukiProbe(
                vertex: candidate.vertex, index: index, budget: budget,
                mySymbol: mySymbol, parser: parser,
                sideToMove: sideToMove, width: width, height: height)
        }
    }

    /// One `allow`-constrained analyze: every root visit is funneled into
    /// `vertex`, yielding full candidate info (winrate/PV/movesOwnership) for
    /// a move the snapshot didn't rank. The constraint is per-analyze-call
    /// engine state, so the next plain kata-analyze clears it. Returns nil
    /// when no report line landed (typically an illegal vertex — the engine
    /// searches nothing and emits nothing).
    private func forcedCandidateProbe(vertex: String,
                                      budget: TimeInterval,
                                      mySymbol: String,
                                      parser: AnalysisLineParser) async throws -> ParsedAnalysis? {
        send("kata-analyze \(mySymbol) interval \(ReportConstants.coldProbeInterval) allow \(mySymbol) \(vertex) 1 maxmoves \(ReportConstants.probeMaxMoves) ownership true movesOwnership true rootInfo true",
             stage: .forcedCandidate)
        try await sleeper(budget)
        try checkEngineError()
        send("stop", stage: nil)
        // Let a final in-flight report line cross the pipe before reading.
        try await sleeper(ReportConstants.stopGrace)
        guard let line = collector.latestLine(for: .forcedCandidate) else { return nil }
        return parser.parse(message: line)
    }

    /// One forced-candidate probe distilled to the nominated vertex's own info
    /// entry — the visit-parity workhorse (see CONTEXT.md "Visit parity").
    /// nil when the vertex can't be probed ("pass" has no allow form) or the
    /// engine stayed silent / never ranked it (typically an illegal vertex).
    private func forcedAlternativeInfo(vertex: String,
                                       budget: TimeInterval,
                                       mySymbol: String,
                                       parser: AnalysisLineParser,
                                       width: Int, height: Int) async throws -> AnalysisInfo? {
        guard vertex != "pass",
              let parsed = try await forcedCandidateProbe(vertex: vertex, budget: budget,
                                                          mySymbol: mySymbol, parser: parser)
        else { return nil }
        return rankedEntries(in: parsed, width: width, height: height)
            .first(where: { $0.vertex == vertex })?.info
    }

    /// One tenuki probe: play the candidate, analyze with the SAME side to
    /// move (= opponent ignored it), undo. The only board mutation any probe
    /// makes, tracked by `outstandingPlays` for the restore path.
    private func tenukiProbe(vertex: String, index: Int, budget: TimeInterval,
                             mySymbol: String, parser: AnalysisLineParser,
                             sideToMove: PlayerColor,
                             width: Int, height: Int) async throws -> TenukiFollowUp? {
        send("play \(mySymbol) \(vertex)", stage: nil)
        outstandingPlays = 1
        send("kata-analyze \(mySymbol) interval \(ReportConstants.coldProbeInterval) maxmoves \(ReportConstants.probeMaxMoves) ownership true rootInfo true",
             stage: .tenuki(index))
        try await sleeper(budget)
        try checkEngineError()
        send("stop", stage: nil)
        // Let a final in-flight report line cross the pipe before reading;
        // the undo (which yanks the cold tree out) must still always follow,
        // whether or not a line landed.
        try await sleeper(ReportConstants.stopGrace)
        let line = collector.latestLine(for: .tenuki(index))
        send("undo", stage: nil)
        outstandingPlays = 0
        guard let line else { return nil }
        return buildTenuki(parsed: parser.parse(message: line),
                           sideToMove: sideToMove, width: width, height: height)
    }

    // MARK: - Builders (White-perspective in, side-to-move out)

    private func buildCandidates(from snapshot: ParsedAnalysis,
                                 position: PositionSummary,
                                 sideToMove: PlayerColor,
                                 width: Int, height: Int) -> [CandidateReport] {
        rankedEntries(in: snapshot, width: width, height: height)
            .prefix(budgets.candidateCount)
            .map { vertex, info in
                buildCandidate(vertex: vertex, info: info, position: position,
                               sideToMove: sideToMove,
                               baseOwnership: snapshot.rawOwnership,
                               width: width, height: height)
            }
    }

    /// Single construction path for snapshot-, cached-, and forced-probe
    /// candidates: deltas vs. the position summary, Δ-ownership vs. the
    /// SNAPSHOT root grid (the report's one baseline).
    private func buildCandidate(vertex: String, info: AnalysisInfo,
                                position: PositionSummary,
                                sideToMove: PlayerColor,
                                baseOwnership: [Float],
                                width: Int, height: Int) -> CandidateReport {
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
            ownershipDelta: OwnershipDelta.grid(base: baseOwnership,
                                                probe: info.movesOwnership ?? [],
                                                width: width, height: height),
            tenuki: nil)
    }

    /// Replaces the Alternative slot (everything after the best move) and
    /// records where the new occupant came from.
    private func setAlternative(_ candidate: CandidateReport,
                                source: AlternativeSource,
                                model: DeepReportModel) {
        guard let best = model.candidates.first else { return }
        model.candidates = [best, candidate]
        model.alternativeSource = source
    }

    /// The game's next recorded move as a GTP vertex, when it can seed the
    /// Alternative slot: not on a branch (a throwaway line has no "game
    /// move"), a real board vertex (not a pass), and the side to move's color.
    private func gameMoveVertex(session: GameSession,
                                gameRecord: GameRecord,
                                sideToMove: PlayerColor) -> String? {
        guard !session.gobanState.isBranchActive,
              let next = session.gobanState.getNextMove(gameRecord: gameRecord) else { return nil }
        let nextColor: PlayerColor = next.player == .black ? .black : .white
        guard nextColor == sideToMove,
              let vertex = session.board.locationToMove(location: next.location),
              vertex != "pass" else { return nil }
        return vertex
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
        model.isBranchPosition = session.gobanState.isBranchActive
        model.visitsPerSecondText = session.analysis.visitsPerSecond > 0
            ? session.analysis.visitsPerSecondText : nil
        model.sideToMove = sideToMove
        model.boardWidth = Int(session.board.width)
        model.boardHeight = Int(session.board.height)
        model.blackVertices = vertices(of: session.stones.blackPoints,
                                       width: model.boardWidth, height: model.boardHeight)
        model.whiteVertices = vertices(of: session.stones.whitePoints,
                                       width: model.boardWidth, height: model.boardHeight)
        model.isClassicStoneStyle = session.gobanState.isClassicStoneStyle
        model.showCoordinate = session.gobanState.showCoordinate
        model.verticalFlip = session.gobanState.verticalFlip

        // A reused model must never show a previous run's results. Regenerate
        // is a true base-budget reset, so the refine multiplier and the
        // alternative pick go back to their defaults too.
        model.position = nil
        model.candidates = []
        model.passComparison = nil
        model.narrative = ""
        model.narrativeUnavailableReason = nil
        model.alternativeSource = .engine
        model.gameMoveVertex = nil
        model.snapshotEntries = []
        model.snapshotOwnership = []
        model.budgetMultiplier = 1
        model.mode = .initial
        model.transientNotice = nil
    }

    private func vertices(of points: [BoardPoint], width: Int, height: Int) -> [String] {
        points.compactMap { Coordinate(x: $0.x, y: $0.y + 1, width: width, height: height)?.move }
    }

    /// Single restore path for every exit: undo any outstanding probe play,
    /// stop whatever streams, hand the line stream back, unfreeze live
    /// collection, and re-sync the board via showboard. Deliberately does NOT
    /// re-arm live analysis: the Deep Report sheet pauses it on presentation,
    /// and it stays paused until the user resumes manually — re-arming here
    /// would restart kata-analyze underneath the still-open sheet.
    private func restore(session: GameSession) {
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
        session.gobanState.sendShowBoardCommand(messageList: messageList)
    }
}
