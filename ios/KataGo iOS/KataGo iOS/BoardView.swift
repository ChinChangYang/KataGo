//
//  BoardView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/12.
//

import SwiftUI
import KataGoInterface
import AVKit

struct BoardView: View {
    @State var audioModel = AudioModel()
    @Environment(BoardSize.self) var board
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    @Environment(Stones.self) var stones
    var config: Config

    var body: some View {
        GeometryReader { geometry in
            let dimensions = Dimensions(size: geometry.size,
                                        width: board.width,
                                        height: board.height,
                                        showCoordinate: config.showCoordinate)
            ZStack {
                BoardLineView(dimensions: dimensions)

                StoneView(dimensions: dimensions,
                          isClassicStoneStyle: config.isClassicStoneStyle)

                AnalysisView(config: config, dimensions: dimensions)
                MoveNumberView(dimensions: dimensions)
                WinrateBarView(dimensions: dimensions)
            }
            .onTapGesture() { location in
                if let coordinate = locationToCoordinate(location: location, dimensions: dimensions),
                   let point = coordinate.point,
                   let move = coordinate.move,
                   let turn = player.nextColorSymbolForPlayCommand,
                   !stones.blackPoints.contains(point) && !stones.whitePoints.contains(point) {
                    KataGoHelper.sendCommand("play \(turn) \(move)")
                    player.toggleNextColorForPlayCommand()
                    KataGoHelper.sendCommand("showboard")
                    KataGoHelper.sendCommand("printsgf")
                    audioModel.playPlaySound(soundEffect: config.soundEffect)
                }
            }
        }
        .onAppear() {
            player.nextColorForPlayCommand = .unknown
            KataGoHelper.sendCommand("showboard")
        }
        .onChange(of: config.maxAnalysisMoves) { _, _ in
            gobanState.maybeRequestAnalysis(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand)
        }
        .onChange(of: player.nextColorForPlayCommand) { oldValue, newValue in
            if oldValue != newValue {
                gobanState.maybeSendAsymmetricHumanAnalysisCommands(config: config, nextColorForPlayCommand: newValue)
                gobanState.maybeRequestAnalysis(config: config, nextColorForPlayCommand: newValue)
                gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: newValue)
            }
        }
        .onChange(of: stones.blackStonesCaptured) { oldValue, newValue in
            if oldValue < newValue {
                audioModel.playCaptureSound(soundEffect: config.soundEffect)
            }
        }
        .onChange(of: stones.whiteStonesCaptured) { oldValue, newValue in
            if oldValue < newValue {
                audioModel.playCaptureSound(soundEffect: config.soundEffect)
            }
        }
        .onDisappear() {
            KataGoHelper.sendCommand("stop")
        }
    }

    func locationToCoordinate(location: CGPoint, dimensions: Dimensions) -> Coordinate? {
        let calculateCoordinate = { (point: CGFloat, margin: CGFloat, length: CGFloat) -> Int in
            return Int(round((point - margin) / length))
        }

        let y = calculateCoordinate(location.y, dimensions.boardLineStartY, dimensions.squareLength) + 1
        let x = calculateCoordinate(location.x, dimensions.boardLineStartX, dimensions.squareLength)

        return Coordinate(x: x, y: y, width: Int(board.width), height: Int(board.height))
    }
}

