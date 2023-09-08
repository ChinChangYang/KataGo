//
//  AnalysisView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/7.
//

import SwiftUI

struct AnalysisView: View {
    @EnvironmentObject var analysis: Analysis
    let dimensions: Dimensions

    var body: some View {
        let maxVisits = computeMaxVisits()

        ForEach(analysis.data, id: \.self) { data in
            if let move = data["move"] {
                if let point = moveToPoint(move: move) {
                    // Shadow
                    Circle()
                        .stroke(Color.black.opacity(0.5), lineWidth: dimensions.squareLength / 32)
                        .blur(radius: dimensions.squareLength / 32)
                        .frame(width: dimensions.squareLength, height: dimensions.squareLength)
                        .position(x: dimensions.marginWidth + CGFloat(point.x) * dimensions.squareLength,
                                  y: dimensions.marginHeight + CGFloat(point.y) * dimensions.squareLength)
                }
            }
        }

        ForEach(analysis.data, id: \.self) { data in
            if let move = data["move"] {
                if let point = moveToPoint(move: move) {
                    let winrate = Float(data["winrate"] ?? "0") ?? 0
                    let visits = Int(data["visits"] ?? "0") ?? 0
                    let isHidden = Float(visits) < (0.1 * Float(maxVisits))
                    let color = computeColorByVisits(isHidden: isHidden, visits: visits, maxVisits: maxVisits)

                    ZStack {
                        Circle()
                            .foregroundColor(color)
                        if !isHidden {
                            VStack {
                                Text(String(format: "%2.0f%%", winrate * 100))
                                    .font(.system(size: 500))
                                    .minimumScaleFactor(0.01)
                                    .bold()

                                Text(convertToSIUnits(visits))
                                    .font(.system(size: 500))
                                    .minimumScaleFactor(0.01)

                                if let scoreLead = data["scoreLead"] {
                                    let text = String(format: "%+.1f", (Float(scoreLead) ?? 0))
                                    Text(text)
                                        .font(.system(size: 500))
                                        .minimumScaleFactor(0.01)
                                }
                            }
                        }
                    }
                    .frame(width: dimensions.squareLength, height: dimensions.squareLength)
                    .position(x: dimensions.marginWidth + CGFloat(point.x) * dimensions.squareLength,
                              y: dimensions.marginHeight + CGFloat(point.y) * dimensions.squareLength)
                }
            }
        }
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

    func computeColorByWinrate(isHidden: Bool, winrate: Float, minWinrate: Float, maxWinrate: Float) -> Color {
        let opacity = isHidden ? 0.1 : 0.5

        if winrate == maxWinrate {
            return .cyan.opacity(opacity)
        } else {
            let ratio = min(1, max(0.01, winrate - minWinrate) / max(0.01, maxWinrate - minWinrate))

            let fraction = 2 / (pow((1 / ratio) - 1, 0.9) + 1)

            if fraction < 1 {
                let hue = cbrt(fraction * fraction) / 2
                return Color(hue: Double(hue) / 2, saturation: 1, brightness: 1).opacity(opacity)
            } else {
                let hue = 1 - (sqrt(2 - fraction) / 2)
                return Color(hue: Double(hue) / 2, saturation: 1, brightness: 1).opacity(opacity)
            }
        }
    }

    func computeBaseColorByVisits(visits: Int, maxVisits: Int) -> Color {
        if visits == maxVisits {
            return Color(red: 0, green: 1, blue: 1)
        } else {
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
    }

    func computeColorByVisits(isHidden: Bool, visits: Int, maxVisits: Int) -> Color {
        let baseColor = computeBaseColorByVisits(visits: visits, maxVisits: maxVisits)
        let opacity = isHidden ? 0.2 : 0.8
        return baseColor.opacity(opacity)
    }

    func computeMinMaxWinrate() -> (Float, Float) {
        let winrates = analysis.data.map() { data in
            Float(data["winrate"] ?? "0") ?? 0
        }

        let minWinrate = winrates.reduce(1) {
            min($0, $1)
        }

        let maxWinrate = winrates.reduce(0) {
            max($0, $1)
        }

        return (minWinrate, maxWinrate)
    }

    func computeMaxVisits() -> Int {
        let allVisits = analysis.data.map() { data in
            Int(data["visits"] ?? "0") ?? 0
        }

        let maxVisits = allVisits.reduce(0) {
            max($0, $1)
        }

        return maxVisits
    }

    func moveToPoint(move: String) -> BoardPoint? {
        // Mapping letters A-T (without I) to numbers 0-18
        let letterMap: [Character: Int] = [
            "A": 0, "B": 1, "C": 2, "D": 3, "E": 4,
            "F": 5, "G": 6, "H": 7, "J": 8, "K": 9,
            "L": 10, "M": 11, "N": 12, "O": 13, "P": 14,
            "Q": 15, "R": 16, "S": 17, "T": 18
        ]

        let letterPart = move.prefix(1)
        let numberPart = move.dropFirst()

        if let x = letterMap[Character(letterPart.uppercased())],
           let y = Int(numberPart) {
            return BoardPoint(x: x, y: y - 1)  // Subtract 1 from y to make it 0-indexed
        } else {
            return nil
        }
    }
}

struct AnalysisView_Previews: PreviewProvider {
    static let analysis = Analysis()
    static var previews: some View {
        ZStack {
            Rectangle()
                .foregroundColor(.brown)

            GeometryReader { geometry in
                let boardSpace: CGFloat = 20
                let width: CGFloat = 2
                let height: CGFloat = 2
                let totalWidth = geometry.size.width
                let totalHeight = geometry.size.height
                let squareWidth = (totalWidth - boardSpace) / (width + 1)
                let squareHeight = (totalHeight - boardSpace) / (height + 1)
                let squareLength = min(squareWidth, squareHeight)
                let boardWidth = width * squareLength
                let boardHeight = height * squareLength
                let marginWidth = (totalWidth - boardWidth + squareLength) / 2
                let marginHeight = (totalHeight - boardHeight + squareLength) / 2
                let dimensions = Dimensions(squareLength: squareLength, boardWidth: boardWidth, boardHeight: boardHeight, marginWidth: marginWidth, marginHeight: marginHeight)

                AnalysisView(dimensions: dimensions)
            }
            .environmentObject(analysis)
            .onAppear() {
                AnalysisView_Previews.analysis.data = [["move": "A1", "winrate": "0.54321012345", "scoreLead": "0.123456789", "order": "0", "visits": "12345678"], ["move": "B1", "winrate": "0.4", "scoreLead": "-9.8", "order": "1", "visits": "2345678"], ["move": "A2", "winrate": "0.321", "scoreLead": "-12.345", "order": "2", "visits": "198"]]
            }
        }
    }
}
