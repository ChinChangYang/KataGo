//
//  Commentator.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/11/30.
//

import SwiftUI
import FoundationModels

class Commentator {
    var gameRecord: GameRecord
    var turn: Turn

    init(gameRecord: GameRecord, turn: Turn) {
        self.gameRecord = gameRecord
        self.turn = turn
    }

    @MainActor
    func generateImprovedComment() async -> String {
        let original = generateNaturalComment()

        let prompt =
"""
Refine the following original Go commentary into a single, cohesive, and insightful paragraph suitable for display as a comment for the current move.

The refined commentary must adopt Technical Tone, highly objective and analysis-driven, focusing almost exclusively on win rates, score difference, and exact positional evaluation. Language is clean, concise, and professional, minimizing subjective adjectives. The structure must adhere to the following three steps: Move Report, Impact Analysis, and AI Recommendation.

Return only the single, improved paragraph of commentary.

Original Go commentary of the current move to be improved:
\(original)
"""

        var comment = original

        do {
            let session = LanguageModelSession()
            let temperature = Double(gameRecord.config?.temperature ?? Config.defaultTemperature)
            let options = GenerationOptions(temperature: temperature)

            let response = try await session.respond(
                to: prompt,
                generating: CommentText.self,
                options: options
            )

            let improved = response.content.description

            comment = improved.isEmpty ? original : improved

#if DEBUG
            let analysisText = generateAnalysisText(currentIndex: gameRecord.currentIndex)

            comment =
"""
\(comment)

\(prompt)

\(analysisText)
"""
#endif
        } catch {
            comment = original
        }

        return comment
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

    func generateNaturalComment() -> String {
        let currentIndex = gameRecord.currentIndex
        let nextIndex = gameRecord.currentIndex + 1
        let lastMoveText = generateLastMoveText()
        let colorToPlay = turn.nextColorForPlayCommand.name
        let colorPlayed = turn.nextColorForPlayCommand.other.name
        let nextMoveText = gameRecord.moves?[currentIndex] ?? "Unknown"

        let colorToPlaySentence = (
            nextMoveText == "Unknown" ? "" :
            " Then, \(colorToPlay) number \(nextIndex) plays a stone at \(nextMoveText)."
        )

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
            ((nextMoveText == "Unknown") || !deadBlackStonesDiffer || deadBlackStonesDiffText.isEmpty) ? "" : " \(deadBlackStonesDiffText)."
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
            ((nextMoveText == "Unknown") || !deadWhiteStonesDiffer || deadWhiteStonesDiffText.isEmpty) ? "" : " \(deadWhiteStonesDiffText)."
        )

        let nextBlackSchrodingerText = gameRecord.blackSchrodingerStones?[nextIndex] ?? "Unknown"
        let bestBlackSchrodingerText = gameRecord.blackSchrodingerStones?[currentIndex] ?? "Unknown"
        let blackSchrodingerDiffer = (nextBlackSchrodingerText != bestBlackSchrodingerText) && (bestBlackSchrodingerText != "Unknown")

        let nextBlackSchrodingerSentence = (
            ((nextMoveText == "Unknown") || !blackSchrodingerDiffer) ? "" :
                nextBlackSchrodingerText == "None" ? " None of Black's stones have an unresolved life-and-death." :
                " The life-and-death at \(nextBlackSchrodingerText) for Black remain unresolved."
        )

        let nextWhiteSchrodingerText = gameRecord.whiteSchrodingerStones?[nextIndex] ?? "Unknown"
        let bestWhiteSchrodingerText = gameRecord.whiteSchrodingerStones?[currentIndex] ?? "Unknown"
        let whiteSchrodingerDiffer = (nextWhiteSchrodingerText != bestWhiteSchrodingerText) && (bestWhiteSchrodingerText != "Unknown")

        let nextWhiteSchrodingerSentence = (
            ((nextMoveText == "Unknown") || !whiteSchrodingerDiffer) ? "" :
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

        let bestDeadBlackStonesDiffText = deadBlackStonesDiffer ? formatDeadStonesDiff(
            current: gameRecord.deadBlackStones?[nextIndex],
            next: gameRecord.deadBlackStones?[currentIndex],
            color: .black
        ) : ""

        let bestDeadBlackStonesSentence = (
            (!deadBlackStonesDiffer || !bestMoveDiffer || bestDeadBlackStonesDiffText.isEmpty) ? "" :
                " If \(colorToPlay) plays the recommended move, \(bestDeadBlackStonesDiffText)."
        )

        let bestDeadWhiteStonesDiffText = deadWhiteStonesDiffer ? formatDeadStonesDiff(
            current: gameRecord.deadWhiteStones?[nextIndex],
            next: gameRecord.deadWhiteStones?[currentIndex],
            color: .white
        ) : ""

        let bestDeadWhiteStonesSentence = (
            (!deadWhiteStonesDiffer || !bestMoveDiffer || bestDeadWhiteStonesDiffText.isEmpty) ? "" :
                " If \(colorToPlay) plays the recommended move, \(bestDeadWhiteStonesDiffText)."
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
\(colorPlayed) number \(currentIndex) plays a stone at \(lastMoveText).\(colorToPlaySentence)\(nextWinrateSentence)\(nextScoreSentence)\(nextDeadBlackStonesSentence)\(nextDeadWhiteStonesSentence)\(nextBlackSchrodingerSentence)\(nextWhiteSchrodingerSentence)\(bestMoveSentence)\(bestWinrateSentence)\(bestScoreSentence)\(bestDeadBlackStonesSentence)\(bestDeadWhiteStonesSentence)\(bestBlackSchrodingerSentence)\(bestWhiteSchrodingerSentence)
"""
        } else {
            comment =
"""
Game starts.\(colorToPlaySentence)\(nextWinrateSentence)\(nextScoreSentence)\(nextDeadBlackStonesSentence)\(nextDeadWhiteStonesSentence)\(nextBlackSchrodingerSentence)\(nextWhiteSchrodingerSentence)\(bestMoveSentence)\(bestWinrateSentence)\(bestScoreSentence)\(bestDeadBlackStonesSentence)\(bestDeadWhiteStonesSentence)\(bestBlackSchrodingerSentence)\(bestWhiteSchrodingerSentence)
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

        let deadStonesDiffText = (
            stonesString == "None" ? "None of \(color.name) stones are completely dead" :
                "\(color.name) \(stonesString) are completely dead"
        )

        return deadStonesDiffText
    }
}

@Generable
struct CommentText {
    @Guide(description: "The improved Go commentary in single paragraph.")
    let description: String
}

