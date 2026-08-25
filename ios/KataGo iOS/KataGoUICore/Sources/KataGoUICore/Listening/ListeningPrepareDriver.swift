//
//  ListeningPrepareDriver.swift
//  KataGo Anytime
//
//  Prepare for Listening: walk the engine through EVERY position of one
//  record — a budgeted analyze probe per position, persisting black-
//  perspective winRates/scoreLeads/bestMoves — then write commentator
//  sentences for the moves that have none. The result is a game whose
//  Listening Session speaks full sentences throughout (the derived
//  ready-to-listen marker: ListeningReadiness.coverage).
//
//  The engine envelope is DeepReportGenerator's, deliberately: the same
//  `reportGenerationActive` flag (free mutual exclusion with the Deep
//  Report and live collection), the same lineObserver hijack into a
//  ReportCollector, the same defer-restore on every exit. The sweep feeds
//  its own replay from a clear board and NEVER touches the record's parked
//  index; restore stands the engine back on the displayed position via
//  syncEngine. The comments pass runs engine-free AFTER restore.
//

import Foundation
import GoRulesKit
import Observation

@Observable
@MainActor
public final class ListeningPrepareModel {
    public enum Phase: Equatable {
        case idle
        case sweeping
        case commenting
        case complete
        case cancelled
        case failed(String)
    }

    public var phase: Phase = .idle
    public var completedPositions = 0
    public var totalPositions = 0

    public init() {}
}

@MainActor
public final class ListeningPrepareDriver {
    public struct Budgets: Sendable {
        /// Per-position analyze allowance. Time-bounded, not visit-bounded:
        /// maxVisits is inert for kata-analyze, so the stop IS the budget.
        public var probeSeconds: TimeInterval
        /// The wait poll step.
        public var pollSeconds: TimeInterval
        /// Root visits that end a position's wait early.
        public var targetVisits: Int
        /// LLM polish is offered only up to this many moves — comments are
        /// the one unbounded CloudKit field, and an hour of on-device
        /// generation for a 300-move import serves nobody. Longer games get
        /// the deterministic register.
        public var llmMoveCap: Int

        public static let standard = Budgets(probeSeconds: 1.2,
                                             pollSeconds: 0.1,
                                             targetVisits: 24,
                                             llmMoveCap: 120)

        public init(probeSeconds: TimeInterval, pollSeconds: TimeInterval,
                    targetVisits: Int, llmMoveCap: Int) {
            self.probeSeconds = probeSeconds
            self.pollSeconds = pollSeconds
            self.targetVisits = targetVisits
            self.llmMoveCap = llmMoveCap
        }
    }

    private let messageList: MessageList
    private let budgets: Budgets
    private let sleeper: ReportSleeper
    private let collector = ReportCollector()
    private var priorObserver: ((String) -> Void)?

    public init(messageList: MessageList,
                budgets: Budgets = .standard,
                sleeper: @escaping ReportSleeper = { try await Task.sleep(for: .seconds($0)) }) {
        self.messageList = messageList
        self.budgets = budgets
        self.sleeper = sleeper
    }

    public func prepare(gameRecord: GameRecord, model: ListeningPrepareModel) async {
        guard let session = messageList.session else {
            model.phase = .failed("No engine session.")
            return
        }
        guard !session.gobanState.reportGenerationActive else {
            model.phase = .failed("Another analysis task is active.")
            return
        }
        guard let scan = SgfHeaderScan(sgf: gameRecord.sgf) else {
            model.phase = .failed("This game has no readable record.")
            return
        }

        model.totalPositions = scan.moveCount + 1
        model.completedPositions = 0
        model.phase = .sweeping

        do {
            try await withEngineHijack(session: session, gameRecord: gameRecord) {
                try await sweep(gameRecord: gameRecord, scan: scan, model: model)
            }
        } catch is CancellationError {
            model.phase = .cancelled
            return
        } catch {
            model.phase = .failed(error.localizedDescription)
            return
        }

        // Engine restored; sentences are generated record-side.
        model.phase = .commenting
        do {
            try await commentsPass(gameRecord: gameRecord, scan: scan)
        } catch {
            model.phase = .cancelled
            return
        }
        model.phase = .complete
    }

    // MARK: - Engine envelope (DeepReportGenerator's, verbatim discipline)

    private func withEngineHijack(session: GameSession,
                                  gameRecord: GameRecord,
                                  body: () async throws -> Void) async throws {
        collector.reset()
        priorObserver = session.lineObserver
        let collector = self.collector
        session.lineObserver = { collector.ingest(line: $0) }
        session.gobanState.reportGenerationActive = true
        defer { restore(session: session, gameRecord: gameRecord) }
        try await body()
    }

    /// Single restore path for every exit: hand the line stream back, unfreeze
    /// live collection, stop whatever streams, and stand the engine back on
    /// the DISPLAYED position (the sweep re-fed the board from scratch, so a
    /// full re-feed — not undos — is the honest way home). Deliberately does
    /// not re-arm live analysis: the progress sheet's dismissal does, exactly
    /// like the Deep Report sheet.
    private func restore(session: GameSession, gameRecord: GameRecord) {
        session.lineObserver = priorObserver
        priorObserver = nil
        session.gobanState.reportGenerationActive = false
        messageList.appendAndSend(command: "stop")
        let gobanState = session.gobanState
        let sgf = gobanState.getSgf(gameRecord: gameRecord) ?? gameRecord.sgf
        let index = gobanState.getCurrentIndex(gameRecord: gameRecord) ?? gameRecord.currentIndex
        gobanState.syncEngine(to: index,
                              sgf: sgf,
                              config: gameRecord.concreteConfig,
                              messageList: messageList,
                              stones: session.stones,
                              player: session.player,
                              projector: session.recordPosition)
    }

