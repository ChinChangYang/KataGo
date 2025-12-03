//
//  Commentator.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/11/30.
//

import SwiftUI
import FoundationModels

enum CommentTone: Int {
    case technical = 0
    case educational = 1
    case encouraging = 2
    case enthusiastic = 3
    case poetic = 4

    var prompt: String {
        switch self {
        case .educational:
            return "Educational Tone, focusing on why moves are good or bad, explaining the underlying principles (e.g., shape, influence, territory). Uses terms like this illustrates, a common mistake, principle, suboptimal, lesson, shape, evaluation, textbook, fundamentals, illustration, or the proper technique"
        case .encouraging:
            return "Encouraging Tone, gentle and non-judgmental, treating deviations from the AI as opportunities for human insight. Uses terms like solid, feasible, developing, trusting your intuition, valid, interesting choice, opportunity, worth exploring, hold steady, small setback"
        case .enthusiastic:
            return "Enthusiastic Tone, highly energetic and exciting, using vivid adjectives to describe moves as brilliant, daring, explosive, spectacular, momentum, thrill, seizing the initiative, high-stakes, decisive, or crucial. Focuses on the dramatic narrative of the game"
        case .poetic:
            return "Poetic Tone, emphasizing the beauty, depth, and aesthetics of the game. Uses abstract language relating moves to concepts like harmony, balance, patience, ephemeral, reflection, profound, rhythm, canvas, aesthetics, or destiny"
        default:
            return "Technical Tone, highly objective and analysis-driven, focusing almost exclusively on win rates, score difference, and exact positional evaluation. Language is clean, concise, and professional, minimizing subjective adjectives"
        }
    }
}

class Commentator {
    var gameRecord: GameRecord
    var turn: Turn
    private let session = LanguageModelSession()

    init(gameRecord: GameRecord, turn: Turn) {
        self.gameRecord = gameRecord
        self.turn = turn
    }

    func prewarm() {
        session.prewarm()
    }

