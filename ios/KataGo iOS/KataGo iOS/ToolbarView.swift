//
//  ToolbarView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/10/1.
//

import SwiftUI
import KataGoInterface

struct StatusToolbarItems: View {
    @Environment(PlayerObject.self) var player
    @Environment(GobanState.self) var gobanState
    @Environment(ObservableBoard.self) var board
    var gameRecord: GameRecord

    var body: some View {
        HStack {
            Button(action: passAction) {
                Image(systemName: "hand.raised")
            }

            Button(action: backwardAction) {
                Image(systemName: "backward.frame")
            }

            if gobanState.analysisStatus == .pause {
                Button(action: stopAction) {
                    Image(systemName: "sparkle")
                }
            } else if gobanState.analysisStatus == .run {
                Button(action: pauseAnalysisAction) {
                    Image(systemName: "sparkle")
                        .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                }
            } else {
                Button(action: startAnalysisAction) { 
                    Image(systemName: "sparkle")
                        .foregroundColor(.red)
                }
            }

            Button(action: forwardAction) {
                Image(systemName: "forward.frame")
            }

            Button(action: clearBoardAction) {
                Image(systemName: "clear")
            }
        }
    }

    func passAction() {
        let nextColor = (player.nextColorForPlayCommand == .black) ? "b" : "w"
        let pass = "play \(nextColor) pass"
        KataGoHelper.sendCommand(pass)
        KataGoHelper.sendCommand("showboard")
        KataGoHelper.sendCommand("printsgf")
        if gobanState.analysisStatus == .run {
            let config = gameRecord.config
            gobanState.requestAnalysis(config: config)
        } else {
            gobanState.requestingClearAnalysis = true
        }
    }

    func backwardAction() {
        gameRecord.undo()
        KataGoHelper.sendCommand("undo")
        KataGoHelper.sendCommand("showboard")
        if gobanState.analysisStatus == .run {
            let config = gameRecord.config
            gobanState.requestAnalysis(config: config)
        } else {
            gobanState.analysisStatus = .clear
            gobanState.requestingClearAnalysis = true
        }
    }

    func startAnalysisAction() {
        gobanState.analysisStatus = .run
        let config = gameRecord.config
        gobanState.requestAnalysis(config: config)
    }

    func pauseAnalysisAction() {
        gobanState.analysisStatus = .pause
        KataGoHelper.sendCommand("stop")
    }

    func stopAction() {
        gobanState.analysisStatus = .clear
        KataGoHelper.sendCommand("stop")
    }

    func forwardAction() {
        let currentIndex = gameRecord.currentIndex
        let sgfHelper = SgfHelper(sgf: gameRecord.sgf)
        if let nextMove = sgfHelper.getMove(at: currentIndex) {
            if let move = locationToMove(location: nextMove.location) {
                gameRecord.currentIndex = currentIndex + 1
                let nextPlayer = nextMove.player == Player.black ? "b" : "w"
                KataGoHelper.sendCommand("play \(nextPlayer) \(move)")
                player.nextColorForPlayCommand = (nextPlayer == "b") ? .white : .black
            }
        }

        KataGoHelper.sendCommand("showboard")
        if gobanState.analysisStatus == .run {
            let config = gameRecord.config
            gobanState.requestAnalysis(config: config)
        } else {
            gobanState.analysisStatus = .clear
            gobanState.requestingClearAnalysis = true
        }
    }

    func clearBoardAction() {
        gameRecord.currentIndex = 0
        KataGoHelper.sendCommand("clear_board")
        KataGoHelper.sendCommand("showboard")
        if gobanState.analysisStatus == .run {
            let config = gameRecord.config
            gobanState.requestAnalysis(config: config)
        } else {
            gobanState.analysisStatus = .clear
            gobanState.requestingClearAnalysis = true
        }
    }

    func locationToMove(location: Location) -> String? {
        guard !location.pass else { return "pass" }
        let x = location.x
        let y = Int(board.height) - location.y

        guard (1...Int(board.height)).contains(y), (0..<Int(board.width)).contains(x) else { return nil }

        return Coordinate.xLabelMap[x].map { "\($0)\(y)" }
    }
}
