//
//  GameSplitView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/12/8.
//

import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import KataGoUICore
import GobanRecogKit
import WidgetKit

struct GameSplitView: View {
    @Binding var selectedModel: NeuralNetworkModel?
    let sgfType = UTType("ccy.KataGo-iOS.sgf")!

    @Binding var aiMove: String?
    let maxBoardLength: Int

    @State var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var isEditorPresented = false
    @State private var widgetReloadLatch = WidgetReloadLatch()
    @State var isGameListViewAppeared = false
    @State private var photoPickerItem: PhotosPickerItem?

#if os(iOS)
    /// Stashes the camera-captured JPEG across the cover→sheet transition. The
    /// `capturingBoardPhoto` observer consumes it when the flag flips false — at
    /// the START of the cover's dismissal animation, not its completion. SwiftUI
    /// tolerates presenting the sheet while the cover finishes dismissing in this
    /// direction, so no wait is needed here (only the retry direction, via the
    /// sheet's `onDismiss` chaining below, waits for the dismissal to complete).
    @State private var capturedBoardPhoto: Data?

    /// Set by the failure-state "Retake Photo" action; consumed by the
    /// photo-import sheet's `onDismiss`. The camera cover must not be presented
    /// in the same transaction that dismisses the sheet (the mirror image of the
    /// `capturedBoardPhoto` race above — the cover presentation gets dropped
    /// while the sheet is still animating out), so the retry only flags intent
    /// and the cover is presented once the sheet has actually gone away.
    @State private var reopeningCameraAfterRetry = false
#endif

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
    @Environment(DeepLinkRouter.self) private var deepLinkRouter

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
                allowedContentTypes: [sgfType, .text, .image],
                allowsMultipleSelection: true
            ) { result in
                importFiles(result: result)
            }
            .onDrop(of: [sgfType, .text], isTargeted: nil, perform: handleDrop)
            .photosPicker(
                isPresented: $topUIState.importingPhoto,
                selection: $photoPickerItem,
                matching: .images
            )
            .onChange(of: photoPickerItem) { _, newItem in
                loadPickedPhoto(newItem)
            }
            .sheet(item: $topUIState.pendingPhotoImport, onDismiss: {
#if os(iOS)
                // "Retake Photo" flagged intent to reopen the camera; present
                // the cover only now that the sheet has finished dismissing
                // (presenting it in the same transaction gets dropped — the
                // mirror image of the cover→sheet race handled below).
                if reopeningCameraAfterRetry {
                    reopeningCameraAfterRetry = false
                    topUIState.capturingBoardPhoto = true
                }
#endif
            }) { pending in
                photoImportSheet(for: pending)
            }
#if os(iOS)
            .fullScreenCover(isPresented: $topUIState.capturingBoardPhoto) {
                BoardCameraView(
                    onCapture: { data in
                        // Stash and dismiss the cover; the photo-import funnel is
                        // driven from the `capturingBoardPhoto` observer when the
                        // flag flips (at the start of the cover's dismissal —
                        // SwiftUI tolerates presenting the sheet while the cover
                        // finishes dismissing in this direction).
                        capturedBoardPhoto = data
                        topUIState.capturingBoardPhoto = false
                    },
                    onCancel: {
                        topUIState.capturingBoardPhoto = false
                    }
                )
                .ignoresSafeArea()
            }
            .onChange(of: topUIState.capturingBoardPhoto) { _, isCapturing in
                guard !isCapturing else {
                    // Camera opening: clear any stash a prior session's late
                    // capture may have leaked, so a stale photo can't be consumed
                    // by this session's cancel edge.
                    capturedBoardPhoto = nil
                    return
                }
                guard let data = capturedBoardPhoto else { return }
                capturedBoardPhoto = nil
                presentPhotoImport(imageData: data,
                                   name: photoImportName(),
                                   source: .camera)
            }
