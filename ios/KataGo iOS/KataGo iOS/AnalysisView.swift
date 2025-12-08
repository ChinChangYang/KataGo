//
//  AnalysisView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/7.
//

import SwiftUI
import KataGoInterface

struct AnalysisView: View {
    @Environment(Analysis.self) var analysis
    @Environment(GobanState.self) var gobanState
    @Environment(Stones.self) var stones
    @Environment(Turn.self) var player
    var config: Config
    let dimensions: Dimensions

    private func isValidPointToShow(blackSet: Set<BoardPoint>,
                                    whiteSet: Set<BoardPoint>,
                                    point: BoardPoint) -> Bool {
        return !blackSet.contains(point) && !whiteSet.contains(point) && (!point.isPass(width: Int(dimensions.width), height: Int(dimensions.height)) || config.showPass)
    }

    func shadows(blackSet: Set<BoardPoint>,
                 whiteSet: Set<BoardPoint>,
                 sortedInfoKeys: [BoardPoint]) -> some View {
        return ForEach(sortedInfoKeys, id: \.self) { point in
            if isValidPointToShow(blackSet: blackSet, whiteSet: whiteSet, point: point) {
                // Shadow
                Circle()
                    .stroke(Color.black.opacity(0.5), lineWidth: dimensions.squareLength / 32)
                    .blur(radius: dimensions.squareLength / 32)
                    .frame(width: dimensions.squareLength, height: dimensions.squareLength)
                    .position(x: dimensions.boardLineStartX + CGFloat(point.x) * dimensions.squareLength,
                              y: dimensions.boardLineStartY + point.getPositionY(height: dimensions.height, verticalFlip: config.verticalFlip) * dimensions.squareLength)
            }
        }
    }

    var ownerships: some View {
        return ForEach(analysis.ownershipUnits) { unit in
            Rectangle()
#if !os(macOS)
                .hoverEffect()
#endif
                .foregroundStyle(Color(hue: 0, saturation: 0, brightness: Double(unit.whiteness)).opacity(Double(unit.opacity)))
                .frame(width: dimensions.squareLength * CGFloat(unit.scale), height: dimensions.squareLength * CGFloat(unit.scale))
                .position(x: dimensions.boardLineStartX + CGFloat(unit.point.x) * dimensions.squareLength,
                          y: dimensions.boardLineStartY + unit.point.getPositionY(height: dimensions.height, verticalFlip: config.verticalFlip) * dimensions.squareLength)
        }
    }

    func moves(blackSet: Set<BoardPoint>,
               whiteSet: Set<BoardPoint>,
               sortedInfoKeys: [BoardPoint]) -> some View {
        let maxVisits = computeMaxVisits(sortedInfoKeys: sortedInfoKeys)
        let maxUtility = computeMaxUtilityLcb(sortedInfoKeys: sortedInfoKeys)

        return ForEach(sortedInfoKeys, id: \.self) { point in
            if isValidPointToShow(blackSet: blackSet, whiteSet: whiteSet, point: point) {
                if let info = analysis.info[point] {
                    let isHidden = Float(info.visits) < (config.hiddenAnalysisVisitRatio * Float(maxVisits))
                    let color = computeColorByVisits(isHidden: isHidden, visits: info.visits, maxVisits: maxVisits)

                    ZStack {
                        Circle()
                            .foregroundStyle(color)
                            .overlay {
                                if info.utilityLcb == maxUtility {
                                    Circle()
                                        .stroke(.blue, lineWidth: dimensions.squareLengthDiv16)
                                }
                            }
                        if !isHidden {
                            if config.isAnalysisInformationWinrate {
                                winrateText(info.winrate)
                            } else if config.isAnalysisInformationScore {
                                scoreText(info.scoreLead)
                            } else if config.isAnalysisInformationAll {
                                VStack {
                                    winrateText(info.winrate)
                                    visitsText(info.visits)
                                    scoreText(info.scoreLead)
                                }
                            }
                        }
                    }
#if !os(macOS)
                    .hoverEffect()
#endif
                    .frame(width: dimensions.squareLength, height: dimensions.squareLength)
                    .position(x: dimensions.boardLineStartX + CGFloat(point.x) * dimensions.squareLength,
                              y: dimensions.boardLineStartY + point.getPositionY(height: dimensions.height, verticalFlip: config.verticalFlip) * dimensions.squareLength)
                }
            }
        }
    }

