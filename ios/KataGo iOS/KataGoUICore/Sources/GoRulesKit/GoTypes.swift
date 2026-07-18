//
//  GoTypes.swift
//  GoRulesKit
//
//  Core value types for the bridge-free Go rules engine. GoRulesKit exists so
//  processes that cannot link the C++ engine (the Messages extension) can
//  validate moves, resolve captures, and score finished games. Semantics are
//  a faithful port of cpp/game/board.cpp + boardhistory.cpp; the differential
//  tests in the app test target replay games through both implementations.
//
//  Coordinates are 0-based with the origin at the TOP-LEFT (x right, y down),
//  matching `parseVertex` in KataGoGameStore so points flow straight into
//  WidgetBoardView. GTP row numbers count from the bottom: row = height - y.
//

import Foundation

public enum GoColor: Int, Sendable, Hashable, Codable {
    case empty = 0
    case black = 1
    case white = 2

    public var opponent: GoColor {
        switch self {
        case .black: .white
        case .white: .black
        case .empty: .empty
        }
    }
}

public struct GoPoint: Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public enum GoMove: Hashable, Sendable {
    case play(GoPoint)
    case pass
}

public enum GoPlayError: Error, Equatable, Sendable {
    case occupied
    case offBoard
    case simpleKoBanned
    case superKoBanned
    case suicideIllegal
    case wrongPhase
}

extension GoPoint {
    /// GTP vertex string ("Q16"): columns skip 'I', two-letter "A"+letter for
    /// columns 25..49, rows count from the bottom. Inverse of
    /// `parseVertex(_:width:height:)` in KataGoGameStore.
    public func gtpVertex(boardHeight: Int) -> String {
        Self.columnLabel(x) + String(boardHeight - y)
    }

    static let gtpColumnLetters = Array("ABCDEFGHJKLMNOPQRSTUVWXYZ")

    static func columnLabel(_ x: Int) -> String {
        if x < gtpColumnLetters.count {
            return String(gtpColumnLetters[x])
        }
        let second = x - gtpColumnLetters.count
        guard second < gtpColumnLetters.count else { return "" }
        return "A" + String(gtpColumnLetters[second])
    }
}
