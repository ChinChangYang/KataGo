//
//  WatchBoardLayout.swift
//  KataGoGameStore
//
//  The watch board page's layout arithmetic: how wide the winrate gutter is,
//  and how the bar splits between the two colors.
//
//  Lives here rather than in the watch target for the same reason
//  `WatchBoardFrame` does — the watch has no test bundle, so any rule that can
//  be wrong has to sit where `KataGo AnytimeTests` can reach it.
//

import CoreGraphics

public enum WatchBoardLayout: Sendable {
    /// Width of the vertical winrate gutter, in points.
    ///
    /// The iOS board (`WinrateBarView`) sizes its bar at 3/8 of a cell and
    /// straddles it over the goban slab's left edge, where the wood provides a
    /// three-quarter-cell margin to sit in. `WidgetBoardView` has no such
    /// margin — its grid is centred in whatever frame it is handed, leaving
    /// only `cell/2` outside the outermost line (4.9 pt on a watch-sized
    /// 19x19, 2.5 pt on a 37x37). Overlaying a legible bar there would graze
    /// the leftmost stones on dense boards, so the bar takes its own column
    /// instead and the board is laid out beside it.
    ///
    /// 5 pt is 3/8 of a cell at the 19x19 watch pitch — the iOS ratio at the
    /// size this actually renders — rounded up to survive a 41 mm screen.
    public static let gutterWidth: CGFloat = 5

    /// Space between the gutter and the board.
    public static let gutterSpacing: CGFloat = 2

    /// How the vertical bar divides, in iOS's orientation: White fills from
    /// the TOP, Black from the BOTTOM (`WinrateBarView` computes
    /// `whiteBarHeight = barHeight * rootWinrate.white` and anchors it at
    /// `gobanStartY`).
    public struct Split: Equatable, Sendable {
        public let whiteHeight: CGFloat
        public let blackHeight: CGFloat

        public init(whiteHeight: CGFloat, blackHeight: CGFloat) {
            self.whiteHeight = whiteHeight
            self.blackHeight = blackHeight
        }
    }

    /// The two-tone split for a bar of `height` points, or nil when nothing has
    /// been analyzed.
    ///
    /// Nil is a real state, not an error: `WatchBoardFrame.winrateBlack` is
    /// optional precisely so an unanalyzed position HIDES the number rather
    /// than inventing 50%. The caller draws a dim empty track for nil and keeps
    /// the gutter reserved either way — collapsing it would resize the board
    /// every time analysis arrives or goes stale.
    ///
    /// `winrateBlack` is clamped to 0...1. A NaN (which no comparison can
    /// reject) is treated as unanalyzed, so a bad float can never produce a
    /// NaN-height rectangle.
    public static func split(winrateBlack: Float?, height: CGFloat) -> Split? {
        guard let winrateBlack, winrateBlack.isFinite else { return nil }
        let barHeight = max(height, 0)
        let black = min(max(CGFloat(winrateBlack), 0), 1)
        let blackHeight = barHeight * black
        // Subtract rather than multiply by (1 - black): the two parts then sum
        // to exactly `barHeight` at every rounding, so the bar never shows a
        // sub-pixel seam or overruns its frame.
        return Split(whiteHeight: barHeight - blackHeight, blackHeight: blackHeight)
    }
}
