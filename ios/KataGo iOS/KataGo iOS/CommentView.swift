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

    func generateAnalysisText() -> String {
        let colorToPlay = turn.nextColorForPlayCommand.name
        let bestMoveText = gameRecord.bestMoves?[gameRecord.currentIndex] ?? "Unknown"
        let blackWinrateText = formatBlackWinRate(gameRecord.winRates?[gameRecord.currentIndex])
        let blackScoreText = formatBlackScore(gameRecord.scoreLeads?[gameRecord.currentIndex])
        let deadBlackStonesText = gameRecord.deadBlackStones?[gameRecord.currentIndex] ?? "Unknown"
        let deadWhiteStonesText = gameRecord.deadWhiteStones?[gameRecord.currentIndex] ?? "Unknown"
        let blackSchrodingerText = gameRecord.blackSchrodingerStones?[gameRecord.currentIndex] ?? "Unknown"
        let whiteSchrodingerText = gameRecord.whiteSchrodingerStones?[gameRecord.currentIndex] ?? "Unknown"

        let analysisText =
"""
- Color to Play: \(colorToPlay)
- Best Move: \(bestMoveText)
- Black Winrate: \(blackWinrateText)
- Black Score Lead: \(blackScoreText)
- Dead Black Stones: \(deadBlackStonesText)
- Dead White Stones: \(deadWhiteStonesText)
- Schrödinger's Black Stones: \(blackSchrodingerText)
- Schrödinger's White Stones: \(whiteSchrodingerText)
"""

        return analysisText
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
