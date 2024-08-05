//
//  GobanView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/2.
//

import SwiftUI
import SwiftData
import KataGoInterface

struct BoardView: View {
    @EnvironmentObject var board: ObservableBoard
    @EnvironmentObject var player: PlayerObject
    @EnvironmentObject var gobanState: GobanState
    var config: Config

    var body: some View {
        GeometryReader { geometry in
            let dimensions = Dimensions(geometry: geometry,
                                        width: board.width,
                                        height: board.height,
                                        showCoordinate: config.showCoordinate)
            ZStack {
                BoardLineView(dimensions: dimensions)

                StoneView(dimensions: dimensions,
                          isClassicStoneStyle: config.isClassicStoneStyle())

                if (gobanState.analysisStatus != .clear) && (isAnalysisForCurrentPlayer()) {
                    AnalysisView(config: config, dimensions: dimensions)
                }

                MoveNumberView(dimensions: dimensions)
                WinrateBarView(dimensions: dimensions)
            }
            .onTapGesture() { location in
                if let move = locationToMove(location: location, dimensions: dimensions) {
                    KataGoHelper.sendCommand("play \(player.nextColorSymbolForPlayCommand) \(move)")
                }

                KataGoHelper.sendCommand("showboard")
                KataGoHelper.sendCommand("printsgf")

                player.toggleNextColorForPlayCommand()

                if (gobanState.analysisStatus != .clear) && isAnalysisForCurrentPlayer() {
                    gobanState.requestAnalysis(config: config)
                } else {
                    gobanState.requestingClearAnalysis = true
                }
            }
        }
        .onAppear() {
            KataGoHelper.sendCommand(config.getKataPlayoutDoublingAdvantageCommand())
            KataGoHelper.sendCommand(config.getKataAnalysisWideRootNoiseCommand())
            KataGoHelper.sendCommand("kata-set-param humanSLProfile \(config.humanSLProfile)")
            KataGoHelper.sendCommand("kata-set-param humanSLRootExploreProbWeightful \(config.humanSLRootExploreProbWeightful)")
            KataGoHelper.sendCommand("showboard")
            if (gobanState.analysisStatus == .run) {
                gobanState.requestAnalysis(config: config)
            }
        }
        .onDisappear() {
            KataGoHelper.sendCommand("stop")
        }
    }

    func isAnalysisForCurrentPlayer() -> Bool {
        return (config.isAnalysisForBlack() && player.nextColorForPlayCommand == .black) ||
        (config.isAnalysisForWhite() && player.nextColorForPlayCommand == .white) ||
        (!config.isAnalysisForBlack() && !config.isAnalysisForWhite())
    }

    func locationToMove(location: CGPoint, dimensions: Dimensions) -> String? {
        let calculateCoordinate = { (point: CGFloat, margin: CGFloat, length: CGFloat) -> Int in
            return Int(round((point - margin) / length))
        }

        let y = calculateCoordinate(location.y, dimensions.boardLineStartY, dimensions.squareLength) + 1
        let x = calculateCoordinate(location.x, dimensions.boardLineStartX, dimensions.squareLength)

        guard (1...Int(board.height)).contains(y), (0..<Int(board.width)).contains(x) else { return nil }

        return Coordinate.xLabelMap[x].map { "\($0)\(y)" }
    }
}

struct TopToolbarView: View {
    var gameRecord: GameRecord
    @Binding var isCommandPresented: Bool
    @Binding var isConfigPresented: Bool
    @Binding var isBoardSizeChanged: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext

    var body: some View {
        HStack {
            Button(action: {
                withAnimation {
                    isCommandPresented.toggle()
                    isConfigPresented = false
                }
            }) {
                if isCommandPresented {
                    Image(systemName: "doc.plaintext.fill")
                } else {
                    Image(systemName: "doc.plaintext")
                }
            }

            Button(action: {
                withAnimation {
                    isCommandPresented = false
                    isConfigPresented.toggle()
                }
            }) {
                if isConfigPresented {
                    Image(systemName: "gearshape.fill")
                } else {
                    Image(systemName: "gearshape")
                }
            }
            .onChange(of: isConfigPresented) { _, isConfigPresentedNow in
                if !isConfigPresentedNow && (isBoardSizeChanged) {
                    KataGoHelper.sendCommand(gameRecord.config.getKataBoardSizeCommand())
                    KataGoHelper.sendCommand("printsgf")
                    isBoardSizeChanged = false
                }
            }

            Button {
                let newGameRecord = GameRecord(gameRecord: gameRecord)
                modelContext.insert(newGameRecord)
                navigationContext.selectedGameRecord = newGameRecord
            } label: {
                Label("New game", systemImage: "plus.square")
                    .help("New game")
            }
        }
    }
}

struct GobanItems: View {
    var gameRecord: GameRecord
    @State private var isCommandPresented = false
    @State private var isConfigPresented = false
    @State private var isBoardSizeChanged = false
    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.verticalSizeClass) var vSizeClass

    var body: some View {
        Group {
            if isCommandPresented {
                CommandView(config: gameRecord.config)
            } else if isConfigPresented {
                ConfigView(config: gameRecord.config, isBoardSizeChanged: $isBoardSizeChanged)
            } else {
                if hSizeClass == .compact && vSizeClass == .regular {
                    VStack {
                        BoardView(config: gameRecord.config)
                        HStack {
                            ToolbarItems(gameRecord: gameRecord)
                        }
                        .padding()
                    }
                } else {
                    HStack {
                        BoardView(config: gameRecord.config)
                        VStack {
                            ToolbarItems(gameRecord: gameRecord)
                        }
                        .padding()
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                TopToolbarView(gameRecord: gameRecord,
                               isCommandPresented: $isCommandPresented,
                               isConfigPresented: $isConfigPresented,
                               isBoardSizeChanged: $isBoardSizeChanged)
            }
        }
    }
}

struct GobanView: View {
    @Binding var isInitialized: Bool
    @Binding var isEditorPresented: Bool
    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.verticalSizeClass) var vSizeClass
    @Environment(NavigationContext.self) var navigationContext
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if isInitialized,
           let gameRecord = navigationContext.selectedGameRecord {
            Text(gameRecord.name)
                .font(.title)
                .bold()
                .onTapGesture {
                    isEditorPresented = true
                }

            if hSizeClass == .compact && vSizeClass == .regular {
                VStack {
                    GobanItems(gameRecord: gameRecord)
                }
            } else {
                HStack {
                    GobanItems(gameRecord: gameRecord)
                }
            }
        } else {
            ContentUnavailableView("Select a game", systemImage: "sidebar.left")
                .toolbar {
                    if isInitialized {
                        ToolbarItem {
                            Button {
                                let newGameRecord = GameRecord()
                                modelContext.insert(newGameRecord)
                                navigationContext.selectedGameRecord = newGameRecord
                            } label: {
                                Label("New game", systemImage: "plus.square")
                                    .help("New game")
                            }
                        }
                    }
                }
        }
    }
}
