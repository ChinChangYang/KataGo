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

    var gameRecord: GameRecord

    var config: Config {
        return gameRecord.concreteConfig
    }

    var isFunctional: Bool {
        !gobanState.shouldGenMove(config: config, player: player)
        && !gobanState.isAutoPlaying
        && (gobanState.showBoardCount == 0)
    }

    var spacing: CGFloat {
#if os(visionOS)
        return 20
#else
        return 1
#endif
    }

    var foregroundStyle: HierarchicalShapeStyle {
        isFunctional ? .primary : .secondary
    }

    func createButton(action: @escaping @MainActor () -> Void,
                      label: String,
                      systemImage: String) -> some View {
        Group {
#if os(visionOS)
            // visionOS doesn't support glass button style
            Button(action: action) {
                Label(label, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(foregroundStyle)
            }
#else
            Button(action: action) {
                Label(label, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(foregroundStyle)
            }
            .buttonStyle(.glass)
#endif
        }
    }

    func createButton(action: @escaping @MainActor () -> Void,
                      label: String,
                      image: some View) -> some View {
        Group {
#if os(visionOS)
            // visionOS doesn't support glass button style
            Button(action: action) {
                Label { Text(label) } icon: { image }
                    .labelStyle(.iconOnly)
            }
#else
            Button(action: action) {
                Label { Text(label) } icon: { image }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
#endif
        }
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

        if isFunctional {
            gobanState.undoIndex(gameRecord: gameRecord)
            gobanState.undo(messageList: messageList, stones: stones)
            player.toggleNextColorForPlayCommand()
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
