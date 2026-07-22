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
    @State private var watchRelay = WatchSessionRelay()

    var body: some View {
        if isInitialized {
            GameSplitView(
                selectedModel: $selectedModel,
                aiMove: $aiMove,
                maxBoardLength: maxBoardLength
            )
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
            .task {
                watchRelay.start(session: session, navigationContext: navigationContext, audioModel: audioModel)
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
                // "Retake Photo" retry path.
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
        // resolves to the most-recently-modified game (unchanged). Resolve it
        // once and use it for the engine config, the selection, the book-compat
        // check, and the SGF load so they all agree on one game.
        let initialGame = GameRecord.resolveInitialSelection(
            pendingGameID: deepLinkRouter.pendingGameID,
            container: modelContext.container
        )
        deepLinkRouter.pendingGameID = nil
        session.sendInitialCommands(config: initialGame?.concreteConfig)

        // Surface the model name + engine version in the Configurations sheet.
        // The launch screen used to linger for a few seconds just to show
        // these; that wait is gone, so stash them where the gear button can
        // reach them (TopUIState rides the environment into GlobalSettingsView).
        topUIState.modelName = selectedModel?.title
        topUIState.engineVersion = version

        navigationContext.selectedGameRecord = initialGame
        navigationContext.selectedGameRecord?.updateToLatestVersion()
        if let cfg = initialGame?.concreteConfig, cfg.isBookEligible {
            session.bookLookup.loadIfNeeded(boardSize: cfg.boardWidth)
        }

        session.gobanState.maybeLoadSgf(
            gameRecord: navigationContext.selectedGameRecord,
            messageList: session.messageList
        )

        session.gobanState.sendShowBoardCommand(messageList: session.messageList)
        session.messageList.appendAndSend(command: "printsgf")
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
