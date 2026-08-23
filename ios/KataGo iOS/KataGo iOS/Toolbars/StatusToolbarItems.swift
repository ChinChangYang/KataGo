//
//  ToolbarView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/10/1.
//

import SwiftUI
import KataGoUICore
import AVKit

struct StatusToolbarItems: View {
    @State var audioModel = AudioModel()
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    @Environment(BoardSize.self) var board
    @Environment(MessageList.self) var messageList
    @Environment(Analysis.self) var analysis
    @Environment(Stones.self) var stones
    @Environment(BookLookup.self) var bookLookup
    /// Optional: a host that injects no status (macOS) reads as ready, which is
    /// the pre-existing behaviour verbatim.
    @Environment(EngineStatus.self) var engineStatus: EngineStatus?

    var gameRecord: GameRecord

    var config: Config {
        return gameRecord.concreteConfig
    }

    /// Whether the navigation buttons act.
    ///
    /// `showBoardCount == 0` — "the engine has acknowledged the position" —
    /// used to be part of this. It was reasonable when the board could not be
    /// drawn until the engine answered; now the board is record-owned and the
    /// cursor moves without asking anyone, so a pending ack must not freeze
    /// Forward/Backward (a launching engine acks nothing at all, which would
    /// grey the row out for the whole launch). What remains are the two states
    /// that would corrupt the record if the cursor moved under them.
    static func isFunctional(gobanState: GobanState, config: Config, player: Turn) -> Bool {
        !gobanState.shouldGenMove(config: config, player: player)
        && !gobanState.isAutoPlaying
    }

    /// The analysis toggle needs an engine that can answer. Held counts as
    /// "cannot": the engine is up but refuses this board's size, so there is
    /// nothing for the toggle to start.
    static func isAnalysisToggleEnabled(engineStatus: EngineStatus?) -> Bool {
        engineStatus?.isReady ?? true
    }

    var isFunctional: Bool {
        Self.isFunctional(gobanState: gobanState, config: config, player: player)
    }

    var spacing: CGFloat {
        1
    }

    var foregroundStyle: HierarchicalShapeStyle {
        isFunctional ? .primary : .secondary
    }

