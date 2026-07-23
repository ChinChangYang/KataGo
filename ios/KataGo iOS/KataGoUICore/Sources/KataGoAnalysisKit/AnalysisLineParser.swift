//
//  AnalysisLineParser.swift
//  KataGo iOS
//

import Foundation

/// The analysis state parsed from one `kata-analyze` output message.
public struct ParsedAnalysis {
    public let info: [BoardPoint: AnalysisInfo]
    public let ownershipUnits: [OwnershipUnit]
    /// Undigitized root ownership means as emitted by the engine (White-positive
    /// under the shipped `reportAnalysisWinratesAs = WHITE` cfg). NEVER flipped
    /// by `nextColor` — consumers needing another perspective convert themselves.
    /// Empty when the message carries no root ownership grid.
    public let rawOwnership: [Float]
    /// The `rootInfo` block's search totals, if present. `winrate`/`scoreLead`
    /// follow the same perspective flip as the per-candidate fields.
    public let rootInfo: ParsedRootInfo?
}

/// Root-level search values from a kata-analyze `rootInfo` block.
public struct ParsedRootInfo {
    public let visits: Int
    public let winrate: Float
    public let scoreLead: Float
}

/// Pure parser for `kata-analyze` lines. Behavior matches the previous
/// ContentView analysis helpers. `nextColor` is `player.nextColorFromShowBoard`;
/// winrate/scoreLead/utilityLcb are flipped to Black's perspective when it is
/// Black to move.
public struct AnalysisLineParser {
    let boardWidth: Int
    let boardHeight: Int
    let nextColor: PlayerColor

    public init(boardWidth: Int, boardHeight: Int, nextColor: PlayerColor) {
        self.boardWidth = boardWidth
        self.boardHeight = boardHeight
        self.nextColor = nextColor
    }

    public func parse(message: String) -> ParsedAnalysis {
        let splitData = message.split(separator: "info")
        let infoDicts = splitData.compactMap { extractAnalysisInfo(dataLine: String($0)) }
        let info = infoDicts.reduce(into: [BoardPoint: AnalysisInfo]()) { acc, dict in
            acc.merge(dict) { current, _ in current }   // first wins on collision
        }
        let lastMessage = splitData.last.map(String.init) ?? ""
        let rawOwnership = extractOwnershipMean(message: lastMessage)
        let ownershipUnits = extractOwnershipUnits(lastData: splitData.last)
        return ParsedAnalysis(info: info,
                              ownershipUnits: ownershipUnits,
                              rawOwnership: rawOwnership,
                              rootInfo: extractRootInfo(message: message))
    }

    // MARK: - Analysis info

    private func extractAnalysisInfo(dataLine: String) -> [BoardPoint: AnalysisInfo]? {
        let point = matchMovePattern(dataLine: dataLine)
        let visits = matchVisitsPattern(dataLine: dataLine)
        let winrate = matchWinratePattern(dataLine: dataLine)
        let scoreLead = matchScoreLeadPattern(dataLine: dataLine)
        let utilityLcb = matchUtilityLcbPattern(dataLine: dataLine)

        if let point, let visits, let winrate, let scoreLead, let utilityLcb {
            // Winrate is 0.5 when visits = 0; skip those to keep the win-rate bar stable.
            guard visits > 0 || winrate != 0.5 else { return nil }
            return [point: AnalysisInfo(visits: visits,
                                        winrate: winrate,
                                        scoreLead: scoreLead,
                                        utilityLcb: utilityLcb,
                                        pv: extractPV(dataLine: dataLine),
                                        movesOwnership: extractMovesOwnership(dataLine: dataLine))]
        }
        return nil
    }

    private func moveToPoint(move: String) -> BoardPoint? {
        let pattern = /([^\d\W]+)(\d+)/
        if let match = move.firstMatch(of: pattern),
           let coordinate = Coordinate(xLabel: String(match.1),
                                       yLabel: String(match.2),
                                       width: boardWidth,
                                       height: boardHeight) {
            return BoardPoint(x: coordinate.x, y: coordinate.y - 1)
        }
        return nil
    }

    private func matchMovePattern(dataLine: String) -> BoardPoint? {
        if let match = dataLine.firstMatch(of: /move (\w+\d+)/) {
            if let point = moveToPoint(move: String(match.1)) { return point }
        } else if dataLine.firstMatch(of: /move pass/) != nil {
            return BoardPoint.pass(width: boardWidth, height: boardHeight)
        }
        return nil
    }

    private func matchVisitsPattern(dataLine: String) -> Int? {
        if let match = dataLine.firstMatch(of: /visits (\d+)/) { return Int(match.1) }
        return nil
    }

    /// Extract a Float capture and flip it to Black's perspective when Black moves.
    private func signedFloat<R: RegexComponent>(in dataLine: String,
                                                pattern: R,
                                                whenBlack: (Float) -> Float) -> Float?
    where R.RegexOutput == (Substring, Substring) {
        guard let match = dataLine.firstMatch(of: pattern),
              let value = Float(match.output.1) else { return nil }
        return nextColor == .black ? whenBlack(value) : value
    }

