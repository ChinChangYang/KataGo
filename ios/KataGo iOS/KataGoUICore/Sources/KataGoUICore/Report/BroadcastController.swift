//
//  BroadcastController.swift
//  KataGoUICore
//
//  Drives the tvOS self-play "commentated broadcast" loop:
//  report → slides → licensed gen-move → (turn change) → report …
//
//  Engine-state protocol (see the broadcast plan; all four are load-bearing):
//  - analysisStatus stays .clear while the broadcast runs, so BoardView's
//    turn observer never issues an analyze command at the same turn change
//    that starts a report cycle. An un-acked `=` crossing the generator's
//    lineObserver swap would desync the ReportCollector FIFO (the round-7
//    stray-ack class).
//  - suppressesGenMove stays true for the whole broadcast; the single
//    per-cycle gen-move is licensed via gobanState.broadcastGenMovePending,
//    consumed exactly once in GameSession.postProcessAIMove.
//  - issueGenMove re-asserts .clear BEFORE sending (a paused-interactive
//    stretch runs .run): the status observer's "stop" ack then drains ahead
//    of the gen-move reply on the FIFO pipe, never near a collector swap.
//  - maybePauseAnalysis is NEVER called around generation; the generator's
//    probe cancellation + restore() leave the engine idle on their own.
//

import SwiftUI

public enum BroadcastPhase: Equatable, Sendable {
    case idle
    case generating
    case slides(Int)
    case awaitingMove
    case paused
}

@Observable
@MainActor
public final class BroadcastController {
    public private(set) var phase: BroadcastPhase = .idle
    public private(set) var currentSlide: BroadcastSlide?
    /// 1-based number of the showing slide, 0 between slideshows.
    public private(set) var slideNumber = 0
    /// Highest slide count observed this cycle (for progress dots).
    public private(set) var slideCount = 0
    public private(set) var typedText = ""
    public private(set) var reportModel: DeepReportModel?

    private let messageList: MessageList
    private let gobanState: GobanState
    private let player: Turn
    private let rootWinrate: Winrate
    private let rootScore: Score
    /// Report seam — tests script model stages instead of probing an engine.
    private let generateReport: @MainActor (DeepReportModel, GameRecord) async -> Void
    private let sleeper: ReportSleeper

    private var cycleTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var moveLanded = false
    private var genMoveIssued = false
    private var skipRequested = false
    /// Monotonic cycle identity: a cycle's continuation may only clear the
    /// shared handle (and chain) if no newer cycle has been started since —
    /// a cancelled cycle's continuation draining late must not clobber a
    /// successor's cycleTask (the double-cycle / double-gen-move race).
    private var cycleToken = 0

    public init(messageList: MessageList,
                gobanState: GobanState,
                player: Turn,
                rootWinrate: Winrate,
                rootScore: Score,
                generateReport: (@MainActor (DeepReportModel, GameRecord) async -> Void)? = nil,
                sleeper: @escaping ReportSleeper = { try await Task.sleep(for: .seconds($0)) }) {
        self.messageList = messageList
        self.gobanState = gobanState
        self.player = player
        self.rootWinrate = rootWinrate
        self.rootScore = rootScore
        self.generateReport = generateReport ?? { [messageList] model, game in
            await DeepReportGenerator(messageList: messageList)
                .generate(model: model, gameRecord: game)
        }
        self.sleeper = sleeper
    }

    public var isShowingSlides: Bool { currentSlide != nil }

    /// The screen's turn-change hook (fires off BoardView's shared observer
    /// signal). Starts the first cycle, chains the next one, or records that
    /// the pre-sent gen-move's stone landed mid-slideshow.
    public func noteTurnChanged(game: GameRecord) {
        guard player.nextColorForPlayCommand != .unknown else { return }
        switch phase {
        case .idle, .awaitingMove:
            startCycle(game: game)
        case .generating, .slides:
            if genMoveIssued { moveLanded = true }
        case .paused:
            break
        }
    }

    /// Fast-forward: end the current slide now. Past the last slide this
    /// exits the slideshow, which issues the gen-move ("play the move now").
    public func skipSlide() {
        skipRequested = true
    }