    func createButton(action: @escaping @MainActor () -> Void,
                      label: String,
                      systemImage: String) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .foregroundStyle(foregroundStyle)
        }
        .buttonStyle(.glass)
    }

    func createButton(action: @escaping @MainActor () -> Void,
                      label: String,
                      image: some View) -> some View {
        Button(action: action) {
            Label { Text(label) } icon: { image }
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
    }

    var body: some View {
        HStack(spacing: spacing) {
            createButton(
                action: backwardEndAction,
                label: "Backward to End",
                systemImage: "backward.end"
            )

            createButton(
                action: backwardAction,
                label: "Backward",
                systemImage: "backward"
            )

            createButton(
                action: backwardFrameAction,
                label: "Backward Frame",
                systemImage: "backward.frame"
            )

            createButton(
                action: sparkleAction,
                label: "Toggle Analysis",
                image:
                    Image((gobanState.analysisStatus == .clear) ? "custom.sparkle.slash" : "custom.sparkle")
                    .symbolEffect(.variableColor.iterative.reversing, isActive: gobanState.analysisStatus == .run)
            )
            .foregroundStyle((gobanState.analysisStatus == .clear) ? .red : .primary)
            .contentTransition(.symbolEffect(.replace))
            // Navigation never waits for the engine; analysis has nothing to
            // do without one. Disabled rather than silently inert, so the
            // button says what the status line already says.
            .disabled(!Self.isAnalysisToggleEnabled(engineStatus: engineStatus))

            createButton(
                action: eyeAction,
                label: "Toggle Visibility",
                image:
                    Image(systemName: eyeIconName)
            )
            .foregroundStyle(eyeForegroundStyle)
            .contentTransition(.symbolEffect(.replace))

            createButton(
                action: forwardFrameAction,
                label: "Forward Frame",
                systemImage: "forward.frame"
            )

            createButton(
                action: forwardAction,
                label: "Forward",
                systemImage: "forward"
            )

            createButton(
                action: forwardEndAction,
                label: "Forward to End",
                systemImage: "forward.end"
            )
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    func backwardEndAction() {
        maybeBackwardAction(limit: nil)
    }

    func backwardAction() {
        maybeBackwardAction(limit: 10)
    }

    private func maybeBackwardAction(limit: Int?) {
        gobanState.maybeUpdateAnalysisData(
            gameRecord: gameRecord,
            analysis: analysis,
            board: board,
            stones: stones,
            all: false
        )

        if isFunctional {
            gobanState.backwardMoves(
                limit: limit,
                gameRecord: gameRecord,
                messageList: messageList,
                player: player,
                stones: stones
            )
        }
    }

    func backwardFrameAction() {
        gobanState.maybeUpdateAnalysisData(
            gameRecord: gameRecord,
            analysis: analysis,
            board: board,
            stones: stones,
            all: false
        )

        // canStepBackward gates the branch floor: this path sends the engine
        // `undo` itself, and at the divergence the engine still holds pre-branch
        // moves an ungated undo would desync. (Off-branch it also stops the
        // futile undo the engine already refuses at mainline index 0.)
        if isFunctional, gobanState.canStepBackward(gameRecord: gameRecord) {
            // A move the replay refused was never fed, so there is nothing to
            // take back — read that BEFORE the cursor moves off the index.
            let fed = gobanState.isStepBackwardFedToEngine(gameRecord: gameRecord)
            gobanState.undoIndex(gameRecord: gameRecord)
            if fed {
                gobanState.undo(messageList: messageList, stones: stones)
                player.toggleNextColorForPlayCommand()
            }
            gobanState.sendShowBoardCommand(messageList: messageList)
        }
    }

    func startAnalysisAction() {
        gobanState.analysisStatus = .run

        // Measure visits/s from this enable point so a prior pause doesn't inflate
        // the elapsed-time denominator and drag the displayed rate down.
        analysis.resetVisitsPerSecondSession()

        gobanState.maybeRequestAnalysis(
            config: config,
            nextColorForPlayCommand: player.nextColorForPlayCommand,
            messageList: messageList
        )
    }

    func pauseAnalysisAction() {
        gobanState.maybePauseAnalysis()
    }

    func stopAction() {
        withAnimation {
            gobanState.analysisStatus = .clear
        }
    }

    func sparkleAction() {
        if gobanState.analysisStatus == .pause {
            stopAction()
        } else if gobanState.analysisStatus == .run {
            pauseAnalysisAction()
        } else {
            startAnalysisAction()
        }
    }

    var eyeIconName: String {
        switch gobanState.eyeStatus {
        case .opened: "eye"
        case .book: "book"
        case .closed: "eye.slash"
        }
    }

    var eyeForegroundStyle: Color {
        switch gobanState.eyeStatus {
        case .opened: .primary
        case .book: .primary
        case .closed: .red
        }
    }

    func eyeAction() {
        withAnimation {
            switch gobanState.eyeStatus {
            case .opened:
                if config.isBookEligible && bookLookup.isAvailable(forBoardSize: config.boardWidth) {
                    // Ensure the (downloaded) book is loading; the overlay shows
                    // once it's in-book. Already-loaded books are a no-op.
                    bookLookup.loadIfNeeded(boardSize: config.boardWidth)
                    gobanState.eyeStatus = .book
                } else {
                    gobanState.eyeStatus = .closed
                }
            case .book:
                gobanState.eyeStatus = .closed
            case .closed:
                gobanState.eyeStatus = .opened
            }
        }
    }

    func forwardFrameAction() {
        maybeForwardMoves(limit: 1)
    }

    func forwardAction() {
        maybeForwardMoves(limit: 10)
    }

    func forwardEndAction() {
        maybeForwardMoves(limit: nil)
    }

    private func maybeForwardMoves(limit: Int?) {
        gobanState.maybeUpdateAnalysisData(
            gameRecord: gameRecord,
            analysis: analysis,
            board: board,
            stones: stones,
            all: false
        )

        if isFunctional {
            gobanState.forwardMoves(
                limit: limit,
                gameRecord: gameRecord,
                board: board,
                messageList: messageList,
                player: player,
                audioModel: audioModel,
                stones: stones
            )
        }
    }
}


#Preview("StatusToolbarItems minimal preview") {
    struct PreviewHost: View {
        let gobanState = GobanState()
        let player = Turn()
        let board = BoardSize()
        let messageList = MessageList()
        let analysis = Analysis()
        let gameRecord = GameRecord(config: Config())
        let bookLookup = BookLookup()

        var body: some View {
            VStack(alignment: .leading) {
                Text("accessibility5:")

                StatusToolbarItems(gameRecord: gameRecord)
                    .environment(gobanState)
                    .environment(player)
                    .environment(board)
                    .environment(messageList)
                    .environment(analysis)
                    .environment(bookLookup)
                    .environment(\.dynamicTypeSize, .accessibility5)

                Text("xSmall:")

                StatusToolbarItems(gameRecord: gameRecord)
                    .environment(gobanState)
                    .environment(player)
                    .environment(board)
                    .environment(messageList)
                    .environment(analysis)
                    .environment(bookLookup)
                    .environment(\.dynamicTypeSize, .xSmall)

            }
        }
    }

    return PreviewHost()
}
