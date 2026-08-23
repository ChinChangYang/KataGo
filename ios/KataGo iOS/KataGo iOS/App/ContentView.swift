//
//  ContentView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/7/2.
//

import SwiftUI
import SwiftData
import KataGoUICore

struct ContentView: View {
    @Binding var selectedModel: NeuralNetworkModel?
    let engineLifecycle: EngineLifecycle
    let maxBoardLength: Int

    @State private var session = GameSession()
    @Query(sort: \GameRecord.lastModificationDate, order: .reverse) var gameRecords: [GameRecord]
    @Environment(\.modelContext) private var modelContext
    @Environment(DeepLinkRouter.self) private var deepLinkRouter
    @State private var navigationContext = NavigationContext()
    @State private var isInitialized = false
    @State var isGameListViewAppeared = false
    @Environment(\.horizontalSizeClass) var horizontalSizeClass: UserInterfaceSizeClass?
    @State var version: String?
    @State var thumbnailModel = ThumbnailModel()
    @State var audioModel = AudioModel()
    @State private var topUIState = TopUIState()
    @State var aiMove: String? = nil

    var body: some View {
        if isInitialized {
            GameSplitView(
                selectedModel: $selectedModel,
                aiMove: $aiMove,
                maxBoardLength: maxBoardLength
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
            .environment(navigationContext)
            .environment(thumbnailModel)
            .environment(audioModel)
            .environment(topUIState)
            .environment(session.bookLookup)
            .onChange(of: topUIState.quitStatus) { _, newValue in
                // Mirror the app's quit lifecycle onto the session loop. The
                // original `messaging()` gated per-line processing on
                // `quitStatus == .none` (so the `.quitting` window stops
                // processing) and the loop ran `while quitStatus != .quitted`.
                // `!stopRequested` collapses both, so flip it as soon as the
                // status leaves `.none`. The status now rides `TopUIState` so
                // the Configurations sheet (Model/Version tap) can trigger it.
                if newValue != .none {
                    session.stopRequested = true
                }
            }
            // Covers a book download that outlives the opening-book picker:
            // started there, finishing after a game session has begun. It
            // cannot fire while the picker itself is on screen — that screen
            // is only reachable when no model is selected, and this view is
            // only mounted when one is, so the two never coexist. That is not
            // a gap: there is no `BookLookup` to call before a session
            // exists, so a book that finishes during the picker becomes
            // usable through the paths that already cover it — the session's
            // own `loadIfNeeded` at startup, and the eye button's
            // availability check, which reads disk state directly.
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
            // `loadIfNeeded` is a no-op when the size is already loaded or the
            // book is missing, so this is cheap and idempotent.
            .onChange(of: DownloadCenter.shared.finishedGeneration) { _, _ in
                guard let config = navigationContext.selectedGameRecord?.concreteConfig,
                      config.isBookEligible,
                      let book = OpeningBook.book(forBoardSize: config.boardWidth),
                      book.isDownloaded else { return }
                session.bookLookup.loadIfNeeded(boardSize: book.boardSize)
            }
            .task {
                // Get messages from KataGo and append to the list of messages
                await session.run(
                    gameRecords: gameRecords,
                    modelContext: modelContext,
                    navigationContext: navigationContext,
                    audioModel: audioModel,
                    aiMove: $aiMove
                )
            }
            .task {
                // DEBUG-only: auto-present the photo-import sheet with a bundled
                // clear-board image so the end-to-end UI test can drive the
                // recognition → preview → Import flow without the out-of-process
                // PhotosPicker. No-op unless its launch argument is present.
                // The camera seam mirrors it for the (cameraless) Simulator,
                // injecting a `.camera`-sourced pending import to exercise the
                // "Retake" retry path.
                #if DEBUG
                PhotoImportUITestSupport.presentIfNeeded(into: topUIState)
                CameraCaptureUITestSupport.presentIfNeeded(into: topUIState)
                CropImportUITestSupport.presentIfNeeded(into: topUIState)
                #endif
            }
        } else if selectedModel != nil {
            LoadingView(version: $version)
                .task {
                    await initializationTask()
                }
        }
    }

    private func initializationTask() async {
        // Handshake first: the blocking `version` read spans the engine's
        // model load (seconds), which is also the window where the system
        // delivers a cold-launch `open-game` URL to the root `.onOpenURL`.
        version = await session.handshake(
            selectedModelTitle: selectedModel?.title ?? "",
            engineLifecycle: engineLifecycle
        )

        // A widget `open-game` deep link captured at the root (`DeepLinkRouter`)
        // wins over the default most-recent selection, so a cold-launch widget
        // tap opens the configured game. Resolved AFTER the handshake await —
        // reading `pendingGameID` before it raced the asynchronous URL delivery
        // and lost on the Release auto-restore path (Debug always shows the
        // model picker, which masked the race). With no pending deep link this
        // resolves to the most-recently-modified game, and on a genuinely empty
        // library it CREATES the first game — engine-free, where a `printsgf`
        // reply used to birth it. A deep link that arrives after this point is
        // drained by `GameSplitView`'s `pendingGameID` observer.
        let initialGame = GameRecord.resolveOrCreateInitialSelection(
            pendingGameID: deepLinkRouter.pendingGameID,
            container: modelContext.container
        )
        deepLinkRouter.pendingGameID = nil

        // Surface the model name + engine version in the Configurations sheet.
        // The launch screen used to linger for a few seconds just to show
        // these; that wait is gone, so stash them where the gear button can
        // reach them (TopUIState rides the environment into GlobalSettingsView).
        topUIState.modelName = selectedModel?.title
        topUIState.engineVersion = version

        navigationContext.selectedGameRecord = initialGame
        initialGame.updateToLatestVersion()
        let initialConfig = initialGame.concreteConfig
        if initialConfig.isBookEligible {
            session.bookLookup.loadIfNeeded(boardSize: initialConfig.boardWidth)
        }

        // The one seeding path: `loadGame` projects the record position (the
        // board is drawn before the engine is told anything) and then FEEDS the
        // engine that position move by move — board size, rules, setup stones
        // and one `play` per accepted move. It subsumes `sendInitialCommands`,
        // `loadsgf` and the `printsgf` echo, and it honours the record's saved
        // cursor instead of parking at the tip.
        //
        // Called directly rather than left to `GameSplitView`'s selection
        // observer: that observer is not `initial:`, and the view is not
        // mounted yet.
        session.gobanState.loadGame(gameRecord: initialGame,
                                    player: session.player,
                                    bookLookup: session.bookLookup,
                                    messageList: session.messageList,
                                    board: session.board,
                                    stones: session.stones,
                                    analysis: session.analysis,
                                    projector: session.recordPosition)
        await session.messaging(
            gameRecords: gameRecords,
            modelContext: modelContext,
            navigationContext: navigationContext,
            audioModel: audioModel,
            aiMove: $aiMove
        )
        isInitialized = true
    }
}
