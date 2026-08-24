//
//  ContentView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/7/2.
//

import SwiftUI
import SwiftData
import KataGoUICore

/// The board tree, mounted on the first frame and never taken down again.
///
/// It used to be a gate: a `LoadingView` until `isInitialized` flipped, and the
/// engine handshake ran inside it. Both are gone. The engine's state is now a
/// LINE over the board (`EngineStatusView`, injected here as
/// `session.engineStatus`), the launch belongs to `AppEngineController`, and
/// what is left here is the seeding that never needed an engine in the first
/// place: resolve which game to open, project its position, and ask for the
/// feed (which the command gate holds until an engine can take it).
struct ContentView: View {
    let session: GameSession
    let controller: AppEngineController
    let navigationContext: NavigationContext
    let topUIState: TopUIState

    @Query(sort: \GameRecord.lastModificationDate, order: .reverse) var gameRecords: [GameRecord]
    @Environment(\.modelContext) private var modelContext
    @Environment(DeepLinkRouter.self) private var deepLinkRouter
    @State var thumbnailModel = ThumbnailModel()
    @State var audioModel = AudioModel()
    @State var aiMove: String? = nil

    /// Everything the board size gates on, in one comparable value, so a single
    /// `.onChange` covers "the game changed", "its board was resized", "the
    /// engine relaunched with a different NN buffer" and "the engine became
    /// ready". Held together because the answer — Held or not — depends on all
    /// four, and splitting it into four observers would let them disagree.
    private struct HeldInputs: Equatable {
        var width: Int
        var height: Int
        var maxBoardLength: Int
        var availability: EngineAvailability
    }

    private var heldInputs: HeldInputs {
        // The board size comes from the PROJECTED position (`session.board`),
        // which the projector writes from the record's SGF — the same source
        // the engine feed sizes itself from. Reading `Config.boardWidth`
        // instead would let the two disagree on an imported record whose
        // config was never updated, and then the feed would refuse a board the
        // status line called fine. Zero when nothing is selected: the projector
        // keeps the outgoing game's size, and "no game" is not "too large".
        let hasGame = navigationContext.selectedGameRecord != nil
        return HeldInputs(width: hasGame ? Int(session.board.width) : 0,
                          height: hasGame ? Int(session.board.height) : 0,
                          maxBoardLength: controller.maxBoardLength,
                          availability: session.engineStatus.availability)
    }