    var body: some View {
        if gobanState.shouldRequestAnalysis(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand) &&
            (gobanState.eyeStatus == .opened) &&
            (!gobanState.isAutoPlaying) {
            Group {
                let blackSet = Set(stones.blackPoints)
                let whiteSet = Set(stones.whitePoints)
                let sortedInfoKeys = analysis.info.keys.sorted()

                if !config.isAnalysisInformationNone && config.isClassicAnalysisStyle {
                    shadows(blackSet: blackSet, whiteSet: whiteSet, sortedInfoKeys: sortedInfoKeys)
                }

                if config.showOwnership {
                    ownerships
                }

                if !config.isAnalysisInformationNone {
                    moves(blackSet: blackSet, whiteSet: whiteSet, sortedInfoKeys: sortedInfoKeys)
                }
            }
            .onAppear() {
                if gobanState.requestingClearAnalysis {
                    analysis.clear()
                    gobanState.requestingClearAnalysis = false
                }
            }
        }
    }

    func winrateText(_ winrate: Float) -> some View {
        return Text(String(format: "%2.0f%%", (winrate * 100).rounded()))
            .contentTransition(.numericText())
            .font(.system(size: 500, design: .monospaced))
            .minimumScaleFactor(0.01)
            .bold()
            .foregroundStyle(.black)
    }

    func visitsText(_ visits: Int) -> some View {
        return Text(convertToSIUnits(visits))
            .contentTransition(.numericText())
            .font(.system(size: 500, design: .monospaced))
            .minimumScaleFactor(0.01)
            .foregroundStyle(.black)
    }

    func scoreText(_ scoreLead: Float) -> some View {
        let text = String(format: "%+.0f", scoreLead.rounded())

        return Text(text)
            .contentTransition(.numericText())
            .font(.system(size: 500, design: .monospaced))
            .minimumScaleFactor(0.01)
            .foregroundStyle(.black)
    }

    func convertToSIUnits(_ number: Int) -> String {
        let prefixes: [(prefix: String, value: Int)] = [
            ("T", 1_000_000_000_000),   // Tera
            ("G", 1_000_000_000),      // Giga
            ("M", 1_000_000),          // Mega
            ("k", 1_000)               // Kilo
        ]

        var result = Double(number)

        for (prefix, threshold) in prefixes {
            if number >= threshold {
                result = Double(number) / Double(threshold)
                return String(format: "%.1f%@", result, prefix)
            }
        }

        return "\(number)"
    }

    func computeBaseColorByVisits(visits: Int, maxVisits: Int) -> Color {
        let ratio = min(1, max(0.01, Float(visits)) / max(0.01, Float(maxVisits)))
        let fraction = 2 / (pow((1 / ratio) - 1, 0.9) + 1)
        var hue: Float

        if fraction < 1 {
            hue = cbrt(fraction * fraction) / 2
        } else {
            hue = 1 - (sqrt(2 - fraction) / 2)
        }

        // discrete for performance
        let digit: Float = 10
        let discretedHue = (hue * digit).rounded() / digit

        return Color(
            hue: Double(discretedHue) / 2,
            saturation: 1,
            brightness: 1
        )
    }

    func computeColorByVisits(isHidden: Bool, visits: Int, maxVisits: Int) -> Color {
        let baseColor = computeBaseColorByVisits(visits: visits, maxVisits: maxVisits)
        let opacity = isHidden ? 0.2 : 0.8
        return baseColor.opacity(opacity)
    }

    func computeMaxUtilityLcb(sortedInfoKeys: [BoardPoint]) -> Float {
        let utilityLcbs = sortedInfoKeys.map { point in
            analysis.info[point]?.utilityLcb ?? 0
        }

        let maxUtilityLcb = utilityLcbs.reduce(-Float.infinity) {
            max($0, $1)
        }

        return maxUtilityLcb
    }

    func computeMaxVisits(sortedInfoKeys: [BoardPoint]) -> Int {
        let visits = sortedInfoKeys.map { point in
            analysis.info[point]?.visits ?? 0
        }

        let maxVisits = visits.reduce(0) {
            max($0, $1)
        }

        return maxVisits
    }
}
