//
//  GameSplitView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/12/8.
//

import SwiftUI
import UniformTypeIdentifiers
import KataGoUICore
import WidgetKit

struct GameSplitView: View {
    @Binding var selectedModel: NeuralNetworkModel?
    let sgfType = UTType("ccy.KataGo-iOS.sgf")!

    @Binding var aiMove: String?
    @Binding var quitStatus: QuitStatus
    let maxBoardLength: Int

    @State var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var isEditorPresented = false
    @State var isGameListViewAppeared = false

    @Environment(Stones.self) var stones
    @Environment(MessageList.self) var messageList
    @Environment(BoardSize.self) var board
    @Environment(Turn.self) var player
    @Environment(Analysis.self) var analysis
    @Environment(GobanState.self) var gobanState
    @Environment(Winrate.self) var rootWinrate
    @Environment(Score.self) var rootScore
    @Environment(NavigationContext.self) var navigationContext
    @Environment(ThumbnailModel.self) var thumbnailModel
    @Environment(AudioModel.self) var audioModel
    @Environment(TopUIState.self) var topUIState
    @Environment(BookLookup.self) var bookLookup

    @Environment(\.scenePhase) var scenePhase
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var topUIState = topUIState

        splitView
            .confirmationDialog(
                "Are you sure you want to delete this game? THIS ACTION IS IRREVERSIBLE!",
                isPresented: $topUIState.confirmingDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let gameRecord = navigationContext.selectedGameRecord {
                        navigationContext.selectedGameRecord = nil
                        modelContext.safelyDelete(gameRecord: gameRecord)
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }

                Button("Cancel", role: .cancel) {
                    topUIState.confirmingDeletion = false
                }
            }
            .confirmationDialog(
                "Are you sure you want to delete \(topUIState.selectionCount) game\(topUIState.selectionCount == 1 ? "" : "s")? THIS ACTION IS IRREVERSIBLE!",
                isPresented: $topUIState.confirmingBulkDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let ids = topUIState.selectedGameIDs
                    // Clear the open game first if it's among those being deleted.
                    if let open = navigationContext.selectedGameRecord,
                       ids.contains(open.persistentModelID) {
                        navigationContext.selectedGameRecord = nil
                    }
                    _ = modelContext.bulkDelete(gameIDs: ids)
                    topUIState.exitSelection()
                    WidgetCenter.shared.reloadAllTimelines()
                }