    var body: some View {
        GameSplitView(
            aiMove: $aiMove,
            maxBoardLength: controller.maxBoardLength
        )
        // The session itself, so `GameSplitView` can drive the record
        // position through `session.recordPosition` (the one projector).
        .environment(session)
        .environment(session.stones)
        .environment(session.messageList)
        .environment(session.board)
        .environment(session.player)
        .environment(session.analysis)
        .environment(session.gobanState)
        .environment(session.rootWinrate)
        .environment(session.rootScore)
        // Engine availability, read back as an OPTIONAL `@Environment` by
        // `BoardView` (the inline status line) and by the toolbar's analysis
        // toggle. This injection is what turns the C4 status view on for iOS.
        .environment(session.engineStatus)
        .environment(navigationContext)
        .environment(thumbnailModel)
        .environment(audioModel)
        .environment(topUIState)
        .environment(session.bookLookup)
        // Covers a book download that outlives the opening-book picker:
        // started there, finishing after a game session has begun.
        //
        // Deliberately does NOT read `lastFinishedDestination`. Two
        // finishes CAN land in one main-actor turn — `finish` ends with
        // `advanceQueue`, which starts the next download, which
        // short-circuits straight back to `finish` when its staged partial
        // already covers the declared total — and that is one `.onChange`
        // for two bumps, with the first destination overwritten. The
        // background-relaunch path makes it likelier still, since a
        // relaunch can leave more than one transfer complete-but-
        // uninstalled for the next foreground launch to finish.
        //
        // So re-scan instead of trusting a single last-value slot: ask
        // whether the book this game actually needs is on disk NOW.
        // `loadIfNeeded` resolves the active book itself (catalog download or
        // user import) and is a no-op when that book — same size AND same
        // identity — is already loaded, so this is cheap and idempotent.
        .onChange(of: DownloadCenter.shared.finishedGeneration) { _, _ in
            guard let config = navigationContext.selectedGameRecord?.concreteConfig,
                  config.isBookEligible else { return }
            session.bookLookup.loadIfNeeded(boardSize: config.boardWidth)
        }
        // The Configurations sheet names the running net and its version. The
        // handshake is the only thing that knows them, so mirror rather than
        // set once: a background relaunch (model switch, Retry) has to update
        // both, and there is no launch screen left to read them off.
        .onChange(of: session.engineStatus.modelTitle, initial: true) { _, newValue in
            topUIState.modelName = newValue
        }
        .onChange(of: session.engineStatus.engineVersion, initial: true) { _, newValue in
            topUIState.engineVersion = newValue
        }
        // Held: the record on screen is bigger than the running engine's NN
        // buffer. The board still draws it — this only decides what the status
        // line says and whether analysis is offered.
        .onChange(of: heldInputs, initial: true) { _, inputs in
            controller.applyHeldStatus(boardWidth: inputs.width,
                                       boardHeight: inputs.height)
        }
        .task {
            // Engine-free seeding. Runs on the first frame, before any engine
            // exists: the position is projected from the record's SGF and the
            // feed is offered to a gate that is still shut, which records the
            // debt. `AppEngineController` pays it after the handshake.
            seedInitialGame()
        }
        .task(id: controller.readLoopGeneration) {
            // The GTP read loop, armed only once an engine has completed its
            // FIRST handshake — the handshake must be the bridge's sole reader,
            // and a loop started before it would eat the `version` reply.
            //
            // Keyed on a generation that bumps exactly once, so a RESTART does
            // not re-key (and therefore cancel) this task: `session.run` exits
            // on `stopRequested`, and `noteRunLoopExited` parks the loop until
            // the replacement engine's handshake lands. Without the park, the
            // exited `run` would busy-spin here.
            guard controller.readLoopGeneration > 0 else { return }
            while !Task.isCancelled {
                await session.run(
                    gameRecords: gameRecords,
                    modelContext: modelContext,
                    navigationContext: navigationContext,
                    audioModel: audioModel,
                    aiMove: $aiMove
                )
                await controller.noteRunLoopExited()
            }
        }
        .task(id: topUIState.presentingModelPicker) {
            // DEBUG-only: auto-present the photo-import sheet with a bundled
            // clear-board image so the end-to-end UI test can drive the
            // recognition → preview → Import flow without the out-of-process
            // PhotosPicker. No-op unless its launch argument is present.
            // The camera seam mirrors it for the (cameraless) Simulator,
            // injecting a `.camera`-sourced pending import to exercise the
            // "Retake" retry path.
            //
            // Keyed on the picker so these sheets are never presented UNDER it:
            // in DEBUG the picker is up from the first frame, and a sheet
            // presented from this (covered) tree in the same window would be
            // dropped. The settle sleep is the same present-after-dismiss
            // courtesy `GameSplitView` pays between its own two presentations.
            #if DEBUG
            guard !topUIState.presentingModelPicker else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            PhotoImportUITestSupport.presentIfNeeded(into: topUIState)
            CameraCaptureUITestSupport.presentIfNeeded(into: topUIState)
            CropImportUITestSupport.presentIfNeeded(into: topUIState)
            #endif
        }
    }

    /// Resolve (or create) the game the app opens with, and put it on screen.
    /// Engine-free from end to end — the board is drawn from the record's own
    /// SGF, and the engine is merely told about it afterwards.
    private func seedInitialGame() {
        // A widget `open-game` deep link captured at the root (`DeepLinkRouter`)
        // wins over the default most-recent selection, so a cold-launch widget
        // tap opens the configured game. With no pending deep link this
        // resolves to the most-recently-modified game, and on a genuinely empty
        // library it CREATES the first game. A deep link that arrives after
        // this point is drained by `GameSplitView`'s `pendingGameID` observer.
        //
        // The old race this used to fight — reading `pendingGameID` before the
        // asynchronous URL delivery landed — is gone with the blocking
        // handshake it used to be sequenced against: nothing is awaited here,
        // so this runs on the first frame and `GameSplitView`'s `initial: true`
        // drain covers anything later.
        let initialGame = GameRecord.resolveOrCreateInitialSelection(
            pendingGameID: deepLinkRouter.pendingGameID,
            container: modelContext.container
        )
        deepLinkRouter.pendingGameID = nil

        navigationContext.selectedGameRecord = initialGame
        initialGame.updateToLatestVersion()
        let initialConfig = initialGame.concreteConfig
        if initialConfig.isBookEligible {
            session.bookLookup.loadIfNeeded(boardSize: initialConfig.boardWidth)
        }

        // The one seeding path: `loadGame` projects the record position (the
        // board is drawn before the engine is told anything) and then FEEDS the
        // engine that position move by move — board size, rules, setup stones
        // and one `play` per accepted move. While no engine is listening the
        // feed is dropped and remembered on `engineSyncGate`; the controller
        // replays it, against the LIVE record, once a handshake lands.
        //
        // Called directly rather than left to `GameSplitView`'s selection
        // observer: that observer is not `initial:`, and the view has only just
        // mounted.
        session.gobanState.loadGame(gameRecord: initialGame,
                                    player: session.player,
                                    bookLookup: session.bookLookup,
                                    messageList: session.messageList,
                                    board: session.board,
                                    stones: session.stones,
                                    analysis: session.analysis,
                                    projector: session.recordPosition)
    }
}
