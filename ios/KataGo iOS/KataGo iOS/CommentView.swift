//
//  CommentView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/9/9.
//

import SwiftUI

struct CommentView: View {
    var gameRecord: GameRecord
    @State var comment = ""
    @Environment(GobanState.self) var gobanState
    @Environment(Analysis.self) var analysis
    @Environment(Stones.self) var stones
    @Environment(BoardSize.self) var board
    @Environment(Turn.self) var turn

    var textArea: some View {
        ZStack {
            if gobanState.isEditing {
                TextField("Add your comment", text: $comment, axis: .vertical)

                if comment.isEmpty {
                    VStack {
                        Spacer()
                        Button {
                            wandAndSparklesAction()
                        } label: {
                            Image(systemName: "wand.and.sparkles")
                        }
                    }
                }
            } else {
                Text(comment.isEmpty ? "(No comment)" : comment)
                    .foregroundStyle(comment.isEmpty ? .secondary : .primary)
            }
        }
    }

    var body: some View {
        ScrollViewReader { _ in
            ScrollView(.vertical) {
                textArea
                    .onAppear {
                        if gameRecord.comments == nil {
                            gameRecord.comments = [:]
                        }

                        comment = gameRecord.comments?[gameRecord.currentIndex] ?? ""
                    }
                    .onChange(of: gameRecord.currentIndex) { oldIndex, newIndex in
                        if oldIndex != newIndex {
                            gameRecord.comments?[oldIndex] = comment
                            comment = gameRecord.comments?[newIndex] ?? ""
                        }
                    }
                    .onDisappear {
                        gameRecord.comments?[gameRecord.currentIndex] = comment
                    }
            }
        }
    }

    func wandAndSparklesAction() {
        gobanState.maybeUpdateMoves(gameRecord: gameRecord, board: board)

        if gobanState.analysisStatus != .clear {
            gobanState.maybeUpdateAnalysisData(
                gameRecord: gameRecord,
                analysis: analysis,
                board: board,
                stones: stones
            )
        }

        withAnimation {
            comment = generateAnalysisText()
        }
    }

    func generateAnalysisText() -> String {
        let currentIndex = gameRecord.currentIndex
        let nextIndex = gameRecord.currentIndex + 1
        let lastMoveText = generateLastMoveText()
        let colorToPlay = turn.nextColorForPlayCommand.name
        let nextMoveText = gameRecord.moves?[currentIndex] ?? "Unknown"
        let nextBlackWinrateText = formatBlackWinRate(gameRecord.winRates?[nextIndex])
        let nextBlackScoreText = formatBlackScore(gameRecord.scoreLeads?[nextIndex])
        let nextDeadBlackStonesText = gameRecord.deadBlackStones?[nextIndex] ?? "Unknown"
        let nextDeadWhiteStonesText = gameRecord.deadWhiteStones?[nextIndex] ?? "Unknown"
        let nextBlackSchrodingerText = gameRecord.blackSchrodingerStones?[nextIndex] ?? "Unknown"
        let nextWhiteSchrodingerText = gameRecord.whiteSchrodingerStones?[nextIndex] ?? "Unknown"
        let bestMoveText = gameRecord.bestMoves?[currentIndex] ?? "Unknown"
        let bestBlackWinrateText = formatBlackWinRate(gameRecord.winRates?[currentIndex])
        let bestBlackScoreText = formatBlackScore(gameRecord.scoreLeads?[currentIndex])
        let bestDeadBlackStonesText = gameRecord.deadBlackStones?[currentIndex] ?? "Unknown"
        let bestDeadWhiteStonesText = gameRecord.deadWhiteStones?[currentIndex] ?? "Unknown"
        let bestBlackSchrodingerText = gameRecord.blackSchrodingerStones?[currentIndex] ?? "Unknown"
        let bestWhiteSchrodingerText = gameRecord.whiteSchrodingerStones?[currentIndex] ?? "Unknown"

        let analysisText =
"""
- Last Move: \(lastMoveText)
- Color to Play: \(colorToPlay)
- Next Move: \(nextMoveText)
- Next Move's Winrate: \(nextBlackWinrateText)
- Next Move's Score Lead: \(nextBlackScoreText)
- Next Move's Dead Black Stones: \(nextDeadBlackStonesText)
- Next Move's Dead White Stones: \(nextDeadWhiteStonesText)
- Next Move's Schrödinger's Black Stones: \(nextBlackSchrodingerText)
- Next Move's Schrödinger's White Stones: \(nextWhiteSchrodingerText)
- AI suggested Next Move: \(bestMoveText)
- AI Move's Black Winrate: \(bestBlackWinrateText)
- AI Move's Black Score Lead: \(bestBlackScoreText)
- AI Move's Dead Black Stones: \(bestDeadBlackStonesText)
- AI Move's Dead White Stones: \(bestDeadWhiteStonesText)
- AI Move's Schrödinger's Black Stones: \(bestBlackSchrodingerText)
- AI Move's Schrödinger's White Stones: \(bestWhiteSchrodingerText)
"""

        return analysisText
    }

    private func generateLastMoveText() -> String {
        guard gameRecord.currentIndex >= 1 else { return "None" }
        let lastMove = gameRecord.moves?[gameRecord.currentIndex - 1] ?? "Unknown"
        return lastMove
    }

    private func formatBlackWinRate(_ blackWinRate: Float?) -> String {
        guard let blackWinRate else {
            return "Unknown"
        }

        let blackWinRateText = String(format: "%2.0f%%", (blackWinRate * 100).rounded())
        return blackWinRateText
    }

    private func formatBlackScore(_ blackScore: Float?) -> String {
        guard let blackScore else {
            return "Unknown"
        }

        let blackScoreText = String(round(Double(blackScore) * 10) / 10.0)
        return blackScoreText
    }
}