                Button("Cancel", role: .cancel) {
                    topUIState.confirmingBulkDeletion = false
                }
            }
            .fileImporter(
                isPresented: $topUIState.importing,
                allowedContentTypes: [sgfType, .text],
                allowsMultipleSelection: true
            ) { result in
                importFiles(result: result)
            }
            .onDrop(of: [sgfType, .text], isTargeted: nil, perform: handleDrop)
    }

    private var splitView: some View {
        @Bindable var navigationContext = navigationContext
        @Bindable var gobanState = gobanState

        return NavigationSplitView(columnVisibility: $columnVisibility) {
            GameListView(isEditorPresented: $isEditorPresented,
                         selectedGameRecord: $navigationContext.selectedGameRecord,
                         isGameListViewAppeared: $isGameListViewAppeared)
            .toolbar {
                GameListToolbar(
                    gameRecord: navigationContext.selectedGameRecord,
                    maxBoardLength: maxBoardLength,
                    quitStatus: $quitStatus
                )
            }
        } detail: {
            detailView
        }
        .modifier(GlobalPreferenceSync(gobanState: gobanState))
        .onChange(of: navigationContext.selectedGameRecord) { oldGameRecord, newGameRecord in
            createThumbnail(for: oldGameRecord)
            WidgetCenter.shared.reloadAllTimelines()
            processChange(oldGameRecord: oldGameRecord, newGameRecord: newGameRecord)
        }
        .onChange(of: gobanState.waitingForAnalysis) { oldWaitingForAnalysis, newWaitingForAnalysis in
            processChange(oldWaitingForAnalysis: oldWaitingForAnalysis,
                          newWaitingForAnalysis: newWaitingForAnalysis)
        }
        .onOpenURL { url in
            if let id = GameDeepLink.gameID(from: url) {
                selectGame(byID: id)
            } else {
                importAndSelect(from: url)
            }
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            processChange(newScenePhase: newScenePhase)
        }
        .onChange(of: gobanState.branchSgf) { oldBranchStateSgf, newBranchStateSgf in
            processChange(oldBranchStateSgf: oldBranchStateSgf,
                          newBranchStateSgf: newBranchStateSgf)
        }
        .onChange(of: isGameListViewAppeared) { oldIsGameListViewAppeared, newIsGameListViewAppeared in
            processChange(oldIsGameListViewAppeared: oldIsGameListViewAppeared,
                          newIsGameListViewAppeared: newIsGameListViewAppeared)
        }
        .onChange(of: gobanState.isEditing) { oldIsEditing, newIsEditing in
            processIsEditingChange(oldIsEditing: oldIsEditing, newIsEditing: newIsEditing)
        }
        .onChange(of: gobanState.isAutoPlaying) { oldIsAutoPlaying, newIsAutoPlaying in
            processIsAutoPlayingChange(
                oldIsAutoPlaying: oldIsAutoPlaying,
                newIsAutoPlaying: newIsAutoPlaying
            )
        }
        .onChange(of: stones.isReady) { oldValue, newValue in
            processStonesReadyChange(
                oldValue: oldValue,
                newValue: newValue
            )
        }
        .onChange(of: gobanState.analysisStatus) { _, newValue in
            processAnalysisStatusChange(newValue: newValue)
        }
        .onChange(of: bookLookup.isLoaded) { _, newValue in
            processBookLoadedChange(newValue: newValue)
        }
        .onChange(of: gobanState.eyeStatus) { oldEyeStatus, newEyeStatus in
            processEyeStatusChange(oldEyeStatus: oldEyeStatus, newEyeStatus: newEyeStatus)
        }
    }

    private var detailView: some View {
        @Bindable var gobanState = gobanState

        return GobanView(isEditorPresented: $isEditorPresented,
                         maxBoardLength: maxBoardLength,
                         columnVisibility: $columnVisibility)
        .confirmationDialog(
            "Do you allow AI overwriting this move?",
            isPresented: $gobanState.confirmingAIOverwrite,
            titleVisibility: .visible
        ) {
            Button("Overwrite", role: .destructive) {
                if let gameRecord = navigationContext.selectedGameRecord,
                   let turn = player.nextColorSymbolForPlayCommand {
                    gobanState.playAIMove(
                        aiMove: aiMove,
                        gameRecord: gameRecord,
                        turn: turn,
                        analysis: analysis,
                        board: board,
                        stones: stones,
                        messageList: messageList,
                        player: player,
                        audioModel: audioModel
                    )
                }
            }

            Button("Cancel", role: .cancel) {
                gobanState.confirmingAIOverwrite = false
                gobanState.analysisStatus = .clear
            }
        }
        .confirmationDialog(
            illegalMoveReasonText,
            isPresented: $gobanState.confirmingIllegalMove,
            titleVisibility: .visible
        ) {
            Button("Play Anyway", role: .destructive) {
                if let gameRecord = navigationContext.selectedGameRecord {
                    gobanState.playPendingHumanMove(
                        gameRecord: gameRecord,
                        analysis: analysis,
                        board: board,
                        stones: stones,
                        messageList: messageList,
                        player: player,
                        audioModel: audioModel
                    )
                } else {
                    gobanState.clearPendingMove()
                }
            }

            Button("Cancel", role: .cancel) {
                gobanState.clearPendingMove()
            }
        }
        .confirmationDialog(
            "Branch moves are temporary. Replace the original game with this branch, or discard it?",
            isPresented: $gobanState.confirmingBranchDeactivation,
            titleVisibility: .visible
        ) {
            Button("Replace") {
                // Defer to the next runloop so the first dialog fully
                // dismisses before the second presents. Chaining
                // confirmationDialogs in the same transaction (present
                // while dismissing) is fragile on iOS 26 and can silently
                // drop the second sheet. Button actions are MainActor-
                // isolated, so this one-turn hop is concurrency-safe.
                Task { @MainActor in
                    gobanState.confirmingBranchReplace = true
                }
            }

            Button("Discard Branch") {
                Task { @MainActor in
                    gobanState.confirmingBranchDiscard = true
                }
            }

            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog(
            "Replace the original game with this branch? The original game’s moves after this point will be permanently lost.",
            isPresented: $gobanState.confirmingBranchReplace,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                if let gameRecord = navigationContext.selectedGameRecord {
                    gobanState.commitBranch(gameRecord: gameRecord)
                } else {
                    // No game to replace (unreachable in practice): exit branch
                    // mode anyway so confirming never leaves the branch stuck,
                    // mirroring the Discard path below.
                    gobanState.deactivateBranch()
                }
            }

            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog(
            "Discard this branch? Your newly played stones will be lost.",
            isPresented: $gobanState.confirmingBranchDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Branch", role: .destructive) {
                gobanState.deactivateBranch()
            }

            Button("Cancel", role: .cancel) { }
        }
    }

    private var illegalMoveReasonText: String {
        switch gobanState.illegalMoveReason {
        case "ko": return "This move violates the ko rule."
        case "suicide": return "This move is a suicide (self-capture)."
        case "superko": return "This move violates the superko rule."
        default: return "This move is illegal."
        }
    }

    private func processChange(newScenePhase: ScenePhase) {
        if newScenePhase == .background {
            createThumbnail(for: navigationContext.selectedGameRecord)
            gobanState.maybePauseAnalysis()
        }
    }

    private func processStonesReadyChange(oldValue: Bool, newValue: Bool) {
        if !oldValue && newValue,
           let gameRecord = navigationContext.selectedGameRecord {

            let currentIndex = gameRecord.currentIndex

            // `refillString` (not `toString`) so an empty side stays present-but-empty
            // ("") rather than dropping the key (`dict[i] = nil` removes it) — matching
            // the SGF-import path and keeping GameEntity.lastIndex on the displayed move.
            gameRecord.blackStones?[currentIndex] = BoardPoint.refillString(
                stones.blackPoints,
                width: Int(board.width),
                height: Int(board.height)
            )

            gameRecord.whiteStones?[currentIndex] = BoardPoint.refillString(
                stones.whitePoints,
                width: Int(board.width),
                height: Int(board.height)
            )

            if gobanState.isAutoPlayed {
                gameRecord.currentIndex += 1
            }

            // Sync book state after undo/forward/backward
            syncBookState()
        }
    }

    private func processIsAutoPlayingChange(oldIsAutoPlaying: Bool,
                                            newIsAutoPlaying: Bool) {
        if gobanState.isAutoPlaying,
           let gameRecord = navigationContext.selectedGameRecord {
            gobanState.analysisStatus = .pause
            gobanState.eyeStatus = .opened
            gobanState.deactivateBranch()

            let sgfHelper = SgfHelper(sgf: gameRecord.sgf)
            while sgfHelper.getMove(at: gameRecord.currentIndex - 1) != nil {
                gameRecord.undo()
                gobanState.undo(messageList: messageList, stones: stones)
                player.toggleNextColorForPlayCommand()
            }

            // auto-play analysis by best AI profile
            if let humanSLModel = HumanSLModel(profile: "AI") {
                messageList.appendAndSend(commands: humanSLModel.commands)
                messageList.appendAndSend(command: "kata-set-param playoutDoublingAdvantage 0")
                messageList.appendAndSend(command: "kata-set-param analysisWideRootNoise 0")
            }

            gobanState.sendPostExecutionCommands(
                config: gameRecord.concreteConfig,
                messageList: messageList,
                player: player
            )
        } else {
            withAnimation {
                gobanState.analysisStatus = .clear
            }

            // restore human profile for the next player
            if let gameRecord = navigationContext.selectedGameRecord,
               let config = gameRecord.config {
                gobanState.maybeSendAsymmetricHumanAnalysisCommands(
                    nextColorForPlayCommand: player.nextColorForPlayCommand,
                    config: config,
                    messageList: messageList)

                messageList.appendAndSend(command: GtpCommandBuilder.playoutDoublingAdvantageCommand(config.playoutDoublingAdvantage))
                messageList.appendAndSend(command: GtpCommandBuilder.analysisWideRootNoiseCommand(config.analysisWideRootNoise))

                // current index might not be correct, recover it
                gobanState.forwardMoves(
                    limit: nil,
                    gameRecord: gameRecord,
                    board: board,
                    messageList: messageList,
                    player: player,
                    audioModel: audioModel,
                    stones: stones)
            }
        }
    }

    private func processIsEditingChange(oldIsEditing: Bool, newIsEditing: Bool) {
        if !newIsEditing {
            gobanState.isAutoPlaying = false
            gobanState.isAutoPlayed = false
        }
    }

    private func processChange(oldIsGameListViewAppeared: Bool,
                               newIsGameListViewAppeared: Bool) {
        if !oldIsGameListViewAppeared && newIsGameListViewAppeared && gobanState.isShownBoard {
            createThumbnail(for: navigationContext.selectedGameRecord)
        }
    }

    private func createThumbnail(for gameRecord: GameRecord?) {
        if let gameRecord {
            let maxBoardLength = max(board.width + 1, board.height + 1)
            let maxCGLength: CGFloat = ThumbnailModel.largeSize
            let cgWidth = (board.width + 1) / maxBoardLength * maxCGLength
            let cgHeight = (board.height + 1) / maxBoardLength * maxCGLength
            let cgSize = CGSize(width: cgWidth, height: cgHeight)
            let isDrawingCapturedStones = false
            let dimensions = Dimensions(size: cgSize,
                                        width: board.width,
                                        height: board.height,
                                        showCoordinate: false,
                                        showPass: false,
                                        isDrawingCapturedStones: isDrawingCapturedStones)

            let config = gameRecord.concreteConfig
            let content = ZStack {
                BoardLineView(dimensions: dimensions,
                              showPass: false,
                              verticalFlip: gobanState.verticalFlip)

                StoneView(dimensions: dimensions,
                          isClassicStoneStyle: gobanState.isClassicStoneStyle,
                          verticalFlip: gobanState.verticalFlip,
                          isDrawingCapturedStones: isDrawingCapturedStones)

                AnalysisView(config: config, dimensions: dimensions)
            }
                .environment(board)
                .environment(stones)
                .environment(analysis)
                .environment(gobanState)
                .environment(player)
                .environment(bookLookup)

            let renderer = ImageRenderer(content: content)
#if os(macOS)
            if let nsImage = renderer.nsImage,
               let tiffData = nsImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                gameRecord.thumbnail = pngData
            }
#else
            gameRecord.thumbnail = renderer.uiImage?.heicData()
#endif
        }
    }

    private func processAnalysisStatusChange(newValue: AnalysisStatus) {
        if newValue == .clear {
            messageList.appendAndSend(command: "stop")
        }
    }

    private func processBookLoadedChange(newValue: Bool) {
        if newValue {
            syncBookState()
        }
    }

    private func processEyeStatusChange(oldEyeStatus: EyeStatus, newEyeStatus: EyeStatus) {
        if newEyeStatus == .book {
            syncBookState()
        }

        // Revealing the overlay again resumes the continuous analysis that
        // power-saving stopped while it was hidden. Only the human's turn in a
        // human-vs-AI game was ever stopped, so skip while the engine is
        // generating an AI move (avoids double-issuing kata-analyze) and for
        // both-human / both-AI games (nothing was stopped).
        if newEyeStatus == .opened,
           oldEyeStatus != .opened,
           gobanState.analysisStatus == .run,
           let config = navigationContext.selectedGameRecord?.config,
           !gobanState.shouldGenMove(config: config, player: player) {
            gobanState.maybeRequestAnalysis(
                config: config,
                nextColorForPlayCommand: player.nextColorForPlayCommand,
                messageList: messageList
            )
        }

        // Hiding the overlay stops an already-running analysis to save power.
        // The continuous-analysis loop won't send "stop" on its own here (no
        // `waitingForAnalysis` edge occurs mid-stream), so arm one. Only fires
        // on the human's turn of a human-vs-AI game; the resume branch above
        // restarts it on reveal.
        if oldEyeStatus == .opened,
           newEyeStatus != .opened,
           let config = navigationContext.selectedGameRecord?.config {
            gobanState.maybeStopAnalysisForPowerSaving(
                config: config,
                nextColorForPlayCommand: player.nextColorForPlayCommand
            )
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var foundMatch = false
        for provider in providers {
            let typeIdentifier = provider.registeredTypeIdentifiers.first {
                $0 == sgfType.identifier || $0 == UTType.utf8PlainText.identifier || $0 == UTType.fileURL.identifier
            }
            guard let typeIdentifier else { continue }
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                // Read file NOW — the temp file is deleted when this closure returns
                guard let url,
                      let content = GameRecord.readSgfContent(from: url) else { return }
                Task { @MainActor in
                    importAndSelect(sgf: content.sgf, name: content.name)
                }
            }
            foundMatch = true
        }
        return foundMatch
    }

    // Handles file import from the document picker
    private func importFiles(result: Result<[URL], any Error>) {
        guard case .success(let files) = result else { return }
        files.forEach { importAndSelect(from: $0) }
    }

    @MainActor
    private func selectGame(byID id: UUID) {
        // F5: fall back to the most-recent game when the deep-linked game was
        // deleted (a widget can lag the store), instead of silently doing nothing.
        guard let match = GameRecord.resolveDeepLinkTarget(id: id, container: modelContext.container)
        else { return }
        navigationContext.selectedGameRecord = match
    }

    private func importAndSelect(from file: URL) {
        if let result = GameRecord.importGameRecord(from: file, in: modelContext) {
            insertAndSelect(result: result)
        }
    }

    private func importAndSelect(sgf: String, name: String) {
        if let result = GameRecord.importGameRecord(sgf: sgf, name: name, in: modelContext) {
            insertAndSelect(result: result)
        }
    }

    private func insertAndSelect(result: (gameRecord: GameRecord, isNew: Bool)) {
        if result.isNew {
            modelContext.insert(result.gameRecord)
        }
        navigationContext.selectedGameRecord = result.gameRecord
    }

    private func processChange(oldGameRecord: GameRecord?, newGameRecord: GameRecord?) {
        gobanState.loadGame(gameRecord: newGameRecord, previous: oldGameRecord,
                            player: player, bookLookup: bookLookup,
                            messageList: messageList, board: board, stones: stones)
    }

    private func processChange(oldWaitingForAnalysis: Bool,
                               newWaitingForAnalysis: Bool) {
        if (oldWaitingForAnalysis && !newWaitingForAnalysis) {
            if let gameRecord = navigationContext.selectedGameRecord,
               let config = gameRecord.config,
               !gobanState.shouldGenMove(config: config, player: player) {
                if gobanState.analysisStatus == .pause
                    || gobanState.isAnalysisHiddenForPowerSaving(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand) {
                    messageList.appendAndSend(command: "stop")
                } else {
                    // Reset the visit cap to unbounded before re-arming continuous
                    // analysis, so a prior human-profile gen-move's maxVisits=400
                    // does not leak in and cap analysis.
                    messageList.appendAndSend(commands: [
                        "kata-set-param maxVisits \(GtpCommandBuilder.unboundedMaxVisits)",
                        GtpCommandBuilder.analyzeCommand(interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves)])
                }

                if gobanState.isAutoPlaying && !analysis.info.isEmpty && stones.isReady {
                    gobanState.maybeUpdateAnalysisData(
                        gameRecord: gameRecord,
                        analysis: analysis,
                        board: board,
                        stones: stones
                    )

                    // forward move
                    let sgfHelper = SgfHelper(sgf: gameRecord.sgf)

                    if let nextMove = sgfHelper.getMove(at: gameRecord.currentIndex),
                       let move = board.locationToMove(location: nextMove.location) {
                        let nextPlayer = nextMove.player == Player.black ? "b" : "w"

                        gobanState.play(
                            turn: nextPlayer,
                            move: String(move),
                            messageList: messageList,
                            stones: stones
                        )

                        player.toggleNextColorForPlayCommand()
                        gobanState.sendShowBoardCommand(messageList: messageList)
                        audioModel.playPlaySound(soundEffect: gobanState.soundEffect)
                        gobanState.isAutoPlayed = true
                    } else {
                        gobanState.isAutoPlaying = false
                        gobanState.isAutoPlayed = false
                    }
                }
            }
        }
    }

    private func processChange(oldBranchStateSgf: String, newBranchStateSgf: String) {
        if (oldBranchStateSgf.isActiveSgf) &&
            (!newBranchStateSgf.isActiveSgf) {
            processChange(oldGameRecord: nil, newGameRecord: navigationContext.selectedGameRecord)
        }
    }

    func syncBookState() {
        if bookLookup.justAdvanced {
            bookLookup.clearJustAdvanced()
            return
        }

        guard let gameRecord = navigationContext.selectedGameRecord,
              gameRecord.concreteConfig.isBookCompatible,
              bookLookup.isLoaded else {
            return
        }

        let sgf = gobanState.getSgf(gameRecord: gameRecord) ?? gameRecord.sgf
        let currentIndex = gobanState.getCurrentIndex(gameRecord: gameRecord) ?? gameRecord.currentIndex
        let sgfHelper = SgfHelper(sgf: sgf)
        let width = Int(board.width)
        let height = Int(board.height)

        var moves: [BoardPoint] = []
        for i in 0..<currentIndex {
            if let move = sgfHelper.getMove(at: i) {
                moves.append(BoardPoint(location: move.location, width: width, height: height))
            }
        }

        withAnimation {
            bookLookup.syncFromMoves(moves, boardWidth: width, boardHeight: height)
        }
    }
}

