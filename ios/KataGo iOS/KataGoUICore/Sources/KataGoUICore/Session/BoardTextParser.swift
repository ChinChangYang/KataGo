//
//  BoardTextParser.swift
//  KataGo iOS
//

import Foundation

/// The board state parsed from KataGo's `showboard` ASCII output.
public struct ParsedBoard: Equatable {
    public let width: CGFloat
    public let height: CGFloat
    public let blackStones: [BoardPoint]
    public let whiteStones: [BoardPoint]
    public let moveOrder: [BoardPoint: Character]
}

/// Pure parser for `showboard` text. Behavior matches the previous
/// ContentView.parseStones/calculateBoardDimensions/calculateYCoordinate/parseLine.
public enum BoardTextParser {
    public static func parse(_ boardText: [String]) -> ParsedBoard {
        let height = CGFloat(boardText.count - 1)
        let width = CGFloat((boardText.last?.dropFirst(2).count ?? 0) / 2)
        var blackStones: [BoardPoint] = []
        var whiteStones: [BoardPoint] = []
        var moveOrder: [BoardPoint: Character] = [:]

        for line in boardText.dropFirst() {
            let y = (Int(line.prefix(2).trimmingCharacters(in: .whitespaces)) ?? 1) - 1
            for (charIndex, char) in line.dropFirst(3).enumerated() {
                let xCoord = charIndex / 2
                let point = BoardPoint(x: xCoord, y: y)
                if char == "X" {
                    blackStones.append(point)
                } else if char == "O" {
                    whiteStones.append(point)
                } else if char.isNumber {
                    moveOrder[point] = char
                }
            }
        }

        return ParsedBoard(width: width,
                           height: height,
                           blackStones: blackStones,
                           whiteStones: whiteStones,
                           moveOrder: moveOrder)
    }
}
