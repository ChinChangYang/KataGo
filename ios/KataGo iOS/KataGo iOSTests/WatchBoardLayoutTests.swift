//
//  WatchBoardLayoutTests.swift
//  KataGo AnytimeTests
//
//  The watch board page's layout arithmetic. It lives in KataGoGameStore
//  precisely so it can be tested here — the watch target has no test bundle,
//  so anything left in a watch view is only ever checked by looking at a
//  simulator.
//

import Testing
import Foundation
import KataGoGameStore

struct WatchBoardLayoutTests {
    /// White fills from the TOP, Black from the bottom — the in-app board's
    /// orientation (`WinrateBarView` anchors `barHeight * rootWinrate.white`
    /// at `gobanStartY`). Getting this backwards would silently invert the
    /// bar for every game.
    ///
    /// Asserted at 0.25 because it is exactly representable as a `Float`:
    /// winrates arrive from the engine as `Float` and are widened to `CGFloat`
    /// here, so a value like 0.55 is really 0.550000011920928955 and 55 pt of
    /// bar is really 55.000001192092896. That is invisible on screen but makes
    /// bit-exact assertions on round decimals meaningless.
    @Test func splitPutsWhiteOnTop() {
        let split = WatchBoardLayout.split(winrateBlack: 0.25, height: 100)
        #expect(split?.whiteHeight == 75)
        #expect(split?.blackHeight == 25)
    }

    /// The same orientation at a winrate that is NOT exactly representable, to
    /// show the rule holds for real engine output and not just for quarters.
    @Test func splitPutsWhiteOnTopAtAnInexactWinrate() {
        guard let split = WatchBoardLayout.split(winrateBlack: 0.55, height: 100) else {
            Issue.record("a finite winrate must produce a split")
            return
        }
        #expect(abs(split.whiteHeight - 45) < 0.001)
        #expect(abs(split.blackHeight - 55) < 0.001)
        #expect(split.blackHeight > split.whiteHeight)   // Black is ahead
    }

    /// An unanalyzed position has no bar, not a 50/50 bar. The caller draws a
    /// dim track for nil and keeps the gutter reserved either way.
    @Test func splitIsNilWhenNothingAnalyzed() {
        #expect(WatchBoardLayout.split(winrateBlack: nil, height: 100) == nil)
    }

    /// A non-finite winrate is treated as unanalyzed rather than propagated.
    /// NaN survives every `<`/`>` comparison, so a naive clamp would hand
    /// SwiftUI a NaN-height rectangle.
    @Test func splitRejectsNonFiniteWinrates() {
        #expect(WatchBoardLayout.split(winrateBlack: .nan, height: 100) == nil)
        #expect(WatchBoardLayout.split(winrateBlack: .infinity, height: 100) == nil)
        #expect(WatchBoardLayout.split(winrateBlack: -.infinity, height: 100) == nil)
    }

    @Test func splitClampsOutOfRangeWinrates() {
        let under = WatchBoardLayout.split(winrateBlack: -0.5, height: 100)
        #expect(under?.whiteHeight == 100)
        #expect(under?.blackHeight == 0)

        let over = WatchBoardLayout.split(winrateBlack: 1.5, height: 100)
        #expect(over?.whiteHeight == 0)
        #expect(over?.blackHeight == 100)
    }

    /// The two parts must fill the bar height at every winrate, so the bar
    /// never overruns its frame or leaves a gap between the colors. This is
    /// why the split subtracts rather than computing each part from its own
    /// multiplication: the seam is defined once, as `barHeight - blackHeight`,
    /// so the two rectangles meet at a single coordinate by construction
    /// instead of by two independent roundings agreeing.
    @Test(arguments: [Float(0), Float(0.001), Float(1) / 3, Float(0.5),
                      Float(0.6180339), Float(0.999), Float(1)])
    func splitPartsFillTheBarHeight(winrate: Float) {
        let height: CGFloat = 150.5
        guard let split = WatchBoardLayout.split(winrateBlack: winrate, height: height) else {
            Issue.record("a finite winrate must produce a split")
            return
        }
        #expect(split.whiteHeight >= 0)
        #expect(split.blackHeight >= 0)
        #expect(abs(split.whiteHeight + split.blackHeight - height) < 1e-9)
    }

    @Test func splitTreatsNegativeHeightAsZero() {
        let split = WatchBoardLayout.split(winrateBlack: 0.5, height: -20)
        #expect(split?.whiteHeight == 0)
        #expect(split?.blackHeight == 0)
    }

    /// The gutter is reserved unconditionally, so its width is a constant the
    /// board's own margin never has to accommodate. Pinned because the whole
    /// reason it is a fixed column rather than an overlay is that the board's
    /// margin (`cell/2`) shrinks to 2.5 pt on a 37x37 at watch size — narrower
    /// than a legible bar, which would then graze the leftmost stones.
    @Test func gutterIsNarrowerThanAWatchSizedCell() {
        #expect(WatchBoardLayout.gutterWidth == 5)
        #expect(WatchBoardLayout.gutterSpacing == 2)
        // Measured on watchOS 26.5: a 46 mm page inside
        // NavigationStack > TabView(.verticalPage) with a title is 204x150 pt,
        // and the board is height-limited, so a 19x19 cell is 150/19 ≈ 7.9 pt.
        // The bar stays under one cell — wider would read as a stone.
        let cell19At46mm = 150.0 / 19.0
        #expect(WatchBoardLayout.gutterWidth < cell19At46mm)
    }
}