/// Two-way binding between the app-wide preference `@AppStorage` keys and the
/// shared `GobanState`. On appear, the persisted values seed `GobanState`; on
/// each `GobanState` change (driven by GlobalSettingsView), the value is written
/// back to UserDefaults. Extracted into its own modifier so the long sync chain
/// stays out of `GameSplitView`'s body (avoids a SwiftUI type-checker timeout).
private struct GlobalPreferenceSync: ViewModifier {
    let gobanState: GobanState

    @AppStorage(GlobalSettingsKeys.soundEffect) private var soundEffect = false
    @AppStorage(GlobalSettingsKeys.hapticFeedback) private var hapticFeedback = false
    @AppStorage(GlobalSettingsKeys.showVisitsPerSecond) private var showVisitsPerSecond = false
    @AppStorage(GlobalSettingsKeys.showCoordinate) private var showCoordinate = Config.defaultShowCoordinate
    @AppStorage(GlobalSettingsKeys.showPass) private var showPass = Config.defaultShowPass
    @AppStorage(GlobalSettingsKeys.verticalFlip) private var verticalFlip = Config.compatibleVerticalFlip
    @AppStorage(GlobalSettingsKeys.showOwnership) private var showOwnership = Config.defaultShowOwnership
    @AppStorage(GlobalSettingsKeys.showWinrateBar) private var showWinrateBar = Config.defaultShowWinrateBar
    @AppStorage(GlobalSettingsKeys.showCharts) private var showCharts = Config.defaultShowCharts
    @AppStorage(GlobalSettingsKeys.showComments) private var showComments = Config.defaultShowComments
    @AppStorage(GlobalSettingsKeys.stoneStyle) private var stoneStyle = Config.defaultStoneStyle
    @AppStorage(GlobalSettingsKeys.moveNumberStyle) private var moveNumberStyle = Config.defaultMoveNumberStyle
    @AppStorage(GlobalSettingsKeys.analysisStyle) private var analysisStyle = Config.defaultAnalysisStyle
    @AppStorage(GlobalSettingsKeys.analysisInformation) private var analysisInformation = Config.defaultAnalysisInformation

