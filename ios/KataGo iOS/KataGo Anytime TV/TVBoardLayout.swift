//
//  TVBoardLayout.swift
//  KataGo Anytime TV
//
//  The one place the board+panel geometry is written down. Every game screen
//  (review, play, self-play) is the same HStack:
//
//      HStack(spacing: 0) {
//          board.frame(width: boardSide, height: boardSide)
//          Spacer(minLength: gapFloor)
//          panel.frame(width: panelWidth, height: panelHeight, alignment: .top)
//      }
//      .padding(.leading, leadingMargin)
//      .padding(.trailing, trailingMargin)
//
//  tvOS is always exactly 1920×1080 pt, and the Spacer is the ONLY flexible
//  element in that row, so it silently absorbs whatever the fixed frames leave
//  over. The numbers below are chosen so nothing is left over:
//
//      leadingMargin + boardSide + gapFloor + panelWidth + trailingMargin
//            24      +   1080    +    24    +    752     +      40       = 1920
//
//  That makes panelWidth = 752 the WIDEST panel that still keeps the Spacer at
//  its 24 pt floor. Widen the panel and the row overflows 1920 pt (the board is
//  pushed off-screen, since it is the leading element of a non-clipping HStack);
//  narrow it and the surplus lands in the Spacer as dead space between the board
//  and the panel — which is exactly the bug this file exists to prevent.
//
//  Why a shared type rather than literals at each site: the three screens each
//  repeated the arithmetic inline, and review + play drifted to a 500 pt panel.
//  That is 252 pt of slack the Spacer swallowed, so those two screens shipped a
//  276 pt gap between board and panel while the live self-play screen sat at the
//  correct 24 pt — the layout bug testers reported. Vertically they had drifted
//  too (1020 pt + 30 pt padding vs. live's 1000 + 40). Reading the constants
//  from here is what stops that drift recurring: change a number once and all
//  three screens move together, or none do.
//
//  The vertical pair is its own budget: panelHeight + 2 × panelVerticalPadding
//  = 1000 + 80 = 1080, the full screen height. The panel frame is FIXED (not a
//  maximum) on purpose — it reports that size to the HStack no matter how tall
//  the content wants to be, so panel growth can never inflate the row and push
//  the square board off-screen. Content that outgrows 1000 pt overflows inside
//  the slot, top-aligned.
//

import CoreGraphics

/// Fixed geometry for the tvOS board+panel row, shared by TVReviewScreen,
/// TVPlayScreen, and TVSelfPlayScreen. A namespace, not a value: there is
/// exactly one 1920×1080 pt tvOS screen, so there is nothing to instantiate.
///
/// See the file header for the arithmetic — every constant here is load-bearing
/// in the single equation `24 + 1080 + 24 + 752 + 40 = 1920`, so none of them
/// can be changed alone.
enum TVBoardLayout {
    /// The hero board is a square pinned to the screen's full height. Fixed
    /// rather than fitted: inside a NavigationStack the safe-area insets
    /// survive `ignoresSafeArea()` on the board subtree and silently shrink a
    /// fitted square to ~950 pt.
    static let boardSide: CGFloat = 1080

    /// `Spacer(minLength:)` between board and panel. The row is sized so the
    /// Spacer always sits exactly at this floor — if a screen shows a visibly
    /// wider gap, its panel is too narrow, not its spacer too big.
    static let gapFloor: CGFloat = 24

    /// The widest panel that keeps `gapFloor` at its floor. See the file header.
    static let panelWidth: CGFloat = 752

    /// Screen height minus the two `panelVerticalPadding` margins.
    static let panelHeight: CGFloat = 1000

    /// Top and bottom margin around the panel (applied as `.padding(.vertical,)`).
    static let panelVerticalPadding: CGFloat = 40

    /// Left margin of the whole row, ahead of the board.
    static let leadingMargin: CGFloat = 24

    /// Right margin of the whole row, after the panel. Wider than the leading
    /// margin: the panel's focus lift/shadow needs room the board does not.
    static let trailingMargin: CGFloat = 40
}
