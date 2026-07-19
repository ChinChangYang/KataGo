//
//  BoardAccessibilityOverlay.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2026/7/19.
//

import SwiftUI

/// One speakable target on the goban: a board intersection named by its Go
/// coordinate ("K 10") or the pass tile ("Pass"). Built by `elements(...)`,
/// rendered by `BoardAccessibilityOverlay`. Public so unit tests can exercise
/// the builder without `@testable` (same precedent as `Coordinate.parseVertex`
/// callers).
public struct BoardAccessibilityElement: Identifiable {
    public let coordinate: Coordinate
    public let point: BoardPoint
    public let label: String

    /// `Coordinate.index` is unique across the grid AND the pass point (the
    /// pass row sits above the board, so its index lands past the grid range).
    public var id: Int { coordinate.index }

    /// Every speakable target for a board, top row first in the default
    /// orientation. Labels reuse `Coordinate.xLabelMap` (letter I skipped,
    /// two-letter columns past Z) with a space between column and row so
    /// Voice Control matches "Tap K ten" and VoiceOver reads "K ten", not
    /// "K10" as one token. The pass element is appended only when the pass
    /// tile is visible, mirroring the tap gesture's phantom-pass guard.
    public static func elements(width: Int, height: Int, includePass: Bool) -> [BoardAccessibilityElement] {
        var elements: [BoardAccessibilityElement] = []
        elements.reserveCapacity(width * height + (includePass ? 1 : 0))

        for y in stride(from: height, through: 1, by: -1) {
            for x in 0..<width {
                if let coordinate = Coordinate(x: x, y: y, width: width, height: height),
                   let point = coordinate.point,
                   let xLabel = coordinate.xLabel {
                    elements.append(BoardAccessibilityElement(coordinate: coordinate,
                                                              point: point,
                                                              label: "\(xLabel) \(coordinate.yLabel)"))
                }
            }
        }

        if includePass {
            let passPoint = BoardPoint.pass(width: width, height: height)
            if let coordinate = Coordinate(x: passPoint.x, y: passPoint.y + 1, width: width, height: height),
               let point = coordinate.point {
                elements.append(BoardAccessibilityElement(coordinate: coordinate,
                                                          point: point,
                                                          label: "Pass"))
            }
        }

        return elements
    }
}

/// Accessibility-only layer over the goban: exposes every intersection (and
/// the pass tile) as a named button so Voice Control users can say
/// "Tap K ten" / "Tap Pass" and VoiceOver users can inspect any point. The
/// board itself is pure drawing with a single whole-board tap gesture, so
/// without this layer it has no accessible targets at all.
///
/// Draws nothing (`Color.clear`) and never intercepts touches
/// (`allowsHitTesting(false)`): real taps keep hitting the tap gesture, while
/// each element's accessibility action routes through the SAME
/// `attemptHumanMove` gate as a touch, so voice moves obey turn/lock/occupancy
/// rules identically.
struct BoardAccessibilityOverlay: View, Equatable {
    @Environment(Stones.self) private var stones
    @Environment(GobanState.self) private var gobanState

    let dimensions: Dimensions
    let boardWidth: Int
    let boardHeight: Int
    let showPass: Bool
    let playAction: (Coordinate) -> Void

    /// Compares ONLY layout inputs, deliberately excluding `playAction` and
    /// the `@Environment` observables: Observation invalidates this view
    /// directly when stones/verticalFlip change, so equality here only needs
    /// to stop parent-driven re-evaluation — BoardView's body re-runs on
    /// every visits/s analysis tick, and without this short-circuit the
    /// up-to-1369-element ForEach would re-diff on each one.
    /// `nonisolated` to satisfy Equatable from the MainActor-isolated View;
    /// it only reads immutable Sendable inputs.
    nonisolated static func == (lhs: BoardAccessibilityOverlay, rhs: BoardAccessibilityOverlay) -> Bool {
        lhs.dimensions == rhs.dimensions &&
        lhs.boardWidth == rhs.boardWidth &&
        lhs.boardHeight == rhs.boardHeight &&
        lhs.showPass == rhs.showPass
    }

    var body: some View {
        // O(n) once per body run (stone changes only), not O(n) per element.
        let black = Set(stones.blackPoints)
        let white = Set(stones.whitePoints)

        ZStack {
            ForEach(BoardAccessibilityElement.elements(width: boardWidth,
                                                       height: boardHeight,
                                                       includePass: showPass)) { element in
                Color.clear
                    .frame(width: dimensions.squareLength, height: dimensions.squareLength)
                    .position(dimensions.screenCenter(for: element.point,
                                                      verticalFlip: gobanState.verticalFlip))
                    .accessibilityElement()
                    .accessibilityLabel(element.label)
                    .accessibilityValue(value(for: element, black: black, white: white))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { playAction(element.coordinate) }
            }
        }
        // One "Board" container so VoiceOver users can skip the whole grid
        // instead of swiping through hundreds of intersections.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Board")
        .allowsHitTesting(false)
    }

    private func value(for element: BoardAccessibilityElement,
                       black: Set<BoardPoint>,
                       white: Set<BoardPoint>) -> String {
        if element.point.isPass(width: boardWidth, height: boardHeight) {
            return ""
        } else if black.contains(element.point) {
            return "Black stone"
        } else if white.contains(element.point) {
            return "White stone"
        } else {
            return "Empty"
        }
    }
}
