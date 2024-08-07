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
    @Binding var isBoardSizeChanged: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(NavigationContext.self) var navigationContext
    @Environment(GobanTab.self) var gobanTab

    var body: some View {
        HStack {
            Button {
                withAnimation {
                    gobanTab.isCommandPresented.toggle()
                    gobanTab.isConfigPresented = false
                    gobanTab.isAddPresented = false
                }
            } label: {
                if gobanTab.isCommandPresented {
                    Image(systemName: "doc.plaintext.fill")
                } else {
                    Image(systemName: "doc.plaintext")
                }
            }

            Button {
                withAnimation {
                    gobanTab.isCommandPresented = false
                    gobanTab.isConfigPresented.toggle()
                    gobanTab.isAddPresented = false
                }
            } label: {
                if gobanTab.isConfigPresented {
                    Image(systemName: "gearshape.fill")
                } else {
                    Image(systemName: "gearshape")
                }
            }
            .onChange(of: gobanTab.isConfigPresented) { _, isConfigPresentedNow in
                if !isConfigPresentedNow && (isBoardSizeChanged) {
                    KataGoHelper.sendCommand(gameRecord.config.getKataBoardSizeCommand())
                    KataGoHelper.sendCommand("printsgf")
                    isBoardSizeChanged = false
                }
            }

            Button {
                withAnimation {
                    gobanTab.isCommandPresented = false
                    gobanTab.isConfigPresented = false
                    gobanTab.isAddPresented.toggle()
                }
            } label: {
                if gobanTab.isAddPresented {
                    Label("New game", systemImage: "plus.square.fill")
                        .help("New game")
                } else {
                    Label("New game", systemImage: "plus.square")
                        .help("New game")
                }
            }
        }
    }
}

struct GobanItems: View {
    var gameRecord: GameRecord
    @State private var isBoardSizeChanged = false
    @Environment(GobanTab.self) var gobanTab

    var body: some View {
        Group {
            if gobanTab.isCommandPresented {
                CommandView(config: gameRecord.config)
            } else if gobanTab.isConfigPresented {
                ConfigView(config: gameRecord.config, isBoardSizeChanged: $isBoardSizeChanged)
            } else if gobanTab.isAddPresented {
                AddGameView(gameRecord: gameRecord)
            } else {
                BoardView(config: gameRecord.config)
            }
        }
        .toolbar {
            ToolbarItem {
                TopToolbarView(gameRecord: gameRecord,
                               isBoardSizeChanged: $isBoardSizeChanged)
            }

            ToolbarItem(placement: .status) {
                StatusToolbarItems(gameRecord: gameRecord)
            }
        }
    }
}

struct UnselectedGameView: View {
    @Binding var isInitialized: Bool
    @Environment(GobanTab.self) var gobanTab

    var body: some View {
        if gobanTab.isAddPresented {
            AddGameView(gameRecord: nil)
        } else {
            ContentUnavailableView("Select a game", systemImage: "sidebar.left")
        }
    }
}

@Observable
class GobanTab {
    var isCommandPresented = false
    var isConfigPresented = false
    var isAddPresented = false
}

struct GobanView: View {
    @Binding var isInitialized: Bool
    @Binding var isEditorPresented: Bool
    @State private var gobanTab = GobanTab()
    @Environment(NavigationContext.self) var navigationContext

    var body: some View {
        Group {
            if isInitialized,
               let gameRecord = navigationContext.selectedGameRecord {
                GobanItems(gameRecord: gameRecord)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text(gameRecord.name)
                                .onTapGesture {
                                    isEditorPresented = true
                                }
                        }
                    }
            } else {
                UnselectedGameView(isInitialized: $isInitialized)
                    .toolbar {
                        if isInitialized {
                            ToolbarItem {
                                Button {
                                    withAnimation {
                                        gobanTab.isCommandPresented = false
                                        gobanTab.isConfigPresented = false
                                        gobanTab.isAddPresented.toggle()
                                    }
                                } label: {
                                    if gobanTab.isAddPresented {
                                        Label("New game", systemImage: "plus.square.fill")
                                            .help("New game")
                                    } else {
                                        Label("New game", systemImage: "plus.square")
                                            .help("New game")
                                    }
                                }
                            }
                        }
                    }
            }
        }
        .environment(gobanTab)
    }
}