    @MainActor
    func generateImprovedComment() async -> String {
        let original = generateNaturalComment()
        let commentTone: CommentTone = gameRecord.config?.tone ?? .technical

        let prompt =
"""
Refine the following original Go commentary into a single, cohesive, and insightful paragraph suitable for display as a comment for the current move.

The refined commentary must adopt \(commentTone.prompt). The structure must adhere to the following three steps: Move Report, Impact Analysis, and AI Recommendation.

Return only the single, improved paragraph of commentary.

Original Go commentary of the current move to be improved:
\(original)
"""

        var comment = original

        do {
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

        let nextDeadBlackStonesText = gameRecord.getDeadBlackStones(nextIndex) ?? "Unknown"
        let nextDeadWhiteStonesText = gameRecord.getDeadWhiteStones(nextIndex) ?? "Unknown"
        let nextEndangeredBlackStonesText = gameRecord.getBlackSacrificeableStones(nextIndex) ?? "Unknown"
        let nextEndangeredWhiteStonesText = gameRecord.getWhiteSacrificeableStones(nextIndex) ?? "Unknown"
        let nextBlackSchrodingerText = gameRecord.getBlackSchrodingerStones(nextIndex) ?? "Unknown"
        let nextWhiteSchrodingerText = gameRecord.getWhiteSchrodingerStones(nextIndex) ?? "Unknown"
        let bestMoveText = gameRecord.bestMoves?[currentIndex] ?? "Unknown"

        let bestWinrateText = formatWinRate(
            gameRecord.winRates?[currentIndex],
            for: turn.nextColorForPlayCommand
        )

        let bestScoreText = formatScore(
            gameRecord.scoreLeads?[currentIndex],
            for: turn.nextColorForPlayCommand
        )

        let bestDeadBlackStonesText = gameRecord.getDeadBlackStones(currentIndex) ?? "Unknown"
        let bestDeadWhiteStonesText = gameRecord.getDeadWhiteStones(currentIndex) ?? "Unknown"
        let bestEndangeredBlackStonesText = gameRecord.getBlackSacrificeableStones(currentIndex) ?? "Unknown"
        let bestEndangeredWhiteStonesText = gameRecord.getWhiteSacrificeableStones(currentIndex) ?? "Unknown"
        let bestBlackSchrodingerText = gameRecord.getBlackSchrodingerStones(currentIndex) ?? "Unknown"
        let bestWhiteSchrodingerText = gameRecord.getWhiteSchrodingerStones(currentIndex) ?? "Unknown"

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
- Next Move's Endangered Black Stones: \(nextEndangeredBlackStonesText)
- Next Move's Endangered White Stones: \(nextEndangeredWhiteStonesText)
- Next Move's Exchangeable Black Stones: \(nextBlackSchrodingerText)
- Next Move's Exchangeable White Stones: \(nextWhiteSchrodingerText)
- AI suggested Next Move for \(colorToPlay): \(bestMoveText)
- AI Move's \(colorToPlay) Winrate: \(bestWinrateText)
- AI Move's \(colorToPlay) Score: \(bestScoreText).
- AI Move's Dead Black Stones: \(bestDeadBlackStonesText)
- AI Move's Dead White Stones: \(bestDeadWhiteStonesText)
- AI Move's Endangered Black Stones: \(bestEndangeredBlackStonesText)
- AI Move's Endangered White Stones: \(bestEndangeredWhiteStonesText)
- AI Move's Exchangeable Black Stones: \(bestBlackSchrodingerText)
- AI Move's Exchangeable White Stones: \(bestWhiteSchrodingerText)
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
        let bestMoveText = gameRecord.bestMoves?[currentIndex] ?? "Unknown"
        let bestMoveDiffer = (bestMoveText != nextMoveText) && (bestMoveText != "Unknown")

        let nextMoveDifferText = (
            bestMoveDiffer ? ". \(colorToPlay)'s move at \(nextMoveText) is different from KataGo's recommended best move at \(bestMoveText)" :
                ", identical with KataGo's recommended move"
        )

        let colorToPlaySentence = (
            nextMoveText == "Unknown" ? "" :
                " Then, \(colorToPlay) number \(nextIndex) plays a stone at \(nextMoveText)\(nextMoveDifferText)."
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

        let nextDeadBlackStonesText = gameRecord.getDeadBlackStones(nextIndex) ?? "Unknown"
        let bestDeadBlackStonesText = gameRecord.getDeadBlackStones(currentIndex) ?? "Unknown"
        let deadBlackStonesDiffer = (nextDeadBlackStonesText != bestDeadBlackStonesText) && (bestDeadBlackStonesText != "Unknown")

        let deadBlackStonesDiffText = deadBlackStonesDiffer ? formatDeadStonesDiff(
            current: bestDeadBlackStonesText,
            next: nextDeadBlackStonesText,
            color: .black
        ) : ""

        let nextDeadBlackStonesSentence = (
            ((nextMoveText == "Unknown") || !deadBlackStonesDiffer || deadBlackStonesDiffText.isEmpty) ? "" :
                " \(deadBlackStonesDiffText)."
        )

        let nextDeadWhiteStonesText = gameRecord.getDeadWhiteStones(nextIndex) ?? "Unknown"
        let bestDeadWhiteStonesText = gameRecord.getDeadWhiteStones(currentIndex) ?? "Unknown"
        let deadWhiteStonesDiffer = (nextDeadWhiteStonesText != bestDeadWhiteStonesText) && (bestDeadWhiteStonesText != "Unknown")

        let deadWhiteStonesDiffText = deadWhiteStonesDiffer ? formatDeadStonesDiff(
            current: bestDeadWhiteStonesText,
            next: nextDeadWhiteStonesText,
            color: .white
        ) : ""

        let nextDeadWhiteStonesSentence = (
            ((nextMoveText == "Unknown") || !deadWhiteStonesDiffer || deadWhiteStonesDiffText.isEmpty) ? "" :
                " \(deadWhiteStonesDiffText)."
        )

        let nextEndangeredBlackStonesText = gameRecord.getBlackSacrificeableStones(nextIndex) ?? "Unknown"
        let bestEndangeredBlackStonesText = gameRecord.getBlackSacrificeableStones(currentIndex) ?? "Unknown"
        let endangeredBlackStonesDiffer = (nextEndangeredBlackStonesText != bestEndangeredBlackStonesText) && (bestEndangeredBlackStonesText != "Unknown")

        let endangeredBlackStonesDiffText = endangeredBlackStonesDiffer ? formatEndangeredStonesDiff(
            current: bestEndangeredBlackStonesText,
            next: nextEndangeredBlackStonesText,
            color: .black
        ) : ""
        
        let nextEndangeredBlackSentence = (
            ((nextMoveText == "Unknown") || !endangeredBlackStonesDiffer || endangeredBlackStonesDiffText.isEmpty) ? "" :
                " \(endangeredBlackStonesDiffText)."
        )

        let nextEndangeredWhiteStonesText = gameRecord.getWhiteSacrificeableStones(nextIndex) ?? "Unknown"
        let bestEndangeredWhiteStonesText = gameRecord.getWhiteSacrificeableStones(currentIndex) ?? "Unknown"
        let endangeredWhiteStonesDiffer = (nextEndangeredWhiteStonesText != bestEndangeredWhiteStonesText) && (bestEndangeredWhiteStonesText != "Unknown")

        let endangeredWhiteStonesDiffText = endangeredWhiteStonesDiffer ? formatEndangeredStonesDiff(
            current: bestEndangeredWhiteStonesText,
            next: nextEndangeredWhiteStonesText,
            color: .white
        ) : ""

        let nextEndangeredWhiteSentence = (
            ((nextMoveText == "Unknown") || !endangeredWhiteStonesDiffer || endangeredWhiteStonesDiffText.isEmpty) ? "" :
                " \(endangeredWhiteStonesDiffText)."
        )

        let nextBlackSchrodingerText = gameRecord.getBlackSchrodingerStones(nextIndex) ?? "Unknown"
        let bestBlackSchrodingerText = gameRecord.getBlackSchrodingerStones(currentIndex) ?? "Unknown"
        let blackSchrodingerDiffer = (nextBlackSchrodingerText != bestBlackSchrodingerText) && (bestBlackSchrodingerText != "Unknown")

        let blackSchrodingerDiffText = blackSchrodingerDiffer ? formatSchrodingerStonesDiff(
            current: bestBlackSchrodingerText,
            next: nextBlackSchrodingerText,
            color: .black
        ) : ""

        let nextBlackSchrodingerSentence = (
            ((nextMoveText == "Unknown") || !blackSchrodingerDiffer || blackSchrodingerDiffText.isEmpty) ? "" :
                " \(blackSchrodingerDiffText)."
        )

        let nextWhiteSchrodingerText = gameRecord.getWhiteSchrodingerStones(nextIndex) ?? "Unknown"
        let bestWhiteSchrodingerText = gameRecord.getWhiteSchrodingerStones(currentIndex) ?? "Unknown"
        let whiteSchrodingerDiffer = (nextWhiteSchrodingerText != bestWhiteSchrodingerText) && (bestWhiteSchrodingerText != "Unknown")

        let whiteSchrodingerDiffText = whiteSchrodingerDiffer ? formatSchrodingerStonesDiff(
            current: bestWhiteSchrodingerText,
            next: nextWhiteSchrodingerText,
            color: .white
        ) : ""

        let nextWhiteSchrodingerSentence = (
            ((nextMoveText == "Unknown") || !whiteSchrodingerDiffer || whiteSchrodingerDiffText.isEmpty) ? "" :
                " \(whiteSchrodingerDiffText)."
        )

        let bestMoveSentence = (
            bestMoveDiffer ? " KataGo AI recommends \(colorToPlay) to play at \(bestMoveText)." :
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
            current: nextDeadBlackStonesText,
            next: bestDeadBlackStonesText,
            color: .black
        ) : ""

        let bestDeadBlackStonesSentence = (
            (!deadBlackStonesDiffer || !bestMoveDiffer || bestDeadBlackStonesDiffText.isEmpty) ? "" :
                " If \(colorToPlay) plays the recommended move, \(bestDeadBlackStonesDiffText)."
        )

        let bestDeadWhiteStonesDiffText = deadWhiteStonesDiffer ? formatDeadStonesDiff(
            current: nextDeadWhiteStonesText,
            next: bestDeadWhiteStonesText,
            color: .white
        ) : ""

        let bestDeadWhiteStonesSentence = (
            (!deadWhiteStonesDiffer || !bestMoveDiffer || bestDeadWhiteStonesDiffText.isEmpty) ? "" :
                " If \(colorToPlay) plays the recommended move, \(bestDeadWhiteStonesDiffText)."
        )

        let bestEndangeredBlackStonesDiffText = endangeredBlackStonesDiffer ? formatEndangeredStonesDiff(
            current: nextEndangeredBlackStonesText,
            next: bestEndangeredBlackStonesText,
            color: .black
        ) : ""
        
        let bestEndangeredBlackSentence = (
            (!endangeredBlackStonesDiffer || !bestMoveDiffer || bestEndangeredBlackStonesDiffText.isEmpty) ? "" :
                " If \(colorToPlay) plays the recommended move, \(bestEndangeredBlackStonesDiffText)."
        )
        
        let bestEndangeredWhiteStonesDiffText = endangeredWhiteStonesDiffer ? formatEndangeredStonesDiff(
            current: nextEndangeredWhiteStonesText,
            next: bestEndangeredWhiteStonesText,
            color: .white
        ) : ""
        
        let bestEndangeredWhiteSentence = (
            (!endangeredWhiteStonesDiffer || !bestMoveDiffer || bestEndangeredWhiteStonesDiffText.isEmpty) ? "" :
                " If \(colorToPlay) plays the recommended move, \(bestEndangeredWhiteStonesDiffText)."
        )

        let bestBlackSchrodingerDiffText = blackSchrodingerDiffer ? formatSchrodingerStonesDiff(
            current: nextBlackSchrodingerText,
            next: bestBlackSchrodingerText,
            color: .black
        ) : ""

        let bestBlackSchrodingerSentence = (
            (!blackSchrodingerDiffer || !bestMoveDiffer || bestBlackSchrodingerDiffText.isEmpty) ? "" :
                " \(bestBlackSchrodingerDiffText)."
        )

        let bestWhiteSchrodingerDiffText = whiteSchrodingerDiffer ? formatSchrodingerStonesDiff(
            current: nextWhiteSchrodingerText,
            next: bestWhiteSchrodingerText,
            color: .white
        ) : ""

        let bestWhiteSchrodingerSentence = (
            (!whiteSchrodingerDiffer || !bestMoveDiffer || bestWhiteSchrodingerDiffText.isEmpty) ? "" :
                " \(bestWhiteSchrodingerDiffText)."
        )

        var comment: String

        if currentIndex >= 1 {
            comment =
"""
\(colorPlayed) number \(currentIndex) plays a stone at \(lastMoveText).\(colorToPlaySentence)\(nextWinrateSentence)\(nextScoreSentence)\(nextDeadBlackStonesSentence)\(nextDeadWhiteStonesSentence)\(nextEndangeredBlackSentence)\(nextEndangeredWhiteSentence)\(nextBlackSchrodingerSentence)\(nextWhiteSchrodingerSentence)\(bestMoveSentence)\(bestWinrateSentence)\(bestScoreSentence)\(bestDeadBlackStonesSentence)\(bestDeadWhiteStonesSentence)\(bestEndangeredBlackSentence)\(bestEndangeredWhiteSentence)\(bestBlackSchrodingerSentence)\(bestWhiteSchrodingerSentence)
"""
        } else {
            comment =
"""
Game starts.\(colorToPlaySentence)\(nextWinrateSentence)\(nextScoreSentence)\(nextDeadBlackStonesSentence)\(nextDeadWhiteStonesSentence)\(nextEndangeredBlackSentence)\(nextEndangeredWhiteSentence)\(nextBlackSchrodingerSentence)\(nextWhiteSchrodingerSentence)\(bestMoveSentence)\(bestWinrateSentence)\(bestScoreSentence)\(bestDeadBlackStonesSentence)\(bestDeadWhiteStonesSentence)\(bestEndangeredBlackSentence)\(bestEndangeredWhiteSentence)\(bestBlackSchrodingerSentence)\(bestWhiteSchrodingerSentence)
"""
        }

        return comment
    }

    private func generateLastMoveText() -> String {
        guard gameRecord.currentIndex >= 1 else { return "None" }
        let lastMove = gameRecord.moves?[gameRecord.currentIndex - 1] ?? "Unknown"
        return lastMove
    }

    private func stonesDiff(current: String?, next: String?) -> [String] {
        guard let current, let next, current != next else { return [] }
        let currentSet = Set(current.split(separator: " ").map(String.init))
        let nextSet = Set(next.split(separator: " ").map(String.init))
        let diff = nextSet.subtracting(currentSet).filter { $0 != "Unknown" }
        return diff.sorted()
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
        let deadStones = stonesDiff(current: current, next: next)
        guard !deadStones.isEmpty else { return "" }
        let stonesString = deadStones.joined(separator: " ")

        let deadStonesDiffText = (
            stonesString == "None" ? "None of \(color.name) stones are completely dead" :
                "\(color.name) \(stonesString) are completely dead"
        )

        return deadStonesDiffText
    }

    private func formatSchrodingerStonesDiff(
        current: String?,
        next: String?,
        color: PlayerColor
    ) -> String {
        let schrodingerStones = stonesDiff(current: current, next: next)
        guard !schrodingerStones.isEmpty else { return "" }
        let stonesString = schrodingerStones.joined(separator: " ")
        
        let schrodingerStonesDiffText = (
            stonesString == "None" ? "" :
                "\(color.name) \(stonesString) are exchangeable, allowing both players gain points in different areas on the board, resulting in a locally balanced trade-off"
        )

        return schrodingerStonesDiffText
    }

    private func formatEndangeredStonesDiff(
        current: String?,
        next: String?,
        color: PlayerColor
    ) -> String {
        let endangeredStones = stonesDiff(current: current, next: next)
        guard !endangeredStones.isEmpty else { return "" }
        let stonesString = endangeredStones.joined(separator: " ")

        let endangeredStonesDiffText = (
            stonesString == "None" ? "" :
                "\(color.name) \(stonesString) are sacrificeable, allowing to be captured to gain a greater advantage elsewhere on the board"
        )

        return endangeredStonesDiffText
    }
}

@Generable
struct CommentText {
    @Guide(description: "The improved Go commentary in single paragraph.")
    let description: String
}