    func body(content: Content) -> some View {
        content
            .onAppear {
                gobanState.soundEffect = soundEffect
                gobanState.hapticFeedback = hapticFeedback
                gobanState.showVisitsPerSecond = showVisitsPerSecond
                gobanState.showCoordinate = showCoordinate
                gobanState.showPass = showPass
                gobanState.verticalFlip = verticalFlip
                gobanState.showOwnership = showOwnership
                gobanState.showWinrateBar = showWinrateBar
                gobanState.showCharts = showCharts
                gobanState.showComments = showComments
                gobanState.stoneStyle = stoneStyle
                gobanState.moveNumberStyle = moveNumberStyle
                gobanState.analysisStyle = analysisStyle
                gobanState.analysisInformation = analysisInformation
            }
            .onChange(of: gobanState.soundEffect) { _, newValue in soundEffect = newValue }
            .onChange(of: gobanState.hapticFeedback) { _, newValue in hapticFeedback = newValue }
            .onChange(of: gobanState.showVisitsPerSecond) { _, newValue in showVisitsPerSecond = newValue }
            .onChange(of: gobanState.showCoordinate) { _, newValue in showCoordinate = newValue }
            .onChange(of: gobanState.showPass) { _, newValue in showPass = newValue }
            .onChange(of: gobanState.verticalFlip) { _, newValue in verticalFlip = newValue }
            .onChange(of: gobanState.showOwnership) { _, newValue in showOwnership = newValue }
            .onChange(of: gobanState.showWinrateBar) { _, newValue in showWinrateBar = newValue }
            .onChange(of: gobanState.showCharts) { _, newValue in showCharts = newValue }
            .onChange(of: gobanState.showComments) { _, newValue in showComments = newValue }
            .onChange(of: gobanState.stoneStyle) { _, newValue in stoneStyle = newValue }
            .onChange(of: gobanState.moveNumberStyle) { _, newValue in moveNumberStyle = newValue }
            .onChange(of: gobanState.analysisStyle) { _, newValue in analysisStyle = newValue }
            .onChange(of: gobanState.analysisInformation) { _, newValue in analysisInformation = newValue }
    }
}
