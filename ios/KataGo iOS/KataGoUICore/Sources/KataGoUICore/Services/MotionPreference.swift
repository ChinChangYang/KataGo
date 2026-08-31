//
//  MotionPreference.swift
//  KataGoUICore
//
//  The one place the board's stone motion is timed and sized (ADR 0015), and
//  the one place the Reduce Motion rule is written down. The 2D layer
//  (`StoneMotionLayer`) reads every constant here; the volumetric board keeps
//  its own, longer flight times (a stone crossing 6 cm of real space is not a
//  stone growing 15% on a phone screen) but shares the RULE — "Reduce Motion
//  means nothing travels and nothing scales" has to mean the same thing on
//  both boards, or one of them will drift.
//
//  UIKit-free on purpose: nothing here reads a system setting. The 2D views
//  read SwiftUI's `\.accessibilityReduceMotion` themselves, and
//  `VisionBoardRealityView` hands the Bool to its scene model.
//

import Foundation
import CoreGraphics

public enum MotionPreference {
    /// How long an arriving stone takes to settle from `settleScale` onto the
    /// board — and therefore when its placement click fires. Deliberately
    /// shorter than the volumetric board's 0.25 s flight: on a flat board
    /// nothing has to travel, so a longer settle reads as lag rather than as
    /// weight.
    public static let settleDuration: TimeInterval = 0.15

    /// How long a stone leaving the board takes to shrink and fade: an undone
    /// stone, or one a capture took.
    public static let removalDuration: TimeInterval = 0.18

    /// The scale an arriving stone starts at. Always ABOVE 1, which is
    /// load-bearing: the transient copy is drawn over the Canvas twin the
    /// record already put on the board, so a stone that grew INTO place from
    /// below 1x would show the twin's edge around it for the whole settle.
    public static let settleScale: CGFloat = 1.15

    /// The scale a departing stone shrinks to before it is gone. It has no
    /// twin underneath — it left the position — so it may shrink freely.
    public static let departureScale: CGFloat = 0.6

    /// The opacity of an arriving stone's contact shadow at the top of its
    /// settle; it fades to 0 as the stone seats.
    public static let contactShadowOpacity: Double = 0.35

    /// The Reduce Motion rule, as one expression: with the setting on, nothing
    /// scales (1x throughout) and only opacity animates, over the same
    /// durations. Both transient views call this rather than each writing the
    /// ternary out, so the two cannot disagree.
    ///
    /// A consequence worth knowing before reading the layer: on the 2D board an
    /// ARRIVING stone sits over the Canvas twin, so its opacity ramp is masked
    /// and the stone simply appears. That is the intended outcome — Reduce
    /// Motion asks for no motion, not for different motion — and the cross-fade
    /// is genuinely visible where there is nothing underneath it: the stones
    /// leaving the board.
    public static func scale(_ scale: CGFloat, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 1 : scale
    }
}
