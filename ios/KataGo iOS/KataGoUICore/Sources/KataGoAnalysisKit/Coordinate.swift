//
//  Coordinate.swift
//  KataGoAnalysisKit
//
//  GTP vertex <-> board coordinate mapping, moved verbatim from KataGoUICore's
//  KataGoModel.swift for the bridge-free analysis tier (AnalysisLineParser
//  turns "Q16"-style vertices into BoardPoints through it). The Dimensions-based
//  screen-point mapping (`from(location:dimensions:...)`) and the move-string
//  parsing convenience init stay in KataGoUICore as extensions.
//

import Foundation

public struct Coordinate {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public var xLabel: String? {
        return Coordinate.xLabelMap[x]
    }

    public var yLabel: String {
        return String(y)
    }

    public var move: String? {
        if let point, point.isPass(width: width, height: height) {
            return "pass"
        } else if let xLabel {
            return "\(xLabel)\(yLabel)"
        } else {
            return nil
        }
    }

    public var point: BoardPoint? {
        BoardPoint(x: x, y: y - 1)
    }

    public var index: Int {
        x + ((y - 1) * width)
    }

    // Mapping letters A-AZ (without I) to numbers 0-49
    public static let xMap: [String: Int] = [
        "A": 0, "B": 1, "C": 2, "D": 3, "E": 4,
        "F": 5, "G": 6, "H": 7, "J": 8, "K": 9,
        "L": 10, "M": 11, "N": 12, "O": 13, "P": 14,
        "Q": 15, "R": 16, "S": 17, "T": 18, "U": 19,
        "V": 20, "W": 21, "X": 22, "Y": 23, "Z": 24,
        "AA": 25, "AB": 26, "AC": 27, "AD": 28, "AE": 29,
        "AF": 30, "AG": 31, "AH": 32, "AJ": 33, "AK": 34,
        "AL": 35, "AM": 36, "AN": 37, "AO": 38, "AP": 39,
        "AQ": 40, "AR": 41, "AS": 42, "AT": 43, "AU": 44,
        "AV": 45, "AW": 46, "AX": 47, "AY": 48, "AZ": 49
    ]

    public static let xLabelMap: [Int: String] = [
        0: "A", 1: "B", 2: "C", 3: "D", 4: "E",
        5: "F", 6: "G", 7: "H", 8: "J", 9: "K",
        10: "L", 11: "M", 12: "N", 13: "O", 14: "P",
        15: "Q", 16: "R", 17: "S", 18: "T", 19: "U",
        20: "V", 21: "W", 22: "X", 23: "Y", 24: "Z",
        25: "AA", 26: "AB", 27: "AC", 28: "AD", 29: "AE",
        30: "AF", 31: "AG", 32: "AH", 33: "AJ", 34: "AK",
        35: "AL", 36: "AM", 37: "AN", 38: "AO", 39: "AP",
        40: "AQ", 41: "AR", 42: "AS", 43: "AT", 44: "AU",
        45: "AV", 46: "AW", 47: "AX", 48: "AY", 49: "AZ"
    ]

    public init?(x: Int, y: Int, width: Int, height: Int) {
        guard ((1...height).contains(y) && (0..<width).contains(x)) || BoardPoint(x: x, y: y - 1).isPass(width: width, height: height) else { return nil }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init?(xLabel: String, yLabel: String) {
        self.init(xLabel: xLabel, yLabel: yLabel, width: 19, height: 19)
    }

    public init?(xLabel: String, yLabel: String, width: Int, height: Int) {
        if let x = Coordinate.xMap[xLabel.uppercased()],
           let y = Int(yLabel) {
            self.init(x: x, y: y, width: width, height: height)
        } else {
            return nil
        }
    }
}
