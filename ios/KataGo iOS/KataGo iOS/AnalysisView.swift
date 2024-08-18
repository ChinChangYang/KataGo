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
    var config: Config
    let dimensions: Dimensions

    var shadows: some View {
        let sortedInfoKeys = analysis.info.keys.sorted()

        return ForEach(sortedInfoKeys, id: \.self) { point in
            // Shadow
            Circle()
                .stroke(Color.black.opacity(0.5), lineWidth: dimensions.squareLength / 32)
                .blur(radius: dimensions.squareLength / 32)
                .frame(width: dimensions.squareLength, height: dimensions.squareLength)
                .position(x: dimensions.boardLineStartX + CGFloat(point.x) * dimensions.squareLength,
                          y: dimensions.boardLineStartY + CGFloat(point.y) * dimensions.squareLength)
        }
    }

    func computeDefiniteness(_ whiteness: Double) -> Double {
        return Swift.abs(whiteness - 0.5) * 2
    }

    var ownerships: some View {
        let sortedOwnershipKeys = analysis.ownership.keys.sorted()

        return ForEach(sortedOwnershipKeys, id: \.self) { point in
            if let ownership = analysis.ownership[point] {
                let whiteness = (analysis.nextColorForAnalysis == .white) ? (Double(ownership.mean) + 1) / 2 : (Double(-ownership.mean) + 1) / 2
                let definiteness = computeDefiniteness(whiteness)
                // Show a black or white square if definiteness is high and stdev is low
                // Show nothing if definiteness is low and stdev is low
                // Show a square with linear gradient of black and white if definiteness is low and stdev is high
                let scale = max(CGFloat(definiteness), CGFloat(ownership.stdev ?? 0)) * 0.7

                Rectangle()
                    .foregroundColor(Color(hue: 0, saturation: 0, brightness: whiteness).opacity(0.8))
                    .frame(width: dimensions.squareLength * scale, height: dimensions.squareLength * scale)
                    .position(x: dimensions.boardLineStartX + CGFloat(point.x) * dimensions.squareLength,
                              y: dimensions.boardLineStartY + CGFloat(point.y) * dimensions.squareLength)
            }
        }
    }

    var moves: some View {
        let maxVisits = computeMaxVisits()
        let maxUtility = computeMaxUtilityLcb()
        let sortedInfoKeys = analysis.info.keys.sorted()

        return ForEach(sortedInfoKeys, id: \.self) { point in
            if let info = analysis.info[point] {
                let isHidden = Float(info.visits) < (config.hiddenAnalysisVisitRatio * Float(maxVisits))
                let color = computeColorByVisits(isHidden: isHidden, visits: info.visits, maxVisits: maxVisits)

                ZStack {
                    Circle()
                        .foregroundColor(color)
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
                        } else {
                            VStack {
                                winrateText(info.winrate)
                                visitsText(info.visits)
                                scoreText(info.scoreLead)
                            }
                        }
                    }
                }
                .frame(width: dimensions.squareLength, height: dimensions.squareLength)
                .position(x: dimensions.boardLineStartX + CGFloat(point.x) * dimensions.squareLength,
                          y: dimensions.boardLineStartY + CGFloat(point.y) * dimensions.squareLength)
            }
        }
    }

    var body: some View {
        Group {
            shadows

            if config.showOwnership {
                ownerships
            }

            moves
        }
        .onAppear() {
            if gobanState.requestingClearAnalysis {
                analysis.clear()
                gobanState.requestingClearAnalysis = false
            }
        }
    }

    func winrateText(_ winrate: Float) -> some View {
        return Text(String(format: "%2.0f%%", (winrate * 100).rounded()))
            .font(.system(size: 500, design: .monospaced))
            .minimumScaleFactor(0.01)
            .bold()
            .foregroundColor(.black)
    }

    func visitsText(_ visits: Int) -> some View {
        return Text(convertToSIUnits(visits))
            .font(.system(size: 500, design: .monospaced))
            .minimumScaleFactor(0.01)
            .foregroundColor(.black)
    }

    func scoreText(_ scoreLead: Float) -> some View {
        let text = String(format: "%+.0f", scoreLead.rounded())

        return Text(text)
            .font(.system(size: 500, design: .monospaced))
            .minimumScaleFactor(0.01)
            .foregroundColor(.black)
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

        if fraction < 1 {
            let hue = cbrt(fraction * fraction) / 2
            return Color(hue: Double(hue) / 2, saturation: 1, brightness: 1)
        } else {
            let hue = 1 - (sqrt(2 - fraction) / 2)
            return Color(hue: Double(hue) / 2, saturation: 1, brightness: 1)
        }

    }

    func computeColorByVisits(isHidden: Bool, visits: Int, maxVisits: Int) -> Color {
        let baseColor = computeBaseColorByVisits(visits: visits, maxVisits: maxVisits)
        let opacity = isHidden ? 0.2 : 0.8
        return baseColor.opacity(opacity)
    }

    func computeMinMaxWinrate() -> (Float, Float) {
        let points = analysis.info.keys.sorted()

        let winrates = points.map { point in
            analysis.info[point]?.winrate ?? 0.5
        }

        let minWinrate = winrates.reduce(1) {
            min($0, $1)
        }

        let maxWinrate = winrates.reduce(0) {
            max($0, $1)
        }

        return (minWinrate, maxWinrate)
    }

    func computeMaxUtilityLcb() -> Float {
        let points = analysis.info.keys.sorted()

        let utilityLcbs = points.map { point in
            analysis.info[point]?.utilityLcb ?? 0
        }

        let maxUtilityLcb = utilityLcbs.reduce(-Float.infinity) {
            max($0, $1)
        }

        return maxUtilityLcb
    }

    func computeMaxVisits() -> Int {
        let points = analysis.info.keys.sorted()

        let visits = points.map { point in
            analysis.info[point]?.visits ?? 0
        }

        let maxVisits = visits.reduce(0) {
            max($0, $1)
        }

        return maxVisits
    }
}