    private func matchWinratePattern(dataLine: String) -> Float? {
        signedFloat(in: dataLine, pattern: /winrate ([-\d.eE]+)/) { 1.0 - $0 }
    }

    private func matchScoreLeadPattern(dataLine: String) -> Float? {
        signedFloat(in: dataLine, pattern: /scoreLead ([-\d.eE]+)/) { -$0 }
    }

    private func matchUtilityLcbPattern(dataLine: String) -> Float? {
        signedFloat(in: dataLine, pattern: /utilityLcb ([-\d.eE]+)/) { -$0 }
    }

    // MARK: - Root info

    /// Parses the `rootInfo` block's visits/winrate/scoreLead. Field order is
    /// fixed by the engine (gtp.cpp: visits, utility, winrate, scoreMean,
    /// scoreStdev, scoreLead, ...). Perspective-flipped like candidate fields.
    private func extractRootInfo(message: String) -> ParsedRootInfo? {
        let pattern = /rootInfo visits (\d+) utility [-\d.eE]+ winrate ([-\d.eE]+) scoreMean [-\d.eE]+ scoreStdev [-\d.eE]+ scoreLead ([-\d.eE]+)/
        guard let match = message.firstMatch(of: pattern),
              let visits = Int(match.1),
              let rawWinrate = Float(match.2),
              let rawScoreLead = Float(match.3) else { return nil }
        let winrate = nextColor == .black ? 1.0 - rawWinrate : rawWinrate
        let scoreLead = nextColor == .black ? -rawScoreLead : rawScoreLead
        return ParsedRootInfo(visits: visits, winrate: winrate, scoreLead: scoreLead)
    }

    // MARK: - Per-candidate extras

    /// Vertices after the `pv` keyword, token-scanned until the first token
    /// that is neither "pass" nor a vertex ("Q16", "AB12" two-letter columns).
    /// Token scanning (not a greedy regex) so trailing keywords like
    /// `movesOwnership` or `rootInfo` terminate the list.
    private func extractPV(dataLine: String) -> [String] {
        let tokens = dataLine.split(separator: " ")
        guard let pvIndex = tokens.firstIndex(of: "pv") else { return [] }
        var pv: [String] = []
        for token in tokens[(pvIndex + 1)...] {
            let isVertex = token.wholeMatch(of: /[A-Za-z]{1,2}\d{1,2}/) != nil
            if token == "pass" || isVertex {
                pv.append(String(token))
            } else {
                break
            }
        }
        return pv
    }

    /// This candidate's subtree ownership grid, when `movesOwnership true` was
    /// requested. Count-validated like the root grid; nil when absent/mismatched.
    private func extractMovesOwnership(dataLine: String) -> [Float]? {
        let values = floats(in: dataLine, pattern: /movesOwnership ([-\d\s.eE]+)/)
        return values.isEmpty ? nil : values
    }

    // MARK: - Ownership

    private func floats<R: RegexComponent>(in message: String, pattern: R) -> [Float]
    where R.RegexOutput == (Substring, Substring) {
        guard let match = message.firstMatch(of: pattern) else { return [] }
        let values = match.output.1.split(separator: " ").compactMap { Float($0) }
        return values.count == boardWidth * boardHeight ? values : []
    }

    private func extractOwnershipMean(message: String) -> [Float] {
        floats(in: message, pattern: /ownership ([-\d\s.eE]+)/)
    }

    private func extractOwnershipStdev(message: String) -> [Float] {
        floats(in: message, pattern: /ownershipStdev ([-\d\s.eE]+)/)
    }

    private func computeDefiniteness(_ whiteness: Float) -> Float {
        Swift.abs(whiteness - 0.5) * 2
    }

    private func computeOpacity(scale x: Float) -> Float {
        let a = 100.0
        let b = 0.25
        return Float(0.8 / (1.0 + exp(-a * (Double(x) - b))))
    }

    private func extractOwnershipUnits(lastData: Substring?) -> [OwnershipUnit] {
        guard let lastData else { return [] }
        let message = String(lastData)
        let mean = extractOwnershipMean(message: message)
        let stdev = extractOwnershipStdev(message: message)
        guard !mean.isEmpty && !stdev.isEmpty else { return [] }

        var ownershipUnits: [OwnershipUnit] = []
        var i = 0
        for y in stride(from: (boardHeight - 1), through: 0, by: -1) {
            for x in 0..<boardWidth {
                let point = BoardPoint(x: x, y: y)
                let whiteness = (mean[i] + 1) / 2
                let digit: Float = 5
                let digitizedWhiteness = (whiteness * digit).rounded() / digit
                let digitizedStdev = (stdev[i] * digit).rounded() / digit
                let definiteness = computeDefiniteness(digitizedWhiteness)
                let scale = max(definiteness, digitizedStdev) * 0.65
                let opacity = computeOpacity(scale: scale)
                ownershipUnits.append(OwnershipUnit(point: point,
                                                    whiteness: digitizedWhiteness,
                                                    scale: scale,
                                                    opacity: opacity))
                i += 1
            }
        }
        return ownershipUnits
    }
}
