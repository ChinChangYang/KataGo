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
            comment = generateNaturalComment()
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

    private func generateNaturalComment() -> String {
        let currentIndex = gameRecord.currentIndex
        let nextIndex = gameRecord.currentIndex + 1
        let lastMoveText = generateLastMoveText()
        let colorToPlay = turn.nextColorForPlayCommand.name
        let colorPlayed = turn.nextColorForPlayCommand.other.name
        let nextMoveText = gameRecord.moves?[currentIndex] ?? "Unknown"
        let nextBlackWinrateText = formatBlackWinRate(gameRecord.winRates?[nextIndex])

        let nextBlackWinrateSentence = nextBlackWinrateText == "Unknown" ? "" : " Black win rate is \(nextBlackWinrateText)."

        let nextBlackScoreText = formatBlackScore(gameRecord.scoreLeads?[nextIndex])

        let nextBlackScoreSentence = nextBlackScoreText == "Unknown" ? "" : " Black leads by \(nextBlackScoreText) points."

        let nextDeadBlackStonesText = gameRecord.deadBlackStones?[nextIndex] ?? "Unknown"

        let nextDeadBlackStonesSentence = (
            nextDeadBlackStonesText == "Unknown" ? "" :
                nextDeadBlackStonesText == "None" ? " None of Black's stones is dead on the board." :
                " Black's stones at \(nextDeadBlackStonesText) will be dead."
        )

        let nextDeadWhiteStonesText = gameRecord.deadWhiteStones?[nextIndex] ?? "Unknown"

        let nextDeadWhiteStonesSentence = (
            nextDeadWhiteStonesText == "Unknown" ? "" :
                nextDeadWhiteStonesText == "None" ? " None of White's stones is dead on the board." :
                " White's stones at \(nextDeadWhiteStonesText) will be dead."
        )

        let nextBlackSchrodingerText = gameRecord.blackSchrodingerStones?[nextIndex] ?? "Unknown"

        let nextBlackSchrodingerSentence = (
            nextBlackSchrodingerText == "Unknown" ? "" :
                nextBlackSchrodingerText == "None" ? " None of Black's stones have an unresolved life-and-death." :
                " The life-and-death at \(nextBlackSchrodingerText) for Black remain unresolved."
        )

        let nextWhiteSchrodingerText = gameRecord.whiteSchrodingerStones?[nextIndex] ?? "Unknown"

        let nextWhiteSchrodingerSentence = (
            nextWhiteSchrodingerText == "Unknown" ? "" :
                nextWhiteSchrodingerText == "None" ? " None of White's stones have an unresolved life-and-death." :
                " The life-and-death at \(nextWhiteSchrodingerText) for White remain unresolved."
        )

        let bestMoveText = gameRecord.bestMoves?[currentIndex] ?? "Unknown"
        let bestMoveDiffer = (bestMoveText != nextMoveText) && (bestMoveText != "Unknown")

        let bestMoveSentence = bestMoveDiffer ? " KataGo recommends \(bestMoveText)" : ""

        let bestBlackWinrateText = formatBlackWinRate(gameRecord.winRates?[currentIndex])

        let bestBlackWinrateSentence = bestMoveDiffer ? ", which changes Black win rate to \(bestBlackWinrateText)." : ""

        let bestBlackScoreText = formatBlackScore(gameRecord.scoreLeads?[currentIndex])

        let bestBlackScoreSentence = bestMoveDiffer ? " If the recommended move is played, Black will lead by \(bestBlackScoreText)." : ""

        let bestDeadBlackStonesText = gameRecord.deadBlackStones?[currentIndex] ?? "Unknown"

        let bestDeadBlackStonesSentence = (
            (bestMoveDiffer && (bestDeadBlackStonesText != "None")) ? " Black's stones at \(bestDeadBlackStonesText) will be dead." :
                bestMoveDiffer ? " None of Black's stones will be dead on the board." :
                ""
        )

        let bestDeadWhiteStonesText = gameRecord.deadWhiteStones?[currentIndex] ?? "Unknown"

        let bestDeadWhiteStonesSentence = (
            (bestMoveDiffer && (bestDeadWhiteStonesText != "None")) ? " White's stones at \(bestDeadWhiteStonesText) will be dead." :
                bestMoveDiffer ? " None of White's stones will be dead on the board." :
                ""
        )

        let bestBlackSchrodingerText = gameRecord.blackSchrodingerStones?[currentIndex] ?? "Unknown"

        let bestBlackSchrodingerSentence = (
            (bestMoveDiffer && (bestBlackSchrodingerText != "None")) ? " The life-and-death at \(bestBlackSchrodingerText) for Black will remain unresolved." :
                bestMoveDiffer ? " None of Black's stones will have an unresolved life-and-death." :
                ""
        )

        let bestWhiteSchrodingerText = gameRecord.whiteSchrodingerStones?[currentIndex] ?? "Unknown"

        let bestWhiteSchrodingerSentence = (
            (bestMoveDiffer && (bestWhiteSchrodingerText != "None")) ? " The life-and-death at \(bestWhiteSchrodingerText) for White will remain unresolved." :
                bestMoveDiffer ? " None of White's stones will have an unresolved life-and-death." :
                ""
        )

        var comment: String

        if currentIndex >= 1 {
            comment =
"""
\(colorPlayed) number \(currentIndex) plays \(lastMoveText). \(colorToPlay) number \(nextIndex) plays \(nextMoveText).\(nextBlackWinrateSentence)\(nextBlackScoreSentence)\(nextDeadBlackStonesSentence)\(nextDeadWhiteStonesSentence)\(nextBlackSchrodingerSentence)\(nextWhiteSchrodingerSentence)\(bestMoveSentence)\(bestBlackWinrateSentence)\(bestBlackScoreSentence)\(bestDeadBlackStonesSentence)\(bestDeadWhiteStonesSentence)\(bestBlackSchrodingerSentence)\(bestWhiteSchrodingerSentence)
"""
        } else {
            comment =
"""
Game starts. \(colorToPlay) number \(nextIndex) plays \(nextMoveText).\(nextBlackWinrateSentence)\(nextBlackScoreSentence)\(nextDeadBlackStonesSentence)\(nextDeadWhiteStonesSentence)\(nextBlackSchrodingerSentence)\(nextWhiteSchrodingerSentence)\(bestMoveSentence)\(bestBlackWinrateSentence)\(bestBlackScoreSentence)\(bestDeadBlackStonesSentence)\(bestDeadWhiteStonesSentence)\(bestBlackSchrodingerSentence)\(bestWhiteSchrodingerSentence)
"""
        }

        return comment
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
