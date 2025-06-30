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
    var gameRecord: GameRecord

    var config: Config {
        return gameRecord.concreteConfig
    }

    var foregroundStyle: HierarchicalShapeStyle {
        gobanState.shouldGenMove(config: config, player: player) ? .secondary : .primary
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: backwardEndAction) {
                Image(systemName: "backward.end")
                    .foregroundStyle(foregroundStyle)
            }

            Button(action: backwardAction) {
                Image(systemName: "backward")
                    .foregroundStyle(foregroundStyle)
            }

            Button(action: backwardFrameAction) {
                Image(systemName: "backward.frame")
                    .foregroundStyle(foregroundStyle)
            }

            Button(action: sparkleAction) {
                if gobanState.analysisStatus == .clear {
                    Image("custom.sparkle.slash")
                        .foregroundColor(.red)
                } else if gobanState.analysisStatus == .run {
                    Image(systemName: "sparkles")
                        .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                } else {
                    Image(systemName: "sparkle")
                }
            }

            Button(action: eyeAction) {
                Image(systemName: (gobanState.eyeStatus == .opened) ? "eye" : "eye.slash")
                    .foregroundColor((gobanState.eyeStatus == .opened) ? .accentColor : .red)
            }

            Button(action: forwardFrameAction) {
                Image(systemName: "forward.frame")
                    .foregroundStyle(foregroundStyle)
            }

            Button(action: forwardAction) {
                Image(systemName: "forward")
                    .foregroundStyle(foregroundStyle)
            }

            Button(action: forwardEndAction) {
                Image(systemName: "forward.end")
                    .foregroundStyle(foregroundStyle)
            }
        }
    }

    func backwardEndAction() {
        maybeBackwardAction(limit: nil)
    }

    func backwardAction() {
        maybeBackwardAction(limit: 10)
    }

    private func maybeBackwardAction(limit: Int?) {
        if !gobanState.shouldGenMove(config: config, player: player) {
            backwardMoves(limit: limit)
            sendPostExecutionCommands()
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
            messageList.appendAndSend(command: "undo")
            player.toggleNextColorForPlayCommand()

            movesExecuted += 1
            if let limit = limit, movesExecuted >= limit {
                break
            }
        }
    }

    func backwardFrameAction() {
        if !gobanState.shouldGenMove(config: config, player: player) {
            if branchState.isActive {
                branchState.undo()
            } else {
                gameRecord.undo()
            }
            messageList.appendAndSend(command: "undo")
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
        if !gobanState.shouldGenMove(config: config, player: player) {
            forwardMoves(limit: limit)
        }
    }

    private func forwardMoves(limit: Int?) {
        let sgfHelper = SgfHelper(sgf: branchState.isActive ? branchState.sgf : gameRecord.sgf)
        var movesExecuted = 0

        while let nextMove = sgfHelper.getMove(at: currentIndex) {
            if let move = locationToMove(location: nextMove.location) {
                updateCurrentIndex()
                let nextPlayer = nextMove.player == Player.black ? "b" : "w"
                messageList.appendAndSend(command: "play \(nextPlayer) \(move)")
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

        sendPostExecutionCommands()
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

    private func sendPostExecutionCommands() {
        gobanState.sendShowBoardCommand(messageList: messageList)
        gobanState.maybeRequestAnalysis(config: config,
                                        nextColorForPlayCommand: player.nextColorForPlayCommand,
                                        messageList: messageList)
        gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    func locationToMove(location: Location) -> String? {
        guard !location.pass else { return "pass" }
        let x = location.x
        let y = Int(board.height) - location.y

        guard (1...Int(board.height)).contains(y), (0..<Int(board.width)).contains(x) else { return nil }

        return Coordinate.xLabelMap[x].map { "\($0)\(y)" }
    }
}
