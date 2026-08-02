//
//  WatchStoredAnalysis.swift
//  KataGoGameStore
//
//  What a saved game already knows about one position. The phone fills these
//  per-move dictionaries as it analyzes, so coverage is whatever the user
//  actually looked at — every field is independently optional and an absent
//  one must be HIDDEN, not zeroed. The watch computes nothing.
//

import Foundation

public struct WatchStoredAnalysis: Equatable, Sendable {
    public var winrateBlack: Float?
    public var scoreLeadBlack: Float?
    public var bestMove: String?
    public var comment: String?

    public init(winrateBlack: Float?, scoreLeadBlack: Float?,
                bestMove: String?, comment: String?) {
        self.winrateBlack = winrateBlack
        self.scoreLeadBlack = scoreLeadBlack
        self.bestMove = bestMove
        self.comment = comment
    }

    public static func at(index: Int,
                          winRates: [Int: Float]?,
                          scoreLeads: [Int: Float]?,
                          bestMoves: [Int: String]?,
                          comments: [Int: String]?) -> WatchStoredAnalysis {
        WatchStoredAnalysis(
            winrateBlack: winRates?[index],
            scoreLeadBlack: scoreLeads?[index],
            bestMove: bestMoves?[index].flatMap(nonBlank),
            comment: comments?[index].flatMap(nonBlank))
    }

    private static func nonBlank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