    /// Cancel the running cycle (probe cancellation → restore) and hand the
    /// screen to the interactive paused UI. Continuous analysis re-arms so
    /// the Top Moves list fills — unlike the old self-play pause there is no
    /// live stream to freeze, because the broadcast never runs one.
    public func pause(game: GameRecord) async {
        let task = cycleTask
        cycleTask = nil
        task?.cancel()
        await task?.value
        currentSlide = nil
        typedText = ""
        slideNumber = 0
        phase = .paused
        gobanState.analysisStatus = .run
        gobanState.requestAnalysis(config: game.concreteConfig,
                                   messageList: messageList,
                                   nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    /// Re-enter the loop from the current (possibly user-altered) position.
    /// The next cycle's first probe cancels the paused screen's continuous
    /// analyze mid-stream — the safe, iOS-identical cancellation (its `=`
    /// ack was consumed long ago). issueGenMove restores the .clear protocol
    /// at the cycle's end.
    public func resume(game: GameRecord) {
        guard phase == .paused else { return }
        startCycle(game: game)
    }

    /// Teardown / new-game restart: abandon everything. The generator's
    /// probe-session defer runs restore() on cancellation, so the engine
    /// comes back to the game position on its own.
    public func cancelAll() {
        cycleToken += 1
        cycleTask?.cancel()
        cycleTask = nil
        generationTask?.cancel()
        generationTask = nil
        currentSlide = nil
        typedText = ""
        slideNumber = 0
        phase = .idle
    }

    // MARK: - Cycle

    private func startCycle(game: GameRecord) {
        guard cycleTask == nil else { return }
        guard gobanState.passCount < 2 else {
            phase = .idle
            return
        }
        moveLanded = false
        genMoveIssued = false
        skipRequested = false
        slideCount = 0
        guard gobanState.passCount == 0 else {
            // Endgame formality (grilled decision): once passing starts,
            // no report segments — answer immediately, the interstitial
            // machinery takes over after the second pass.
            reportModel = nil
            issueGenMove(game: game)
            phase = .awaitingMove
            return
        }
        phase = .generating
        cycleToken += 1
        let token = cycleToken
        cycleTask = Task { [weak self] in
            guard let self else { return }
            let chain = await self.runCycle(game: game)
            guard self.cycleToken == token else { return }
            self.cycleTask = nil
            if chain {
                self.startCycle(game: game)
            }
        }
    }

    /// Returns true when the gen-move's stone already landed mid-slideshow,
    /// so the caller chains straight into the next cycle.
    private func runCycle(game: GameRecord) async -> Bool {
        let model = DeepReportModel()
        reportModel = model
        let generation = Task { [generateReport] in
            await generateReport(model, game)
        }
        generationTask = generation

        // Overlap-at-snapshot: the slideshow starts as soon as the first
        // slide's data lands (~2 s), while pass/tenuki probes continue.
        while BroadcastScript.slides(from: model).isEmpty && !model.stage.isSettled {
            if Task.isCancelled {
                generation.cancel()
                await generation.value
                return false
            }
            try? await sleeper(BroadcastConstants.pollSeconds)
        }
        writeSnapshotStats(model: model, game: game)

        var index = 0
        while !Task.isCancelled {
            let slides = BroadcastScript.slides(from: model)
            if index >= slides.count {
                if model.stage.isSettled { break }
                try? await sleeper(BroadcastConstants.pollSeconds)
                continue
            }
            phase = .slides(index)
            slideNumber = index + 1
            slideCount = max(slides.count, slideCount)
            currentSlide = slides[index]
            if model.stage.isSettled && index == slides.count - 1 && !genMoveIssued {
                // Early gen-move (grilled decision): sent as the FINAL slide
                // starts, so the reply lands invisibly (hero and panel both
                // show report content) and the stone appears the moment the
                // live board returns. Generation is settled — restore() ran.
                await generation.value
                issueGenMove(game: game)
            }
            await typewrite(slideIndex: index, model: model)
            index += 1
        }

        if Task.isCancelled {
            generation.cancel()
        }
        await generation.value
        currentSlide = nil
        typedText = ""
        slideNumber = 0
        if Task.isCancelled { return false }
        if !genMoveIssued {
            issueGenMove(game: game)
        }
        phase = .awaitingMove
        return moveLanded
    }

    /// Types one slide's facts word-by-word, tolerating a fact list that is
    /// still growing (slide 1's tenuki line lands mid-typewriter), then
    /// dwells so short slides don't flash by.
    private func typewrite(slideIndex: Int, model: DeepReportModel) async {
        typedText = ""
        var elapsed: TimeInterval = 0
        var factIndex = 0
        while !Task.isCancelled && !skipRequested {
            let slides = BroadcastScript.slides(from: model)
            guard slideIndex < slides.count else { break }
            let slide = slides[slideIndex]
            let facts = slide.facts
            if factIndex < facts.count {
                for chunk in BroadcastScript.typewriterChunks(facts[factIndex]) {
                    guard !Task.isCancelled && !skipRequested else { break }
                    typedText += chunk
                    let delay = Double(chunk.count) / BroadcastConstants.charactersPerSecond
                    try? await sleeper(delay)
                    elapsed += delay
                }
                typedText += "\n"
                factIndex += 1
            } else if BroadcastScript.factsMayGrow(kind: slide.kind, model: model) {
                try? await sleeper(BroadcastConstants.pollSeconds)
                elapsed += BroadcastConstants.pollSeconds
            } else {
                break
            }
        }
        if skipRequested {
            skipRequested = false
            return
        }
        guard !Task.isCancelled else { return }
        let dwell = max(BroadcastConstants.minimumSlideSeconds - elapsed,
                        BroadcastConstants.dwellSeconds)
        try? await sleeper(dwell)
    }

    private func issueGenMove(game: GameRecord) {
        guard !genMoveIssued else { return }
        guard gobanState.passCount < 2 else { return }
        genMoveIssued = true
        // Restore the broadcast protocol BEFORE the gen-move: after a
        // paused-interactive stretch status is .run, and the .clear
        // transition fires the TV root's "stop" — its ack drains ahead of
        // the gen-move reply on the FIFO pipe, and .clear keeps BoardView's
        // turn observer silent at the upcoming turn change.
        if gobanState.analysisStatus != .clear {
            gobanState.analysisStatus = .clear
        }
        gobanState.requestBroadcastGenMove(config: game.concreteConfig,
                                           messageList: messageList,
                                           nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    /// The broadcast never streams continuous analysis, so the winrate
    /// headline and score chart are fed from the report's own snapshot
    /// (side-to-move perspective → black-positive).
    private func writeSnapshotStats(model: DeepReportModel, game: GameRecord) {
        guard let position = model.position else { return }
        let blackWinrate = model.sideToMove == .black ? position.winrate : 1 - position.winrate
        let blackScore = model.sideToMove == .black ? position.scoreLead : -position.scoreLead
        rootWinrate.black = blackWinrate
        rootScore.black = blackScore
        game.winRates?[game.currentIndex] = blackWinrate
        withAnimation(.spring) {
            game.scoreLeads?[game.currentIndex] = blackScore
        }
    }
}