#endif
    }

    /// Hosts the shared `PhotoImportSheet` for a picked board image. On import
    /// the synthesized SGF is routed through the same seam the file/SGF import
    /// uses, so de-dup, selection, and widget reload all come for free.
    private func photoImportSheet(for pending: PendingPhotoImport) -> some View {
        // A failed camera capture offers "Retake Photo", reopening the camera
        // cover. The retry only dismisses the sheet and flags intent; the cover
        // is presented from the sheet's `onDismiss` (presenting it while the
        // sheet is still dismissing gets dropped). File/library imports keep
        // today's behavior: no retry button — the user re-picks from the menu.
        let onRetry: (() -> Void)?
        let retryButtonTitle: String
        switch pending.source {
        case .camera:
#if os(iOS)
            onRetry = {
                reopeningCameraAfterRetry = true
                topUIState.pendingPhotoImport = nil
            }
#else
            // No camera entry point exists off-iOS, so a `.camera` pending
            // import cannot occur; offer no retry if one ever does.
            onRetry = nil
#endif
            retryButtonTitle = "Retake Photo"
        case .fileOrLibrary:
            onRetry = nil
            retryButtonTitle = "Try Another Image"
        }
        return NavigationStack {
            PhotoImportSheet(
                imageData: pending.imageData,
                suggestedName: pending.suggestedName,
                onImport: { sgf, name in
                    importAndSelect(sgf: sgf, name: name)
                    topUIState.pendingPhotoImport = nil
                },
                onCancel: {
                    topUIState.pendingPhotoImport = nil
                },
                onRetry: onRetry,
                retryButtonTitle: retryButtonTitle
            )
        }
        // The grid phase's photo is sized by its container, and on iPad the
        // default form sheet (~540x620) is that limit — the layout inside is
        // already maximal. No effect in compact width, where the sheet is
        // full height already.
        .presentationSizing(.page)
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
                    maxBoardLength: maxBoardLength
                )
            }
        } detail: {
            detailView
        }
        .modifier(GlobalPreferenceSync(gobanState: gobanState))
        .onChange(of: navigationContext.selectedGameRecord) { oldGameRecord, newGameRecord in
            createThumbnail(for: oldGameRecord)
            // Reloading here raced ahead of the engine: the switched game's
            // sgf/stones land with the showboard reply, so arm the latch and
            // reload from `processStonesReadyChange` instead. Deselection has
            // nothing to await — fire immediately (the historical behavior).
            switch widgetReloadLatch.gameSwitched(hasNewGame: newGameRecord != nil) {
            case .fireNow:
                try? modelContext.save()
                WidgetCenter.shared.reloadAllTimelines()
            case .armed:
                break
            }
            processChange(oldGameRecord: oldGameRecord, newGameRecord: newGameRecord)
        }
        .onChange(of: gobanState.waitingForAnalysis) { oldWaitingForAnalysis, newWaitingForAnalysis in
            processChange(oldWaitingForAnalysis: oldWaitingForAnalysis,
                          newWaitingForAnalysis: newWaitingForAnalysis)
        }
        .onOpenURL { url in
            // `open-game` deep links AND externally-opened images are captured at
            // the root (`DeepLinkRouter`) so they survive a cold launch; the id is
            // applied via the `pendingGameID` `.onChange` below and the image via
            // the `pendingImageImport` drain. `import-sgf` links come from the
            // Messages extension, whose game rides a spool file in the App Group
            // (the URL only names it). Everything else is an SGF file-import URL.
            // Images are excluded here so a WARM open does not present the photo
            // sheet twice (the root already owns them).
            if let fileName = GameDeepLink.importSgfFileName(from: url) {
                drainMessagesHandoffSpool(preferring: fileName)
            } else if GameDeepLink.gameID(from: url) == nil, !FileOpenClassifier.isImage(url) {
                importAndSelect(from: url)
            }
        }
        .task {
            // A cold launch can drop the Messages extension's `import-sgf`
            // URL (this view is not mounted while the loading screens run),
            // but the spool FILE survives — drain whatever is queued.
            drainMessagesHandoffSpool(preferring: nil)
        }
        .onChange(of: deepLinkRouter.pendingGameID, initial: true) { _, _ in
            // Warm app: a deep link arrived after the board was already shown
            // (`initializationTask` won't re-run), so apply it here.
            // `initial: true` also drains an id captured BEFORE this view
            // mounted — a cold-launch URL delivered after `initializationTask`
            // resolved the selection would otherwise strand here forever (the
            // stranded value even swallows later same-game taps, since an
            // equal write fires no change).
            applyPendingDeepLink()
        }
        .onChange(of: deepLinkRouter.pendingImageImport, initial: true) { _, _ in
            // A board image opened WITH the app is latched at the root (its bytes
            // read at receipt). Present the existing photo-recognition sheet here.
            // `initial: true` also drains an image captured BEFORE this view
            // mounted — a cold-launch open delivered while the loading / model
            // picker screens were up would otherwise strand forever, mirroring
            // the `pendingGameID` drain above.
            applyPendingImageImport()
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

            if let advanced = gobanState.autoPlayAdvancedIndex() {
                gameRecord.currentIndex = advanced
            }

            // Sync book state after undo/forward/backward
            syncBookState()

            // A game switch armed the latch; the switched game's state is now
            // written above, so flush the App Group store and reload the
            // widgets. Per-move edges find the latch unarmed — no reload.
            if widgetReloadLatch.consumeDataLanded() {
                try? modelContext.save()
                WidgetCenter.shared.reloadAllTimelines()
            }
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
            gobanState.clearAutoPlayStep()
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

    /// Applies a pending `open-game` deep link and clears it. Single seam for
    /// the warm `.onChange` path and the mount-time (`initial: true`) drain.
    @MainActor
    private func applyPendingDeepLink() {
        guard let id = deepLinkRouter.pendingGameID else { return }
        selectGame(byID: id)
        deepLinkRouter.pendingGameID = nil
    }

    /// Applies a pending externally-opened image and clears it. Single seam for
    /// the warm `.onChange` path and the mount-time (`initial: true`) drain.
    /// Nils the latch BEFORE presenting so a re-entrant change can't double-fire.
    @MainActor
    private func applyPendingImageImport() {
        guard let pending = deepLinkRouter.pendingImageImport else { return }
        deepLinkRouter.pendingImageImport = nil
        presentPhotoImport(imageData: pending.imageData, name: pending.suggestedName)
    }

    @MainActor
    private func selectGame(byID id: UUID) {
        // F5: fall back to the most-recent game when the deep-linked game was
        // deleted (a widget can lag the store), instead of silently doing nothing.
        guard let match = GameRecord.resolveDeepLinkTarget(id: id, container: modelContext.container)
        else { return }
        navigationContext.selectedGameRecord = match
    }

    /// Imports every SGF the Messages extension spooled into the App Group
    /// (each "Analyze in KataGo Anytime" tap writes one), deletes the spool
    /// files, and selects the named file's game (or the newest). Runs at
    /// mount for cold launches and from `.onOpenURL` when warm; the existing
    /// exact-SGF dedupe makes repeated drains harmless.
    @MainActor
    private func drainMessagesHandoffSpool(preferring fileName: String?) {
        guard let directory = GameDeepLink.messagesHandoffDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let spooled = files
            .filter { $0.pathExtension == "sgf" }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return dateA < dateB
            }
        var selected: (gameRecord: GameRecord, isNew: Bool)?
        for file in spooled {
            // Two writers share this spool: the Messages extension and the
            // Safari web extension. Prefer a name derived from the SGF itself
            // (the Safari extensions write the page title into GN, so web
            // hand-offs get the game's real name); fall back to a per-source
            // literal, told apart by that same GN marker.
            if let sgf = try? String(contentsOf: file, encoding: .utf8),
               let result = GameRecord.importGameRecord(
                   sgf: sgf,
                   name: SgfGameName.derive(fromSgf: sgf)
                       ?? (SgfGameName.hasGameName(inSgf: sgf) ? "Web Game" : "iMessage Game"),
                   in: modelContext) {
                if result.isNew {
                    modelContext.insert(result.gameRecord)
                }
                if selected == nil || fileName == nil || file.lastPathComponent == fileName {
                    selected = result
                }
            }
            try? FileManager.default.removeItem(at: file)
        }
        if let selected {
            navigationContext.selectedGameRecord = selected.gameRecord
        }
    }

    private func importAndSelect(from file: URL) {
        // Branch by content type BEFORE the SGF path's UTF-8 read: image bytes
        // are binary and would fail silently when decoded as UTF-8. An image
        // routes to the photo-import preview sheet (recognition + confirm);
        // everything else keeps the existing SGF import.
        if let imageData = imageDataIfImage(at: file) {
            presentPhotoImport(imageData: imageData,
                               name: file.deletingPathExtension().lastPathComponent)
            return
        }
        if let result = GameRecord.importGameRecord(from: file, in: modelContext) {
            insertAndSelect(result: result)
            // Drop the share-sheet / Mail Inbox copy now that the SGF is imported
            // (safe no-op for an in-place Files URL — see FileOpenClassifier).
            FileOpenClassifier.cleanUpInboxFile(at: file)
        }
    }

    /// If `file` is an image, reads and returns its bytes inside a
    /// security-scoped access (mirroring `readSgfContent`); otherwise nil.
    /// Delegates to the shared `FileOpenClassifier` (same behavior; the
    /// `fileImporter` path keeps calling `importAndSelect(from:)` unchanged).
    private func imageDataIfImage(at file: URL) -> Data? {
        FileOpenClassifier.imageData(at: file)
    }

    /// Loads the Photos-picked item's bytes and presents the photo-import sheet.
    /// `PhotosPicker` needs no permission string; `loadTransferable(type:)`
    /// yields the encoded image `Data`.
    private func loadPickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task { @MainActor in
            defer { photoPickerItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            presentPhotoImport(imageData: data, name: photoImportName())
        }
    }

    private func presentPhotoImport(imageData: Data,
                                    name: String,
                                    source: PendingPhotoImport.Source = .fileOrLibrary) {
        topUIState.pendingPhotoImport = PendingPhotoImport(imageData: imageData,
                                                           suggestedName: name,
                                                           source: source)
    }

    /// Default name for a library photo (Photos items carry no filename).
    private func photoImportName() -> String {
        "Board Photo \(Date.now.formatted(date: .abbreviated, time: .shortened))"
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
        // Deep Report probes own the engine stream; while a report is active
        // this handler must not send its own "stop"/re-arm — a stray command
        // ack would desync the probe collector's FIFO. maybeCollectAnalysis is
        // already frozen during a report (so no waiting edge fires), making
        // this a defensive invariant that mirrors the macOS
        // handleAnalysisLifecycleChange guard.
        guard !gobanState.reportGenerationActive else { return }
        if (oldWaitingForAnalysis && !newWaitingForAnalysis) {
            if let gameRecord = navigationContext.selectedGameRecord,
               let config = gameRecord.config,
               !gobanState.shouldGenMove(config: config, player: player) {
                if gobanState.analysisStatus == .pause
                    || gobanState.isAnalysisHiddenForPowerSaving(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand) {
                    messageList.appendAndSend(command: "stop")
                } else {
                    // The bundle embeds the maxVisits reset (structural fix for
                    // the sticky human-profile gen-move cap).
                    messageList.appendAndSend(commands: GtpCommandBuilder.continuousAnalyzeCommands(
                        interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves))
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
                        gobanState.recordAutoPlayStep(nextIndex: gameRecord.currentIndex + 1)
                    } else {
                        gobanState.isAutoPlaying = false
                        gobanState.clearAutoPlayStep()
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
              gameRecord.concreteConfig.isBookEligible,
              bookLookup.isReady(forBoardSize: gameRecord.concreteConfig.boardWidth) else {
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
