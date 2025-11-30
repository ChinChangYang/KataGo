//
//  CommentView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/9/9.
//

import SwiftUI
import FoundationModels

struct CommentView: View {
    var gameRecord: GameRecord
    @State var comment = ""
    @State private var isGenerating = false
    @Environment(GobanState.self) var gobanState
    @Environment(Analysis.self) var analysis
    @Environment(Stones.self) var stones
    @Environment(BoardSize.self) var board
    @Environment(Turn.self) var turn

    var textArea: some View {
        ZStack {
            if gobanState.isEditing {
                TextField(
                    isGenerating ? "Generating..." : "Add your comment",
                    text: $comment,
                    axis: .vertical
                )
                .disabled(isGenerating)
                .contentTransition(.opacity)

                if (comment.isEmpty) && (isGenerating == false) {
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

            if isGenerating {
                ProgressView()
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

        isGenerating = true

        Task {
            let original = generateNaturalComment()
            let analysisText = generateAnalysisText(currentIndex: gameRecord.currentIndex)
            let previousText = gameRecord.currentIndex > 0 ? generateAnalysisText(currentIndex: gameRecord.currentIndex - 1) : "None"

            let prompt =
"""
Improve the precise and friendly quality of the original Go commentary. Return a single paragraph of the improved commentary suitable for display as a comment for the current move.

For context-only, commentary of the previous move:
\(previousText)

Analysis of the current move:
\(analysisText)

Original Go commentary of the current move to be improved:
\(original)
"""

            do {
                let session = LanguageModelSession()
                let options = GenerationOptions(temperature: 1.0)
                let response = try await session.respond(to: prompt, options: options)
                let improved = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

                await MainActor.run {
                    withAnimation {
                        comment = improved.isEmpty ? original : improved

#if DEBUG
                        comment =
"""
\(comment)

\(prompt)
"""
#endif

                        isGenerating = false
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation {
                        comment = original
                        isGenerating = false
                    }
                }
            }
        }
    }

    func generateAnalysisText(currentIndex: Int) -> String {
        let nextIndex = currentIndex + 1
        let lastMoveText = generateLastMoveText()
        let colorToPlay = turn.nextColorForPlayCommand.name
        let colorPlayed = turn.nextColorForPlayCommand.other.name
        let nextMoveText = gameRecord.moves?[currentIndex] ?? "Unknown"

        let nextWinrateText = formatWinRate(
            gameRecord.winRates?[nextIndex],
            for: turn.nextColorForPlayCommand
        )

        let nextScoreText = formatScore(
            gameRecord.scoreLeads?[nextIndex],
            for: turn.nextColorForPlayCommand
        )

        let nextDeadBlackStonesText = gameRecord.deadBlackStones?[nextIndex] ?? "Unknown"
        let nextDeadWhiteStonesText = gameRecord.deadWhiteStones?[nextIndex] ?? "Unknown"
        let nextBlackSchrodingerText = gameRecord.blackSchrodingerStones?[nextIndex] ?? "Unknown"
        let nextWhiteSchrodingerText = gameRecord.whiteSchrodingerStones?[nextIndex] ?? "Unknown"
        let bestMoveText = gameRecord.bestMoves?[currentIndex] ?? "Unknown"

        let bestWinrateText = formatWinRate(
            gameRecord.winRates?[currentIndex],
            for: turn.nextColorForPlayCommand
        )

        let bestScoreText = formatScore(
            gameRecord.scoreLeads?[currentIndex],
            for: turn.nextColorForPlayCommand
        )

        let bestDeadBlackStonesText = gameRecord.deadBlackStones?[currentIndex] ?? "Unknown"
        let bestDeadWhiteStonesText = gameRecord.deadWhiteStones?[currentIndex] ?? "Unknown"
        let bestBlackSchrodingerText = gameRecord.blackSchrodingerStones?[currentIndex] ?? "Unknown"
        let bestWhiteSchrodingerText = gameRecord.whiteSchrodingerStones?[currentIndex] ?? "Unknown"

        let analysisText =
"""
- Previous Color Played: \(colorPlayed)
- Previous Move by \(colorPlayed): \(lastMoveText)
- Next Color to Play: \(colorToPlay)
- Next Move by \(colorToPlay): \(nextMoveText)
- Next Move's \(colorToPlay) Winrate: \(nextWinrateText)
- Next Move's \(colorToPlay) Score: \(nextScoreText).
- Next Move's Dead Black Stones: \(nextDeadBlackStonesText)
- Next Move's Dead White Stones: \(nextDeadWhiteStonesText)
- Next Move's Endangered Black Stones: \(nextBlackSchrodingerText)
- Next Move's Endangered White Stones: \(nextWhiteSchrodingerText)
- AI suggested Next Move for \(colorToPlay): \(bestMoveText)
- AI Move's \(colorToPlay) Winrate: \(bestWinrateText)
- AI Move's \(colorToPlay) Score: \(bestScoreText).
- AI Move's Dead Black Stones: \(bestDeadBlackStonesText)
- AI Move's Dead White Stones: \(bestDeadWhiteStonesText)
- AI Move's Endangered Black Stones: \(bestBlackSchrodingerText)
- AI Move's Endangered White Stones: \(bestWhiteSchrodingerText)
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

        let nextWinrateText = formatWinRate(
            gameRecord.winRates?[nextIndex],
            for: turn.nextColorForPlayCommand
        )

        let bestWinrateText = formatWinRate(
            gameRecord.winRates?[currentIndex],
            for: turn.nextColorForPlayCommand
        )

        let winRateDiffer = (nextWinrateText != bestWinrateText) && (bestWinrateText != "Unknown")

        let winRateDiffText = winRateDiffer ? formatWinRateDiff(
            gameRecord.winRates?[currentIndex],
            gameRecord.winRates?[nextIndex],
            for: turn.nextColorForPlayCommand
        ) : ""

        let nextWinrateSentence = nextWinrateText == "Unknown" ? "" : " \(colorToPlay) win rate is \(nextWinrateText)\(winRateDiffText)."

        let nextScoreText = formatScore(
            gameRecord.scoreLeads?[nextIndex],
            for: turn.nextColorForPlayCommand
        )

        let bestScoreText = formatScore(
            gameRecord.scoreLeads?[currentIndex],
            for: turn.nextColorForPlayCommand
        )

        let scoreDiffer = (nextScoreText != bestScoreText) && (bestScoreText != "Unknown")

        let scoreDiffText = scoreDiffer ? formatScoreDiff(
            gameRecord.scoreLeads?[currentIndex],
            gameRecord.scoreLeads?[nextIndex],
            for: turn.nextColorForPlayCommand
        ) : ""

        let nextScoreSentence = (
            (nextScoreText == "Unknown" || scoreDiffText.isEmpty) ? ""
            : " \(nextScoreText). \(scoreDiffText)."
        )

        let nextDeadBlackStonesText = gameRecord.deadBlackStones?[nextIndex] ?? "Unknown"
        let bestDeadBlackStonesText = gameRecord.deadBlackStones?[currentIndex] ?? "Unknown"
        let deadBlackStonesDiffer = (nextDeadBlackStonesText != bestDeadBlackStonesText) && (bestDeadBlackStonesText != "Unknown")

        let deadBlackStonesDiffText = deadBlackStonesDiffer ? formatDeadStonesDiff(
            current: gameRecord.deadBlackStones?[currentIndex],
            next: gameRecord.deadBlackStones?[nextIndex],
            color: .black
        ) : ""

        let nextDeadBlackStonesSentence = (
            (!deadBlackStonesDiffer || deadBlackStonesDiffText.isEmpty) ? "" : " \(deadBlackStonesDiffText)."
        )

        let nextDeadWhiteStonesText = gameRecord.deadWhiteStones?[nextIndex] ?? "Unknown"
        let bestDeadWhiteStonesText = gameRecord.deadWhiteStones?[currentIndex] ?? "Unknown"
        let deadWhiteStonesDiffer = (nextDeadWhiteStonesText != bestDeadWhiteStonesText) && (bestDeadWhiteStonesText != "Unknown")

        let deadWhiteStonesDiffText = deadWhiteStonesDiffer ? formatDeadStonesDiff(
            current: gameRecord.deadWhiteStones?[currentIndex],
            next: gameRecord.deadWhiteStones?[nextIndex],
            color: .white
        ) : ""

        let nextDeadWhiteStonesSentence = (
            (!deadWhiteStonesDiffer || deadWhiteStonesDiffText.isEmpty) ? "" : " \(deadWhiteStonesDiffText)."
        )

        let nextBlackSchrodingerText = gameRecord.blackSchrodingerStones?[nextIndex] ?? "Unknown"
        let bestBlackSchrodingerText = gameRecord.blackSchrodingerStones?[currentIndex] ?? "Unknown"
        let blackSchrodingerDiffer = (nextBlackSchrodingerText != bestBlackSchrodingerText) && (bestBlackSchrodingerText != "Unknown")

        let nextBlackSchrodingerSentence = (
            (!blackSchrodingerDiffer) ? "" :
                nextBlackSchrodingerText == "None" ? " None of Black's stones have an unresolved life-and-death." :
                " The life-and-death at \(nextBlackSchrodingerText) for Black remain unresolved."
        )

        let nextWhiteSchrodingerText = gameRecord.whiteSchrodingerStones?[nextIndex] ?? "Unknown"
        let bestWhiteSchrodingerText = gameRecord.whiteSchrodingerStones?[currentIndex] ?? "Unknown"
        let whiteSchrodingerDiffer = (nextWhiteSchrodingerText != bestWhiteSchrodingerText) && (bestWhiteSchrodingerText != "Unknown")

        let nextWhiteSchrodingerSentence = (
            (!whiteSchrodingerDiffer) ? "" :
                nextWhiteSchrodingerText == "None" ? " None of White's stones have an unresolved life-and-death." :
                " The life-and-death at \(nextWhiteSchrodingerText) for White remain unresolved."
        )

        let bestMoveText = gameRecord.bestMoves?[currentIndex] ?? "Unknown"
        let bestMoveDiffer = (bestMoveText != nextMoveText) && (bestMoveText != "Unknown")

        let bestMoveSentence = (
            bestMoveDiffer ? " KataGo AI recommends \(bestMoveText)." :
                " KataGo agrees with \(colorToPlay) number \(nextIndex) at \(bestMoveText)."
        )

        let bestWinrateSentence = (
            (bestMoveDiffer && winRateDiffer) ? " If \(colorToPlay) plays the recommended move, \(colorToPlay)'s win rate will change to \(bestWinrateText)." :
                bestMoveDiffer ? " It doesn't significantly change \(colorToPlay) win rate." :
                ""
        )

        let bestScoreSentence = (
            (bestMoveDiffer && scoreDiffer) ? " If \(colorToPlay) plays the recommended move, \(bestScoreText)." :
                bestMoveDiffer ? " It doesn't significantly change \(colorToPlay) score." :
                ""
        )

        let bestDeadBlackStonesSentence = (
            (!deadBlackStonesDiffer) ? "" :
            (bestMoveDiffer && (bestDeadBlackStonesText != "None")) ? " Black's stones at \(bestDeadBlackStonesText) will be dead." :
                bestMoveDiffer ? " None of Black's stones will be dead on the board." :
                ""
        )

        let bestDeadWhiteStonesSentence = (
            (!deadWhiteStonesDiffer) ? "" :
            (bestMoveDiffer && (bestDeadWhiteStonesText != "None")) ? " White's stones at \(bestDeadWhiteStonesText) will be dead." :
                bestMoveDiffer ? " None of White's stones will be dead on the board." :
                ""
        )

        let bestBlackSchrodingerSentence = (
            (!blackSchrodingerDiffer) ? "" :
            (bestMoveDiffer && (bestBlackSchrodingerText != "None")) ? " KataGo thinks the life-and-death at \(bestBlackSchrodingerText) for Black is unresolved." :
                bestMoveDiffer ? " KataGo thinks none of Black's stones have an unresolved life-and-death." :
                ""
        )

        let bestWhiteSchrodingerSentence = (
            (!whiteSchrodingerDiffer) ? "" :
            (bestMoveDiffer && (bestWhiteSchrodingerText != "None")) ? " KataGo thinks the life-and-death at \(bestWhiteSchrodingerText) for White is unresolved." :
                bestMoveDiffer ? " KataGo thinks none of White's stones have an unresolved life-and-death." :
                ""
        )

        var comment: String

        if currentIndex >= 1 {
            comment =
"""
\(colorPlayed) number \(currentIndex) plays \(lastMoveText). Then, \(colorToPlay) number \(nextIndex) plays \(nextMoveText).\(nextWinrateSentence)\(nextScoreSentence)\(nextDeadBlackStonesSentence)\(nextDeadWhiteStonesSentence)\(nextBlackSchrodingerSentence)\(nextWhiteSchrodingerSentence)\(bestMoveSentence)\(bestWinrateSentence)\(bestScoreSentence)\(bestDeadBlackStonesSentence)\(bestDeadWhiteStonesSentence)\(bestBlackSchrodingerSentence)\(bestWhiteSchrodingerSentence)
"""
        } else {
            comment =
"""
Game starts. \(colorToPlay) number \(nextIndex) plays \(nextMoveText).\(nextWinrateSentence)\(nextScoreSentence)\(nextDeadBlackStonesSentence)\(nextDeadWhiteStonesSentence)\(nextBlackSchrodingerSentence)\(nextWhiteSchrodingerSentence)\(bestMoveSentence)\(bestWinrateSentence)\(bestScoreSentence)\(bestDeadBlackStonesSentence)\(bestDeadWhiteStonesSentence)\(bestBlackSchrodingerSentence)\(bestWhiteSchrodingerSentence)
"""
        }

        return comment
    }

    private func generateLastMoveText() -> String {
        guard gameRecord.currentIndex >= 1 else { return "None" }
        let lastMove = gameRecord.moves?[gameRecord.currentIndex - 1] ?? "Unknown"
        return lastMove
    }

    private func formatWinRate(_ blackWinRate: Float?, for selfColor: PlayerColor) -> String {
        guard let blackWinRate else {
            return "Unknown"
        }

        let winRate = (selfColor == .black) ? blackWinRate : (1.0 - blackWinRate)
        let winRateText = String(format: "%2.0f%%", (winRate * 100).rounded())

        return winRateText
    }

    private func formatWinRateDiff(
        _ bestBlackWinRate: Float?,
        _ myBlackWinRate: Float?,
        for selfColor: PlayerColor
    ) -> String {
        guard let bestBlackWinRate, let myBlackWinRate else {
            return ""
        }

        let bestWinRate = (selfColor == .black) ? bestBlackWinRate : (1.0 - bestBlackWinRate)
        let myWinRate = (selfColor == .black) ? myBlackWinRate : (1.0 - myBlackWinRate)
        let winRateDiff = bestWinRate - myWinRate
        let verb = (winRateDiff > 0) ? "decreased" : "increased"
        let winRateDiffText = String(format: "%2.0f%%", (abs(winRateDiff) * 100).rounded())
        let bestWinRateText = String(format: "%2.0f%%", (bestWinRate * 100).rounded())
        let winRateDiffSentence = ", \(verb) by \(winRateDiffText) from \(bestWinRateText)"

        return winRateDiffSentence
    }

    private func formatScore(_ blackScore: Float?, for selfColor: PlayerColor) -> String {
        guard let blackScore else {
            return "Unknown"
        }

        let score = (selfColor == .black) ? blackScore : (-blackScore)
        let scoreText = String(round(Double(abs(score)) * 10) / 10.0)
        let verb = (score > 0) ? "leads" : "is behind"
        let scoreSentence = "\(selfColor.name) \(verb) by \(scoreText) points"

        return scoreSentence
    }

    private func formatScoreDiff(
        _ bestBlackScore: Float?,
        _ myBlackScore: Float?,
        for selfColor: PlayerColor
    ) -> String {
        guard let bestBlackScore, let myBlackScore else {
            return ""
        }
        
        let bestScore = (selfColor == .black) ? bestBlackScore : (-bestBlackScore)
        let myScore = (selfColor == .black) ? myBlackScore : (-myBlackScore)
        let scoreDiff = bestScore - myScore
        let verb = (scoreDiff > 0) ? "decreased" : "increased"
        let scoreDiffText = String(round(Double(abs(scoreDiff)) * 10) / 10.0)
        let bestScoreText = String(round(Double(bestScore) * 10) / 10.0)
        let scoreDiffSentence = "\(selfColor.name) score is \(verb) by \(scoreDiffText) points from \(bestScoreText)"

        return scoreDiffSentence
    }
    
    private func formatDeadStonesDiff(
        current: String?,
        next: String?,
        color: PlayerColor
    ) -> String {
        guard let current, let next, current != next else { return "" }

        let currentSet = Set(current.split(separator: " ").map(String.init))
        let nextSet = Set(next.split(separator: " ").map(String.init))
        let deadStones = nextSet.subtracting(currentSet)
        guard !deadStones.isEmpty else { return "" }
        let stonesString = deadStones.sorted().joined(separator: " ")
        return "\(color.name) \(stonesString) are dead"
    }
}