    // MARK: - The sweep

    private func sweep(gameRecord: GameRecord, scan: SgfHeaderScan,
                       model: ListeningPrepareModel) async throws {
        // Black-perspective by construction: the wire is White-perspective
        // (reportAnalysisWinratesAs = WHITE) and the parser flips exactly
        // when told Black — so every persisted number lands black-positive
        // with no side-to-move bookkeeping.
        let parser = AnalysisLineParser(boardWidth: scan.boardWidth,
                                        boardHeight: scan.boardHeight,
                                        nextColor: .black)
        var replay = SgfReplay(scan: scan)

        // The record's dictionaries can arrive nil from CloudKit; a nil
        // dictionary swallows optional-chained writes silently.
        if gameRecord.winRates == nil { gameRecord.winRates = [:] }
        if gameRecord.scoreLeads == nil { gameRecord.scoreLeads = [:] }
        if gameRecord.bestMoves == nil { gameRecord.bestMoves = [:] }

        // Stand the engine on the record's EMPTY board (its own geometry,
        // rules, setup stones), then advance one accepted move at a time.
        for command in EngineFeed.openingCommands(replay: &replay,
                                                 config: gameRecord.concreteConfig,
                                                 targetIndex: 0) {
            send(command, stage: nil)
        }
        send("kata-set-param maxVisits \(GtpCommandBuilder.unboundedMaxVisits)", stage: nil)

        for index in 0...scan.moveCount {
            try Task.checkCancellation()
            try await probePosition(index, parser: parser, scan: scan, gameRecord: gameRecord)
            model.completedPositions = index + 1
            if index < scan.moveCount,
               let move = EngineFeed.playArguments(replay: &replay, at: index) {
                send(EngineFeed.playCommand(turn: move.turn, vertex: move.vertex), stage: nil)
            }
        }
    }

    /// One budgeted analyze at the engine's current position. No color
    /// argument on purpose — `kata-analyze <player>` flips the engine's root
    /// player persistently, and the fed moves already put the right side to
    /// move. Silence within budget simply leaves the index unpersisted:
    /// Prepare's coverage marker stays honest, and a later run fills holes.
    private func probePosition(_ index: Int, parser: AnalysisLineParser,
                               scan: SgfHeaderScan,
                               gameRecord: GameRecord) async throws {
        let stage = ReportStage.tenuki(index)
        send("kata-analyze interval \(ReportConstants.probeInterval) maxmoves \(ReportConstants.probeMaxMoves) rootInfo true",
             stage: stage)
        var waited: TimeInterval = 0
        while waited < budgets.probeSeconds {
            try await sleeper(budgets.pollSeconds)
            waited += budgets.pollSeconds
            if let line = collector.latestLine(for: stage),
               let root = parser.parse(message: line).rootInfo,
               root.visits >= budgets.targetVisits {
                break
            }
        }
        send("stop", stage: nil)
        try await sleeper(ReportConstants.stopGrace)

        guard let line = collector.latestLine(for: stage) else { return }
        let parsed = parser.parse(message: line)
        if let root = parsed.rootInfo, root.visits > 0 {
            gameRecord.winRates?[index] = root.winrate
            gameRecord.scoreLeads?[index] = root.scoreLead
        }
        if let best = bestVertex(in: parsed, width: scan.boardWidth,
                                 height: scan.boardHeight) {
            gameRecord.bestMoves?[index] = best
        }
    }

    /// The most-visited candidate's vertex — "the engine's recommendation at
    /// this position", the same reading `getBestMove` gives live analysis.
    private func bestVertex(in parsed: ParsedAnalysis,
                            width: Int, height: Int) -> String? {
        guard let (point, info) = parsed.info.max(by: { $0.value.visits < $1.value.visits }),
              info.visits > 0 else { return nil }
        if point == BoardPoint.pass(width: width, height: height) {
            return "pass"
        }
        return Coordinate(x: point.x, y: point.y + 1, width: width, height: height)?.move
    }

    private func send(_ command: String, stage: ReportStage?) {
        collector.willSend(stage: stage)
        messageList.appendAndSend(command: command)
    }

    // MARK: - Comments (engine-free, after restore)

    /// A commentator-register sentence for every analyzed move that has no
    /// comment yet. Only-if-absent: user text is never overwritten. LLM
    /// polish applies up to the move cap; comment writes do not bump
    /// lastModificationDate, so the library order is stable.
    private func commentsPass(gameRecord: GameRecord, scan: SgfHeaderScan) async throws {
        let useLLM = gameRecord.concreteConfig.useLLM && scan.moveCount <= budgets.llmMoveCap
        if gameRecord.comments == nil { gameRecord.comments = [:] }
        for index in 0...scan.moveCount {
            try Task.checkCancellation()
            guard gameRecord.winRates?[index] != nil else { continue }
            let existing = gameRecord.comments?[index]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard existing.isEmpty else { continue }
            let turn = Turn()
            turn.nextColorForPlayCommand = scan.toMove(atMoveIndex: index)
            let commentator = Commentator(gameRecord: gameRecord, turn: turn, index: index)
            let comment = useLLM
                ? await commentator.generateImprovedComment()
                : commentator.generateNaturalComment()
            CommentPersistence.store(comment, at: index, in: gameRecord)
        }
    }
}
