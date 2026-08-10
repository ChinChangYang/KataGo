//
//  LastMoveKey.swift
//  KataGoUICore
//
//  The ghost-cursor anchor derivation key (extracted from VisionRootView so
//  the tvOS screens share it): keyed on the exact inputs of
//  MoveNumbers.derive so passes and step/jump navigation retrigger an
//  .onChange even though the stones don't change. The derive walk is an
//  O(moves) C++ SGF parse — run it once per position change (inside the
//  onChange), never per body eval or glide frame.
//

import Foundation

public struct LastMoveKey: Equatable, Sendable {
    public let sgf: String
    public let index: Int

    public init(sgf: String, index: Int) {
        self.sgf = sgf
        self.index = index
    }

    /// The board point of the last played move at this position; nil for a
    /// pass or an empty board (the caller keeps the center fallback then).
    public var lastPoint: BoardPoint? {
        MoveNumbers.derive(sgf: sgf, currentIndex: index).lastPoint
    }
}
