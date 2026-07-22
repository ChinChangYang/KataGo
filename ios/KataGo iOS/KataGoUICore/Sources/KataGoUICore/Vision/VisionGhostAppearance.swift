//
//  VisionGhostAppearance.swift
//  KataGoUICore
//
//  What the visionOS controller cursor renders at its focused
//  intersection. An empty point shows the semi-transparent aiming ghost
//  stone in the to-move color; an occupied point hides the ghost — a
//  translucent stone coinciding with a concrete one reads as a glitch —
//  and shows a flat focus ring hugging the occupant instead, so the
//  focused intersection never loses its visual indication. Pure logic;
//  rendering lives in the app target's VisionBoardSceneModel.
//

import Foundation
import KataGoGameStore

public enum VisionGhostAppearance: Equatable, Sendable {
    case hidden
    /// Empty intersection: the aiming ghost stone in the to-move color.
    case ghost(color: PlayerColor, point: BoardPoint)
    /// Occupied intersection: no ghost; a focus ring hugging the occupant
    /// stone's base, contrast-colored against the occupant.
    case focusRing(occupant: PlayerColor, point: BoardPoint)

    public static func resolve(cursor: BoardPoint?,
                               black: [BoardPoint],
                               white: [BoardPoint],
                               nextColor: PlayerColor) -> VisionGhostAppearance {
        guard let cursor else { return .hidden }
        if black.contains(cursor) { return .focusRing(occupant: .black, point: cursor) }
        if white.contains(cursor) { return .focusRing(occupant: .white, point: cursor) }
        return .ghost(color: nextColor == .white ? .white : .black, point: cursor)
    }
}
