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
    @State private var navigationContext = NavigationContext()
    @State private var isInitialized = false
    @State var isGameListViewAppeared = false
    @Environment(\.horizontalSizeClass) var horizontalSizeClass: UserInterfaceSizeClass?
    @State var version: String?
    @State var thumbnailModel = ThumbnailModel()
    @State var audioModel = AudioModel()
    @State var quitStatus: QuitStatus = .none
    @State private var topUIState = TopUIState()
    @State var aiMove: String? = nil

    var body: some View {
        if isInitialized {
            GameSplitView(
                selectedModel: $selectedModel,
                aiMove: $aiMove,
                quitStatus: $quitStatus,
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
            .onChange(of: quitStatus) { _, newValue in
                // Mirror the app's quit lifecycle onto the session loop. The
                // original `messaging()` gated per-line processing on
                // `quitStatus == .none` (so the `.quitting` window stops
                // processing) and the loop ran `while quitStatus != .quitted`.
                // `!stopRequested` collapses both, so flip it as soon as the
                // status leaves `.none`.
                if newValue != .none {
                    session.stopRequested = true
                }
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
        } else if let model = selectedModel {
            LoadingView(version: $version, selectedModel: model)
                .task {
                    await initializationTask()
                }
        }
    }

    private func initializationTask() async {
        version = await session.initialize(
            selectedModelTitle: selectedModel?.title ?? "",
            engineLifecycle: engineLifecycle,
            config: gameRecords.first?.concreteConfig
        )

        navigationContext.selectedGameRecord = gameRecords.first
        navigationContext.selectedGameRecord?.updateToLatestVersion()
        if gameRecords.first?.concreteConfig.isBookCompatible == true {
            session.bookLookup.loadIfNeeded()
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
        try? await Task.sleep(for: .seconds(3))
        isInitialized = true
    }
}
