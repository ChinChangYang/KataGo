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
//    stretch runs .run). The TV root's status observer fires one MainActor
//    update pass LATER — after the gen-move is already on the FIFO — so it
//    is gated on the armed license (shouldStopEngineOnAnalysisClear): an
//    ungated "stop" would cancel the licensed search, which then prints
//    "play cancelled" instead of a vertex and the broadcast would park in
//    .awaitingMove forever (the pause→resume stall).
//  - maybePauseAnalysis is NEVER called around generation; the generator's
//    probe cancellation + restore() leave the engine idle on their own.
//  - BoardView's turn observer also sends asymmetric human-SL kata-set-param
//    commands regardless of analysisStatus; inert for the symmetric self-play
//    config, but an asymmetric demo config would inject acks at cycle-start —
//    keep the config symmetric or gate those sends before reusing this
//    controller.
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
    /// The slide board's current choreography frame; non-nil exactly while
    /// currentSlide is non-nil — EXCEPT the replay Comment slide, which
    /// deliberately keeps it nil so the live hero board stays mounted.
    public private(set) var currentFrame: BroadcastBoardFrame?

    private let messageList: MessageList
    private let gobanState: GobanState
    private let player: Turn
    private let rootWinrate: Winrate
    private let rootScore: Score
    /// Report seam — tests script model stages instead of probing an engine.
    private let generateReport: @MainActor (DeepReportModel, GameRecord) async -> Void
    private let sleeper: ReportSleeper
    /// Spoken narration (nil = silent). One utterance per fact, enqueued as
    /// the fact starts typing; the end-of-slide hold waits the queue out.
    private let speaker: NarrationSpeaking?
    private let isSpeechEnabled: () -> Bool
    /// Read fresh each use so a mid-broadcast Settings change takes effect
    /// on the next slide.
    private let pacing: () -> BroadcastPacing
    /// Replay move source: non-nil switches the cycle's ending from the
    /// licensed gen-move to "play the next RECORDED move", returning the
    /// synced comment for the new position (nil = none). See Task 5.
    private let replayAdvance: (@MainActor () -> String?)?

    private var cycleTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    /// The in-flight pause drain, stored so cancelAll (a Menu exit) can cancel
    /// it before its continuation re-arms analysis for a torn-down screen.
    private var pauseTask: Task<Void, Never>?
    private var moveLanded = false
    private var genMoveIssued = false
    private var skipRequested = false
    /// Characters enqueued for speech so far this slide — bounds the
    /// end-of-slide speech hold against a wedged synthesizer (see
    /// waitOutDwellAndSpeech). Reset at slide entry.
    private var spokenCharactersThisSlide = 0
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
                sleeper: @escaping ReportSleeper = { try await Task.sleep(for: .seconds($0)) },
                speaker: NarrationSpeaking? = nil,
                isSpeechEnabled: @escaping () -> Bool = { false },
                pacing: @escaping () -> BroadcastPacing = { .live },
                replayAdvance: (@MainActor () -> String?)? = nil) {
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
        self.speaker = speaker
        self.isSpeechEnabled = isSpeechEnabled
        self.pacing = pacing
        self.replayAdvance = replayAdvance
    }

    public var isShowingSlides: Bool { currentSlide != nil }

    /// The screen's turn-change hook (fires off BoardView's shared observer
    /// signal). Starts the first cycle, chains the next one, or records that
    /// the pre-sent gen-move's stone landed mid-slideshow. Replay-mode
    /// screens must chain off `phase == .awaitingMove`, not off turn
    /// changes — a commented move's turn flip lands mid-comment-slide and is
    /// consumed here as `moveLanded`, never a fresh cycle.
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
    ///
    /// Idempotent and cancel-safe: the whole body runs inside a stored task.
    /// A second Play/Pause press during the drain early-returns (else it would
    /// double-arm continuous analysis), and a Menu-exit's cancelAll can cancel
    /// the in-flight drain — whose continuation must NOT re-arm kata-analyze
    /// for a screen cancelAll already tore down.
    public func pause(game: GameRecord) async {
        guard pauseTask == nil, phase != .paused else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            let cycle = self.cycleTask
            self.cycleTask = nil
            cycle?.cancel()
            await cycle?.value
            // A cancelAll during the drain cancels THIS task: it must not
            // mutate state (re-arm analysis, flip to .paused) after cancelAll
            // has already returned the screen to .idle.
            guard !Task.isCancelled else { return }
            self.speaker?.cancelAll()
            self.currentSlide = nil
            self.currentFrame = nil
            self.typedText = ""
            self.slideNumber = 0
            self.phase = .paused
            self.gobanState.analysisStatus = .run
            self.gobanState.requestAnalysis(config: game.concreteConfig,
                                            messageList: self.messageList,
                                            nextColorForPlayCommand: self.player.nextColorForPlayCommand)
        }
        pauseTask = task
        await task.value
        // Only clear the handle if a concurrent cancelAll (which nils it) or a
        // later pause has not already replaced it. Task is Equatable by
        // identity.
        if pauseTask == task { pauseTask = nil }
    }

    /// Re-enter the loop from the current (possibly user-altered) position.
    /// The next cycle's first probe cancels the paused screen's continuous
    /// analyze mid-stream — the safe, iOS-identical cancellation (its `=`
    /// ack was consumed long ago). issueGenMove restores the .clear protocol
    /// at the cycle's end.
    public func resume(game: GameRecord) {
        // Drop a resume pressed while a pick's legality check or a cancelled
        // gen-move reply is still in flight (the next press works): the
        // resumed cycle's collector must not arm over un-acked non-probe
        // traffic — the ReportCollector FIFO pops one stage per `=` line.
        guard phase == .paused,
              gobanState.pendingMoveTurn == nil,
              !gobanState.broadcastGenMovePending else { return }
        startCycle(game: game)
    }

    /// Teardown / new-game restart: abandon everything. The generator's
    /// probe-session defer runs restore() on cancellation, so the engine
    /// comes back to the game position on its own. Callers own analysisStatus
    /// restoration after this returns — cancelAll deliberately does not touch
    /// it.
    public func cancelAll() {
        cycleToken += 1
        pauseTask?.cancel()
        pauseTask = nil
        cycleTask?.cancel()
        cycleTask = nil
        generationTask?.cancel()
        generationTask = nil
        // An exit during .awaitingMove must not leave the gen-move license
        // armed: a later screen's stray "play" reply would otherwise consume
        // it, bypassing the review screen's spectator protection into a
        // CloudKit-synced record.
        gobanState.broadcastGenMovePending = false
        speaker?.cancelAll()
        currentSlide = nil
        currentFrame = nil
        typedText = ""
        slideNumber = 0
        phase = .idle
    }

    /// cancelAll, then await the cancelled tasks so callers can sequence
    /// engine traffic AFTER the generator's cooperative restore has drained
    /// (its deferred restore sends "stop" + an undo tail — anything armed
    /// before that lands gets killed by it; the pause path awaits the same
    /// drain for the same reason).
    public func cancelAllAndDrain() async {
        let cycle = cycleTask
        let generation = generationTask
        let pause = pauseTask
        cancelAll()
        await pause?.value
        await cycle?.value
        await generation?.value
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
        guard gobanState.passCount == 0 || replayAdvance != nil else {
            // Endgame formality (grilled decision): once passing starts,
            // no report segments — answer immediately, the interstitial
            // machinery takes over after the second pass. (Live only:
            // replay routes through the full cycle so its move source and
            // comment slide run — a report on a one-pass position is fine.)
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
            let chain = await self.runCycle(game: game, token: token)
            guard self.cycleToken == token else { return }
            self.cycleTask = nil
            // Replay publishes .awaitingMove only once the handle is clear:
            // the SCREEN chains off this phase signal (never the turn
            // observer — a commented move's turn flip lands mid-comment-slide
            // and is consumed as moveLanded), and publishing before the
            // handle cleared would let a fast observer's noteTurnChanged be
            // silently dropped by the cycleTask guard above.
            if self.replayAdvance != nil, !Task.isCancelled, self.phase != .idle {
                self.phase = .awaitingMove
            }
            if chain {
                self.startCycle(game: game)
            }
        }
    }

    /// Returns true when the gen-move's stone already landed mid-slideshow,
    /// so the caller chains straight into the next cycle.
    private func runCycle(game: GameRecord, token: Int) async -> Bool {
        // Turn-quiescence gate (structural): playAIMove toggles
        // nextColorForPlayCommand before the showboard/printsgf replies land,
        // so a cycle can arm over their un-acked `=` tails and generate() can
        // read a stale nextColorFromShowBoard (wrong-side report). The
        // showboard reply both settles the reply tail and makes the report
        // side authoritative — wait for it. Bounded, so a lost reply degrades
        // to today's behavior instead of hanging.
        var polls = 0
        while player.nextColorFromShowBoard != player.nextColorForPlayCommand
                && polls < 50 && !Task.isCancelled {
            try? await sleeper(BroadcastConstants.pollSeconds)
            polls += 1
        }
        if Task.isCancelled { return false }

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
        var cappedByPacing = false
        while !Task.isCancelled {
            let slides = BroadcastScript.slides(from: model)
            if index >= pacing().maxSlideCount {
                // Fast replay shows only the Best Move slide; the leftover
                // generation is cancelled below (probe restore() runs, the
                // same path pause takes).
                cappedByPacing = true
                break
            }
            if index >= slides.count {
                if model.stage.isSettled { break }
                try? await sleeper(BroadcastConstants.pollSeconds)
                continue
            }
            phase = .slides(index)
            slideNumber = index + 1
            slideCount = max(slides.count, slideCount)
            currentSlide = slides[index]
            // Constraint 5: the first frame lands in the SAME synchronous
            // block — the early-genmove await below would otherwise render
            // the new slide's title over the previous slide's terminal frame
            // (a stray pass chip under "Best Move …").
            currentFrame = BroadcastScript.frames(for: slides[index], model: model).first
            if model.stage.isSettled && index == slides.count - 1
                && !genMoveIssued && replayAdvance == nil {
                // Early gen-move (grilled decision): sent as the FINAL slide
                // starts, so the reply lands invisibly (hero and panel both
                // show report content) and the stone appears the moment the
                // live board returns. Generation is settled — restore() ran.
                await generation.value
                issueGenMove(game: game)
            }
            await present(slideIndex: index, model: model)
            index += 1
        }

        if Task.isCancelled || cappedByPacing {
            generation.cancel()
        }
        await generation.value
        // Only blank the shared slide state if no newer cycle owns it — a
        // late-draining cancelled cycle must not wipe its successor's live
        // slide (the same cycleToken the continuation checks).
        if cycleToken == token {
            currentSlide = nil
            currentFrame = nil
            typedText = ""
            slideNumber = 0
        }
        if Task.isCancelled { return false }
        if let replayAdvance {
            // The recorded move IS this cycle's move. genMoveIssued marks
            // "the move is played" so a turn change landing during the
            // comment slide takes the moveLanded branch in noteTurnChanged
            // instead of starting a nested cycle; the SCREEN chains cycles
            // (policy-gated), so replay always returns false.
            genMoveIssued = true
            let comment = replayAdvance()
            if let comment {
                await presentStandalone(BroadcastSlide(kind: .comment,
                                                       title: "Comment",
                                                       facts: [comment]),
                                        token: token)
            }
            if Task.isCancelled { return false }
            return false
        }
        if !genMoveIssued {
            issueGenMove(game: game)
        }
        phase = .awaitingMove
        return moveLanded
    }

    /// Types one slide's facts word-by-word while advancing its board
    /// choreography in LOCKSTEP: a fact's frames appear the moment it starts
    /// typing, its trailing beat frames drain before the next fact starts,
    /// and the dwell runs after both text and frames are done. Tolerates a
    /// fact list that is still growing (slide 1's tenuki line lands
    /// mid-typewriter).
    ///
    /// Frames are FROZEN at slide entry: re-derivation adopts a fresh list
    /// only when it strictly extends the current one (the late tenuki tail).
    /// setAlternative can replace model.candidates wholesale mid-show
    /// (resume-after-Undo + forced probe) — an unfrozen rebuild could flip
    /// the Δ/PV branch and reshape the list mid-drain.
    private func present(slideIndex: Int, model: DeepReportModel) async {
        typedText = ""
        spokenCharactersThisSlide = 0
        var elapsed: TimeInterval = 0
        var factIndex = 0
        var frames: [BroadcastBoardFrame] = []
        var frameCursor = 0

        func refreshFrames() {
            let slides = BroadcastScript.slides(from: model)
            guard slideIndex < slides.count else { return }
            let fresh = BroadcastScript.frames(for: slides[slideIndex], model: model)
            if frames.isEmpty
                || (fresh.count > frames.count
                    && Array(fresh.prefix(frames.count)) == frames) {
                frames = fresh
            }
        }
        refreshFrames()

        // Emit every frame due at the CURRENT fact (anchor .fact(i),
        // i ≤ factIndex). No sleeps: these show as their fact starts typing.
        func emitDueFactFrames() {
            while frameCursor < frames.count,
                  case .fact(let i) = frames[frameCursor].anchor, i <= factIndex {
                currentFrame = frames[frameCursor]
                frameCursor += 1
            }
        }

        // Drain consecutive beat frames at poll granularity so a skip stays
        // responsive and a pause's cancellation is honored; beat time accrues
        // into `elapsed` so the dwell formula stays honest.
        func drainBeatFrames() async {
            while frameCursor < frames.count,
                  case .afterPrevious(let beatLength) = frames[frameCursor].anchor {
                if Task.isCancelled || skipRequested { return }
                currentFrame = frames[frameCursor]
                frameCursor += 1
                var waited: TimeInterval = 0
                while waited < beatLength {
                    if Task.isCancelled || skipRequested { return }
                    try? await sleeper(BroadcastConstants.pollSeconds)
                    waited += BroadcastConstants.pollSeconds
                    elapsed += BroadcastConstants.pollSeconds
                }
            }
        }

        while !Task.isCancelled && !skipRequested {
            let slides = BroadcastScript.slides(from: model)
            guard slideIndex < slides.count else { break }
            let slide = slides[slideIndex]
            let facts = slide.facts
            refreshFrames()
            if factIndex < facts.count {
                emitDueFactFrames()
                if isSpeechEnabled() {
                    speaker?.speak(facts[factIndex])
                    spokenCharactersThisSlide += facts[factIndex].count
                }
                for chunk in BroadcastScript.typewriterChunks(facts[factIndex]) {
                    guard !Task.isCancelled && !skipRequested else { break }
                    typedText += chunk
                    let delay = Double(chunk.count) / pacing().charactersPerSecond
                    try? await sleeper(delay)
                    elapsed += delay
                }
                typedText += "\n"
                factIndex += 1
                await drainBeatFrames()
            } else if BroadcastScript.factsMayGrow(kind: slide.kind, model: model) {
                try? await sleeper(BroadcastConstants.pollSeconds)
                elapsed += BroadcastConstants.pollSeconds
            } else {
                break
            }
        }
        if skipRequested {
            skipRequested = false
            speaker?.cancelAll()
            return
        }
        guard !Task.isCancelled else { return }
        await waitOutDwellAndSpeech(elapsed: elapsed)
    }

    /// Types (and speaks) a slide that has NO choreography — the replay
    /// Comment slide. currentFrame stays nil, the one deliberate exception
    /// to the "frame non-nil while a slide shows" pairing: the TV screens
    /// mount the slide board only when a frame exists, so the LIVE hero
    /// board (already showing the just-played move) stays visible while the
    /// comment types over it in the panel.
    private func presentStandalone(_ slide: BroadcastSlide, token: Int) async {
        slideCount += 1
        slideNumber = slideCount
        currentSlide = slide
        currentFrame = nil
        typedText = ""
        spokenCharactersThisSlide = 0
        var elapsed: TimeInterval = 0
        for fact in slide.facts {
            guard !Task.isCancelled && !skipRequested else { break }
            if isSpeechEnabled() {
                speaker?.speak(fact)
                spokenCharactersThisSlide += fact.count
            }
            for chunk in BroadcastScript.typewriterChunks(fact) {
                guard !Task.isCancelled && !skipRequested else { break }
                typedText += chunk
                let delay = Double(chunk.count) / pacing().charactersPerSecond
                try? await sleeper(delay)
                elapsed += delay
            }
            typedText += "\n"
        }
        if skipRequested {
            skipRequested = false
            speaker?.cancelAll()
        } else if !Task.isCancelled {
            await waitOutDwellAndSpeech(elapsed: elapsed)
        }
        // Same guard as present()'s epilogue: a cancelled cycle draining
        // late must not blank a successor's live slide.
        guard !Task.isCancelled, cycleToken == token else { return }
        currentSlide = nil
        currentFrame = nil
        typedText = ""
        slideNumber = 0
    }

    /// The end-of-slide hold: the pacing dwell/floor PLUS, when narration is
    /// on, the remainder of the utterance queue (speech is never rate-
    /// shifted, so on fast pacing it becomes the slide's floor). Polled so a
    /// skip is honored AND consumed (the F4 regression) and cancellation is
    /// prompt; a consumed skip also cuts the speech off mid-word. The speech
    /// extension is itself capped (speechCeiling): a wedged synthesizer's
    /// isSpeaking is not under this controller's control, so an unbounded
    /// wait would park the whole broadcast — past the ceiling the utterance
    /// is cancelled and the slide advances on silent pacing.
    private func waitOutDwellAndSpeech(elapsed: TimeInterval) async {
        let dwell = max(pacing().minimumSlideSeconds - elapsed,
                        pacing().dwellSeconds)
        let speechCeiling = max(BroadcastConstants.speechHoldFloorSeconds,
                                Double(spokenCharactersThisSlide)
                                    / BroadcastConstants.assumedMinimumSpokenCharactersPerSecond)
        var dwelled: TimeInterval = 0
        while dwelled < dwell || speaker?.isSpeaking == true {
            if Task.isCancelled { return }
            if skipRequested {
                skipRequested = false
                speaker?.cancelAll()
                return
            }
            if dwelled >= dwell + speechCeiling {
                // The synthesizer wedged: degrade to silent pacing.
                speaker?.cancelAll()
                return
            }
            try? await sleeper(BroadcastConstants.pollSeconds)
            dwelled += BroadcastConstants.pollSeconds
        }
    }

    private func issueGenMove(game: GameRecord) {
        guard !genMoveIssued else { return }
        guard gobanState.passCount < 2 else { return }
        genMoveIssued = true
        // Restore the broadcast protocol BEFORE the gen-move: after a
        // paused-interactive stretch status is .run, and .clear keeps
        // BoardView's turn observer silent at the upcoming turn change.
        // The TV root's status observer reacts one update pass LATER —
        // after the gen-move below is on the FIFO — and is gated on the
        // armed license (GobanState.shouldStopEngineOnAnalysisClear), so
        // its "stop" cannot cancel this search (a stop-cancelled search
        // prints "play cancelled", never a vertex, and the cycle would
        // park in .awaitingMove forever).
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
        // Replay is a spectator: never write the synced record's per-move
        // dictionaries (the review no-write invariant). The headline and
        // chart playhead read the root models above.
        guard replayAdvance == nil else { return }
        game.winRates?[game.currentIndex] = blackWinrate
        withAnimation(.spring) {
            game.scoreLeads?[game.currentIndex] = blackScore
        }
    }
}
