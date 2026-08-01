//
//  BoardSheetFit.swift
//  KataGoGameStore
//
//  How large the board may be on a sheet it shares with a header and an
//  action row — and where the resulting block sits.
//
//  This exists because the Messages extension used to ask SwiftUI the same
//  question through proposal negotiation: `.aspectRatio(_:contentMode: .fit)`
//  on a `GeometryReader` inside a `ScrollView`. A ScrollView proposes an
//  UNSPECIFIED height, so `fit` had only the width to go on and resolved the
//  aspect ratio from it alone. A 9x19 came out ~781 pt tall in a ~636 pt
//  sheet, its bottom rows unreachable because the board's own drag gesture ate
//  the scroll pan; the same nil proposal left a square board pinned to the top
//  with ~266 pt of dead space dumped below the buttons.
//
//  Doing the arithmetic here instead makes both unrepresentable: the board is
//  fitted against BOTH axes, so it can never exceed the sheet, and the
//  leftover is reported as an inset so the caller can center the whole block
//  rather than letterbox the board inside an oversized slot.
//
//  CoreGraphics only, like every rule in this module: `KataGoGameStore` also
//  compiles for watchOS and tvOS, and the iOS test target exercises the rule
//  directly.
//

import CoreGraphics

public struct BoardSheetFit: Equatable, Sendable {
    /// The sheet's content box, already net of the screen's own padding.
    public let available: CGSize
    /// Everything on the sheet that is not the board: header, action row, and
    /// the spacing between them.
    public let chromeHeight: CGFloat
    /// The board's drawn size. Fits `available` on both axes and keeps the
    /// board's aspect ratio exactly.
    public let boardSize: CGSize
    /// The block's natural height — chrome plus board.
    public let contentHeight: CGFloat
    /// The height the scrolling content should claim: the block, or the sheet
    /// when the block is shorter than it.
    public let totalHeight: CGFloat
    /// Half the leftover, so the block sits centered rather than top-aligned.
    public let topInset: CGFloat

    /// True only when the chrome itself has outgrown the sheet — at ordinary
    /// text sizes the board is fitted and nothing scrolls.
    public var scrolls: Bool { contentHeight > available.height }

    /// - Parameter minimumBoardHeight: a floor on the board's height BUDGET,
    ///   not on the board. At accessibility text sizes a grown header and a
    ///   stacked action column can claim the whole sheet, collapsing the board
    ///   to a few points; below this floor the sheet is expected to scroll
    ///   instead. The floor deliberately does not inflate a board that is
    ///   naturally shorter — a 37x2 is genuinely ~20 pt tall at phone widths,
    ///   and stretching it would either distort it or push it off the sides.
    public init(available: CGSize, chromeHeight: CGFloat,
                boardWidth: Int, boardHeight: Int,
                minimumBoardHeight: CGFloat) {
        let columns = CGFloat(max(boardWidth, 1))
        let rows = CGFloat(max(boardHeight, 1))
        // SwiftUI proposals legitimately carry `.infinity`, and an unbounded
        // dimension poisons the whole result: an infinite height makes
        // `totalHeight` infinite while `contentHeight` stays finite, so the
        // centering inset diverges — and when BOTH are unbounded the inset
        // comes out NaN, which is a hard crash the moment it reaches a frame.
        // An unbounded axis offers no usable space, so it is treated as none.
        let width = finite(available.width)
        let height = finite(available.height)
        let chrome = finite(chromeHeight)

        self.available = CGSize(width: width, height: height)
        self.chromeHeight = chrome

        let budget = max(max(height - chrome, 0), finite(minimumBoardHeight))
        // The tallest the board could be if only the width constrained it.
        let widthDriven = width * rows / columns
        let fittedHeight = min(widthDriven, budget)

        boardSize = CGSize(width: fittedHeight * columns / rows, height: fittedHeight)
        contentHeight = chrome + fittedHeight
        totalHeight = max(contentHeight, height)
        topInset = (totalHeight - contentHeight) / 2
    }
}

/// Non-negative and finite, so no infinity or NaN can reach the arithmetic
/// above — every value this type publishes is fed straight into a frame.
private func finite(_ value: CGFloat) -> CGFloat {
    value.isFinite ? max(value, 0) : 0
}
