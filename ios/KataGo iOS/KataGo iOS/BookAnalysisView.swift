//
//  BookAnalysisView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2026/3/2.
//

import SwiftUI
import KataGoUICore

struct BookAnalysisView: View {
    @Environment(BookLookup.self) var bookLookup
    @Environment(GobanState.self) var gobanState
    @Environment(Stones.self) var stones
    @Environment(BoardSize.self) var board
    var config: Config
    let dimensions: Dimensions

    var body: some View {
        if gobanState.eyeStatus == .book && bookLookup.isInBook && !gobanState.isAutoPlaying {
            let analysis = bookLookup.getBookAnalysis(
                boardWidth: Int(board.width),
                boardHeight: Int(board.height)
            )
            let blackSet = Set(stones.blackPoints)
            let whiteSet = Set(stones.whitePoints)
            let sortedPoints = analysis.keys.sorted()

            // Get best move info for badness comparison
            let bestMoveInfo = analysis.values.first(where: { $0.rank == 0 })

            ForEach(sortedPoints, id: \.self) { point in
                if !blackSet.contains(point) && !whiteSet.contains(point),
                   (!point.isPass(width: Int(dimensions.width), height: Int(dimensions.height)) || gobanState.showPass),
                   let info = analysis[point] {
                    let color = badnessColor(
                        info: info,
                        bestInfo: bestMoveInfo,
                        nextPlayer: bookLookup.currentNextPlayer ?? 1
                    )

                    ZStack {
                        Circle()
                            .foregroundStyle(color.opacity(0.8))
                            .overlay {
                                if info.rank == 0 {
                                    Circle()
                                        .stroke(.blue, lineWidth: dimensions.squareLengthDiv16)
                                }
                            }

                        if !gobanState.isAnalysisInformationNone {
                            moveText(info: info, nextPlayer: bookLookup.currentNextPlayer ?? 1)
                        }
                    }
#if !os(macOS)
                    .hoverEffect()
#endif
                    .frame(width: dimensions.squareLength, height: dimensions.squareLength)
                    .position(
                        x: dimensions.boardLineStartX + CGFloat(point.x) * dimensions.squareLength,
                        y: dimensions.boardLineStartY + point.getPositionY(
                            height: dimensions.height,
                            verticalFlip: gobanState.verticalFlip
                        ) * dimensions.squareLength
                    )
                }
            }
        }
    }

    // MARK: - Text formatting

    @ViewBuilder
    func moveText(info: BookMoveInfo, nextPlayer: Int) -> some View {
        let winrate = currentPlayerWinrate(wl: info.winLoss, nextPlayer: nextPlayer)
        let scoreLead = currentPlayerScore(ss: info.sharpScore, nextPlayer: nextPlayer)
        let visits = Int(info.adjustedVisits)

        if gobanState.isAnalysisInformationWinrate {
            winrateText(winrate)
        } else if gobanState.isAnalysisInformationScore {
            scoreText(scoreLead)
        } else if gobanState.isAnalysisInformationAll {
            VStack {
                winrateText(winrate)
                visitsText(visits)
                scoreText(scoreLead)
            }
        }
    }

    // MARK: - Value conversion

    /// Convert book winLoss to current player's winrate (0-1).
    /// Book wl: positive = good for white, negative = good for black.
    func currentPlayerWinrate(wl: Double, nextPlayer: Int) -> Float {
        let blackWinrate = (1.0 - wl) / 2.0
        return Float(nextPlayer == 1 ? blackWinrate : 1.0 - blackWinrate)
    }

    /// Convert book sharpScore to current player's score lead.
    /// Book ss: positive = good for white, negative = good for black.
    func currentPlayerScore(ss: Double, nextPlayer: Int) -> Float {
        let blackScore = -ss
        return Float(nextPlayer == 1 ? blackScore : -blackScore)
    }

    // MARK: - Badness color (ported from book.js)

    /// Color interpolation table from book.js
    static let badnessColorStops: [(threshold: Double, rgb: (Double, Double, Double))] = [
        (0.00, (100, 255, 245)),  // cyan-green (best)
        (0.12, (120, 235, 130)),  // green
        (0.30, (205, 235, 60)),   // yellow-green
        (0.70, (255, 100, 0)),    // orange
        (1.00, (200, 0, 0)),      // red
        (2.00, (50, 0, 0)),       // dark red (worst)
    ]

    func badnessColor(info: BookMoveInfo, bestInfo: BookMoveInfo?, nextPlayer: Int) -> Color {
        guard let best = bestInfo else { return .gray }

        let sign = Double(nextPlayer == 1 ? 1 : -1)
        let winLossDiff = sign * (info.winLoss - best.winLoss)
        let scoreDiff = sign * (info.sharpScore - best.sharpScore)
        let sqrtPolicyDiff = sqrt(info.policyPrior) - sqrt(best.policyPrior)

        let scoreDiffScaled: Double
        if scoreDiff < 0 {
            scoreDiffScaled = scoreDiff
        } else {
            scoreDiffScaled = sqrt(8.0 * scoreDiff + 16.0) - 4.0
        }

        var adjustedScoreDiff = scoreDiffScaled
        if adjustedScoreDiff < 0 && winLossDiff > 0 {
            adjustedScoreDiff = max(adjustedScoreDiff, -0.2 / winLossDiff)
        }

        var x = winLossDiff * 0.8 + adjustedScoreDiff * 0.1 - 0.05 * sqrtPolicyDiff
        let losingness = max(0.0, sign * 0.5 * best.winLoss)
        x += losingness * 0.6 + (x * 1.25 * losingness)

        return interpolateBadnessColor(x)
    }

    private func interpolateBadnessColor(_ x: Double) -> Color {
        let stops = Self.badnessColorStops

        for i in 0..<stops.count {
            let (x1, c1) = stops[i]
            if x < x1 {
                if i == 0 {
                    return Color(
                        red: c1.0 / 255.0,
                        green: c1.1 / 255.0,
                        blue: c1.2 / 255.0
                    )
                }
                let (x0, c0) = stops[i - 1]
                let interp = (x - x0) / (x1 - x0)
                return Color(
                    red: (c0.0 + (c1.0 - c0.0) * interp) / 255.0,
                    green: (c0.1 + (c1.1 - c0.1) * interp) / 255.0,
                    blue: (c0.2 + (c1.2 - c0.2) * interp) / 255.0
                )
            }
        }

        let last = stops.last!.rgb
        return Color(red: last.0 / 255.0, green: last.1 / 255.0, blue: last.2 / 255.0)
    }
}
