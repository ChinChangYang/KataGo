//
//  ToolbarView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/10/1.
//

import SwiftUI
import KataGoInterface
import AVKit

struct StatusToolbarItems: View {
    @State var audioModel = AudioModel()
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    @Environment(BoardSize.self) var board
    @Environment(MessageList.self) var messageList
    @Environment(BranchState.self) var branchState
    @Environment(Analysis.self) var analysis
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
        if #available(iOS 26.0, *),
           #available(macOS 26.0, *) {
            // glass button's padding is big, so spacing is small.
            return 1
        } else {
            // plain button's padding is small, so spacing is big.
            return 20
        }
    }

    var foregroundStyle: HierarchicalShapeStyle {
        isFunctional ? .primary : .secondary
    }

    func createButton(action: @escaping @MainActor () -> Void,
                      systemImage: String) -> some View {
        Group {
#if os(visionOS)
            // visionOS doesn't support glass button style
            Button(action: action) {
                Image(systemName: systemImage)
                    .foregroundStyle(foregroundStyle)
            }
#else
            if #available(iOS 26.0, *),
               #available(macOS 26.0, *) {
                // iOS and macOS 26.0 support glass button style
                Button(action: action) {
                    Image(systemName: systemImage)
                        .foregroundStyle(foregroundStyle)
                }
                .buttonStyle(.glass)
            } else {
                // previous iOS and macOS do not support glass button style
                Button(action: action) {
                    Image(systemName: systemImage)
                        .foregroundStyle(foregroundStyle)
                }
                .buttonStyle(.plain)
            }
#endif
        }
    }

    func createButton(action: @escaping @MainActor () -> Void,
                      image: some View) -> some View {
        Group {
#if os(visionOS)
            // visionOS doesn't support glass button style
            Button(action: action) {
                image
            }
#else
            if #available(iOS 26.0, *),
               #available(macOS 26.0, *) {
                // iOS and macOS 26.0 support glass button style
                Button(action: action) {
                    image
                }
                .buttonStyle(.glass)
            } else {
                // previous iOS and macOS do not support glass button style
                Button(action: action) {
                    image
                }
                .buttonStyle(.plain)
            }
#endif
        }
    }

    var body: some View {
        HStack(spacing: spacing) {
            createButton(
                action: backwardEndAction,
                systemImage: "backward.end"
            )

            createButton(
                action: backwardAction,
                systemImage: "backward"
            )

            createButton(
                action: backwardFrameAction,
                systemImage: "backward.frame"
            )

            createButton(
                action: sparkleAction,
                image:
                    Image((gobanState.analysisStatus == .clear) ? "custom.sparkle.slash" : "custom.sparkle")
                    .symbolEffect(.variableColor.iterative.reversing, isActive: gobanState.analysisStatus == .run)
            )
            .foregroundColor((gobanState.analysisStatus == .clear) ? .red : .primary)
            .contentTransition(.symbolEffect(.replace))

            createButton(
                action: eyeAction,
                image:
                    Image(systemName: (gobanState.eyeStatus == .opened) ? "eye" : "eye.slash")
            )
            .foregroundColor((gobanState.eyeStatus == .opened) ? .primary : .red)
            .contentTransition(.symbolEffect(.replace))

            createButton(
                action: forwardFrameAction,
                systemImage: "forward.frame"
            )

            createButton(
                action: forwardAction,
                systemImage: "forward"
            )

            createButton(
                action: forwardEndAction,
                systemImage: "forward.end"
            )
        }
    }

    func backwardEndAction() {
        maybeBackwardAction(limit: nil)
    }

    func backwardAction() {
        maybeBackwardAction(limit: 10)
    }

    private func maybeBackwardAction(limit: Int?) {
        gobanState.maybeUpdateScoreLeads(gameRecord: gameRecord, analysis: analysis)
        if isFunctional {
            backwardMoves(limit: limit)
            gobanState.sendPostExecutionCommands(config: config, messageList: messageList, player: player)
        }
    }

    private func backwardMoves(limit: Int?) {
        let sgfHelper = SgfHelper(sgf: branchState.isActive ? branchState.sgf : gameRecord.sgf)
        var movesExecuted = 0

        while sgfHelper.getMove(at: (branchState.isActive ? branchState.currentIndex : gameRecord.currentIndex) - 1) != nil {
            if branchState.isActive {
                branchState.undo()
            } else {
                gameRecord.undo()
            }

            gobanState.undo(messageList: messageList)
            player.toggleNextColorForPlayCommand()

            movesExecuted += 1
            if let limit = limit, movesExecuted >= limit {
                break
            }
        }
    }

    func backwardFrameAction() {
        gobanState.maybeUpdateScoreLeads(gameRecord: gameRecord, analysis: analysis)
        if isFunctional {
            if branchState.isActive {
                branchState.undo()
            } else {
                gameRecord.undo()
            }

            gobanState.undo(messageList: messageList)
            player.toggleNextColorForPlayCommand()
            gobanState.sendShowBoardCommand(messageList: messageList)
        }
    }

    func startAnalysisAction() {
        gobanState.analysisStatus = .run
        gobanState.maybeRequestAnalysis(config: config,
                                        nextColorForPlayCommand: player.nextColorForPlayCommand,
                                        messageList: messageList)
    }

    func pauseAnalysisAction() {
        gobanState.maybePauseAnalysis()
    }

    func stopAction() {
        withAnimation {
            gobanState.analysisStatus = .clear
        }
        messageList.appendAndSend(command: "stop")
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

    func eyeAction() {
        withAnimation {
            if gobanState.eyeStatus == .closed {
                gobanState.eyeStatus = .opened
            } else {
                gobanState.eyeStatus = .closed
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
        gobanState.maybeUpdateScoreLeads(gameRecord: gameRecord, analysis: analysis)
        if isFunctional {
            forwardMoves(limit: limit)
        }
    }

    private func forwardMoves(limit: Int?) {
        let sgfHelper = SgfHelper(sgf: branchState.isActive ? branchState.sgf : gameRecord.sgf)
        var movesExecuted = 0

        while let nextMove = sgfHelper.getMove(at: currentIndex) {
            if let move = board.locationToMove(location: nextMove.location) {
                updateCurrentIndex()
                let nextPlayer = nextMove.player == Player.black ? "b" : "w"
                gobanState.play(turn: nextPlayer, move: move, messageList: messageList)
                player.toggleNextColorForPlayCommand()

                movesExecuted += 1
                if let limit = limit, movesExecuted >= limit {
                    break
                }
            }
        }

        if movesExecuted > 0 {
            audioModel.playPlaySound(soundEffect: config.soundEffect)
        }

        gobanState.sendPostExecutionCommands(config: config, messageList: messageList, player: player)
    }

    private var currentIndex: Int {
        branchState.isActive ? branchState.currentIndex : gameRecord.currentIndex
    }

    private func updateCurrentIndex() {
        if branchState.isActive {
            branchState.currentIndex += 1
        } else {
            gameRecord.currentIndex += 1
        }
    }
}


#Preview("StatusToolbarItems minimal preview") {
    struct PreviewHost: View {
        let gobanState = GobanState()
        let player = Turn()
        let board = BoardSize()
        let messageList = MessageList()
        let branchState = BranchState()
        let analysis = Analysis()
        let gameRecord = GameRecord(config: Config())

        var body: some View {
            StatusToolbarItems(gameRecord: gameRecord)
                .environment(gobanState)
                .environment(player)
                .environment(board)
                .environment(messageList)
                .environment(branchState)
                .environment(analysis)
        }
    }

    return PreviewHost()
}
