//
//  BoardView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/12.
//

import SwiftUI
import AVKit

public struct BoardView: View {
    @Environment(AudioModel.self) var audioModel
    @Environment(BoardSize.self) var board
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    @Environment(Stones.self) var stones
    @Environment(MessageList.self) var messageList
    @Environment(Analysis.self) var analysis
    @Environment(BookLookup.self) var bookLookup
    @Environment(Winrate.self) var rootWinrate
    @Environment(Score.self) var rootScore
    var gameRecord: GameRecord
    /// When false, the board is display-only: taps never place a stone (used by
    /// the tvOS review/spectate screen, which has no pointer). Phase 2's casual-
    /// play cursor re-enables it. Defaults true so every existing call site (the
    /// live iOS/visionOS/macOS board) is unchanged.
    var interactive: Bool = true
    /// When false, the on-board captured-stone counts and per-color player-name
    /// labels ("AI" / "9d" / "Human") are hidden and their fixed 20 pt strip is
    /// reclaimed for the grid. The tvOS review board hides them — that strip is
    /// unreadable at 10-foot distance and clips the board top — and surfaces the
    /// same info in its side panel instead. Defaults true so the live
    /// iOS/visionOS/macOS board is unchanged.
    var showsCapturedStones: Bool = true
    /// When false, the pass affordance row below the board is hidden, reclaiming
    /// ~1.5 squares of height for a larger grid. The tvOS review board is
    /// display-only (no move to pass), so it opts out. Defaults true.
    var showsPass: Bool = true
    @FocusState<Bool>.Binding var commentIsFocused: Bool
    @State private var confirmingOverwrite: Bool = false
    @State private var gestureLocation: CGPoint?

    public init(gameRecord: GameRecord,
                interactive: Bool = true,
                showsCapturedStones: Bool = true,
                showsPass: Bool = true,
                commentIsFocused: FocusState<Bool>.Binding) {
        self.gameRecord = gameRecord
        self.interactive = interactive
        self.showsCapturedStones = showsCapturedStones
        self.showsPass = showsPass
        self._commentIsFocused = commentIsFocused
    }

    var config: Config {
        gameRecord.concreteConfig
    }

    var shouldShowWinrateBar: Bool {
        gobanState.showWinrateBar && (gobanState.eyeStatus == .opened || (gobanState.eyeStatus == .book && bookLookup.isInBook))
    }

    public var body: some View {
        VStack {
#if os(macOS)
            Spacer(minLength: 20)
#endif
            GeometryReader { geometry in
                let effectiveShowPass = showsPass && gobanState.showPass
                let dimensions = Dimensions(size: geometry.size,
                                            width: board.width,
                                            height: board.height,
                                            showCoordinate: gobanState.showCoordinate,
                                            showPass: effectiveShowPass,
                                            isDrawingCapturedStones: showsCapturedStones)
                ZStack {
                    BoardLineView(dimensions: dimensions,
                                  showPass: effectiveShowPass,
                                  verticalFlip: gobanState.verticalFlip)

                    StoneView(
                        dimensions: dimensions,
                        isClassicStoneStyle: gobanState.isClassicStoneStyle,
                        verticalFlip: gobanState.verticalFlip,
                        isDrawingCapturedStones: showsCapturedStones,
                        speedText: speedText,
                        blackPlayerName: showsCapturedStones ? config.playerLabel(for: .black) : nil,
                        whitePlayerName: showsCapturedStones ? config.playerLabel(for: .white) : nil,
                        onToggleAI: interactive ? { toggleAI(for: $0) } : nil
                    )

                    drawNextMove(dimensions: dimensions,
                                 verticalFlip: gobanState.verticalFlip,
                                 showPass: effectiveShowPass)

                    AnalysisView(config: config, dimensions: dimensions)
                    BookAnalysisView(config: config, dimensions: dimensions)
                    MoveNumberView(dimensions: dimensions,
                                   verticalFlip: gobanState.verticalFlip,
                                   style: gobanState.moveNumberStyleChoice,
                                   moveNumbers: gobanState.getMoveNumbers(gameRecord: gameRecord))

                    if gobanState.isBranchActive {
                        // Reminder that branch stones are temporary; geometry
                        // matches BoardLineView.drawBoardBackground's wood rect.
                        Rectangle()
                            .stroke(.red, lineWidth: max(2, dimensions.squareLengthDiv16))
                            .frame(width: dimensions.gobanWidth, height: dimensions.gobanHeight)
                            .position(x: dimensions.gobanStartX + (dimensions.gobanWidth / 2),
                                      y: dimensions.gobanStartY + (dimensions.gobanHeight / 2))
                    }

                    if shouldShowWinrateBar {
                        WinrateBarView(dimensions: dimensions)
                            .transition(.opacity)
                    }
                }
#if !os(tvOS)
                // The location-providing onTapGesture variant is unavailable on
                // tvOS (no pointer). The tvOS review board is display-only
                // (interactive == false); Phase 2 play uses a focus cursor, not taps.
                .onTapGesture { location in
                    commentIsFocused = false
                    gestureLocation = location

                    if interactive && stones.isReady && !gobanState.isAutoPlaying && (gobanState.pendingMoveTurn == nil || gobanState.isPendingMoveStale),
                       let coordinate = locationToCoordinate(location: location, dimensions: dimensions),
                       let point = coordinate.point,
                       let move = coordinate.move,
                       let turn = player.nextColorSymbolForPlayCommand,
                       !stones.blackPoints.contains(point) && !stones.whitePoints.contains(point),
                       !gobanState.shouldGenMove(config: config, player: player) {

                        if gobanState.isPendingMoveStale {
                            gobanState.clearPendingMove()
                        }

                        if gobanState.isOverwriting(gameRecord: gameRecord) {
                            confirmingOverwrite = true
                        } else {
                            gobanState.sendCheckMoveCommand(
                                turn: turn,
                                move: move,
                                messageList: messageList
                            )
                        }
                    }
                }
                .confirmationDialog(
                    "Are you sure you want to overwrite this move?",
                    isPresented: $confirmingOverwrite,
                    titleVisibility: .visible
                ) {
                    Button("Overwrite", role: .destructive) {
                        if let gestureLocation,
                           let coordinate = locationToCoordinate(location: gestureLocation, dimensions: dimensions),
                           let move = coordinate.move,
                           let turn = player.nextColorSymbolForPlayCommand {
                            gobanState.sendCheckMoveCommand(
                                turn: turn,
                                move: move,
                                messageList: messageList
                            )
                        }
                    }

                    Button("Cancel", role: .cancel) {
                        confirmingOverwrite = false
                    }
                }
#endif
            }
            .onAppear {
                player.nextColorForPlayCommand = .unknown
                gobanState.sendShowBoardCommand(messageList: messageList)
            }
            .onChange(of: config.maxAnalysisMoves) { _, _ in
                gobanState.maybeRequestAnalysis(
                    config: config,
                    nextColorForPlayCommand: player.nextColorForPlayCommand,
                    messageList: messageList)
            }
            .onChange(of: player.nextColorForPlayCommand) { oldValue, newValue in
                if oldValue != newValue {
                    gobanState.maybeSendAsymmetricHumanAnalysisCommands(nextColorForPlayCommand: newValue,
                                                                        config: config,
                                                                        messageList: messageList)

                    gobanState.maybeRequestAnalysis(
                        config: config,
                        nextColorForPlayCommand: newValue,
                        messageList: messageList)

                    gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: newValue)
                }
            }
            .onChange(of: stones.blackStonesCaptured) { oldValue, newValue in
                if oldValue < newValue {
                    audioModel.playCaptureSound(soundEffect: gobanState.soundEffect)
                }
            }
            .onChange(of: stones.whiteStonesCaptured) { oldValue, newValue in
                if oldValue < newValue {
                    audioModel.playCaptureSound(soundEffect: gobanState.soundEffect)
                }
            }
            .onChange(of: gobanState.eyeStatus) {
                updateWinrateFromBook()
            }
            .onChange(of: bookLookup.currentPositionId) {
                updateWinrateFromBook()
            }
            .onDisappear {
                gobanState.maybePauseAnalysis()
            }
        }
    }

    private func updateWinrateFromBook() {
        guard gobanState.eyeStatus == .book else { return }
        withAnimation {
            if let wr = bookLookup.bestBlackWinrate {
                rootWinrate.black = wr
            }
            if let sc = bookLookup.bestBlackScore {
                rootScore.black = sc
            }
        }
    }

    /// Flip a color between Human (thinking time 0) and AI (0.5s) when its
    /// captured-stone capsule is tapped. Reuses `ConfigEngineSync.set*MaxTime`,
    /// which writes the live `Config` (label updates via Observation) and re-arms
    /// analysis so an enabled side-to-move generates a move immediately.
    private func toggleAI(for color: PlayerColor) {
        switch color {
        case .black:
            ConfigEngineSync.setBlackMaxTime(config.toggledMaxTime(for: .black),
                                             config: config,
                                             gobanState: gobanState,
                                             player: player,
                                             messageList: messageList)
        case .white:
            ConfigEngineSync.setWhiteMaxTime(config.toggledMaxTime(for: .white),
                                             config: config,
                                             gobanState: gobanState,
                                             player: player,
                                             messageList: messageList)
        case .unknown:
            break
        }
    }

    /// The visits/s text to show beside the captured-stone counts, or nil when hidden.
    private var speedText: String? {
        guard gobanState.showVisitsPerSecond,
              gobanState.analysisStatus == .run,
              analysis.visitsPerSecond > 0 else { return nil }
        return analysis.visitsPerSecondText
    }

    private func drawNextMove(dimensions: Dimensions, verticalFlip: Bool, showPass: Bool) -> some View {
        Group {
            if let nextMove = gobanState.getNextMove(gameRecord: gameRecord) {
                let boardPoint = BoardPoint(
                    location: nextMove.location,
                    width: Int(board.width),
                    height: Int(board.height)
                )

                // With the pass row hidden (tvOS review), a "next move = pass"
                // hint would float in the empty space below the grid, so skip it.
                if showPass || !boardPoint.isPass(width: Int(board.width), height: Int(board.height)) {
                    let stoneColor: Color = (nextMove.player == .black) ? .black : Color(white: 1.0)
                    let x = boardPoint.x
                    let y = boardPoint.getPositionY(height: dimensions.height, verticalFlip: verticalFlip)

                    Circle()
                        .stroke(stoneColor, lineWidth: 2)
                        .frame(width: dimensions.stoneLength, height: dimensions.stoneLength)
                        .position(x: dimensions.boardLineStartX + CGFloat(x) * dimensions.squareLength,
                                  y: dimensions.boardLineStartY + y * dimensions.squareLength)
                }
            }
        }
    }

    func locationToCoordinate(location: CGPoint, dimensions: Dimensions) -> Coordinate? {
        // Delegates to the shared `Coordinate.from` so the macOS right-click menu
        // and hover preview map points to vertices identically to this tap path.
        Coordinate.from(location: location,
                        dimensions: dimensions,
                        boardWidth: Int(board.width),
                        boardHeight: Int(board.height),
                        verticalFlip: gobanState.verticalFlip)
    }
}

