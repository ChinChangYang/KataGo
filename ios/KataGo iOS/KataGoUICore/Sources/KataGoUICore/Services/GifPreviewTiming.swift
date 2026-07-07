//
//  GifPreviewTiming.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2026/7/7.
//

import Foundation

/// Timing model for the GIF export **preview**, mirroring the exported GIF's
/// pacing exactly so the preview shows what the file will do.
///
/// The encoder (`GameGifRenderer`/`AnimatedGifEncoder`) shows each of the first
/// `n - 1` frames for `secondsPerMove` and holds the final frame for
/// `finalHoldSeconds`, optionally looping. This struct reproduces that layout as
/// a pure function of elapsed time so both the preview's `TimelineView` schedule
/// and its per-tick frame lookup agree — and so it can be unit-tested without UI.
///
/// `secondsPerMove`/`finalHoldSeconds` are the *effective* values (already
/// floored above zero and with the caller's "0 == no extra hold" mapping
/// resolved), so the math here never divides by or holds for zero.
struct GifPreviewTiming: Equatable {
    let frameCount: Int
    let secondsPerMove: Double
    let finalHoldSeconds: Double
    let loops: Bool

    /// One full pass: the first `n - 1` frames at `secondsPerMove`, then the
    /// final frame held for `finalHoldSeconds`.
    var cycle: Double {
        max(Double(frameCount - 1), 0) * secondsPerMove + finalHoldSeconds
    }

    /// Elapsed offset (from the animation start) at which frame `i` appears.
    func start(of i: Int) -> Double {
        Double(i) * secondsPerMove
    }

    /// The frame index visible at `e` seconds since the animation started.
    ///
    /// The first `n - 1` frames each span `secondsPerMove`; the final frame fills
    /// the rest of the cycle (its hold), which `min(_, last)` captures. When
    /// `loops`, time wraps every `cycle`; otherwise it is clamped so that once the
    /// final frame appears it stays forever (a frozen last position that subsumes
    /// the final hold). A tiny epsilon snaps near-boundary values so the preview
    /// doesn't show an off-by-one frame when the schedule wakes it exactly on a
    /// frame boundary.
    func index(atElapsed e: Double) -> Int {
        guard frameCount > 1 else { return 0 }
        let t: Double
        if loops {
            var r = e.truncatingRemainder(dividingBy: cycle)
            if r < 0 { r += cycle }
            t = r
        } else {
            t = max(0, e)
        }
        let i = Int((t / secondsPerMove + 1e-6).rounded(.down))
        return min(i, frameCount - 1)
    }

    /// True once a non-looping animation has reached (and frozen on) its final
    /// frame — the cue for the preview's "tap to replay" affordance.
    func isFinished(atElapsed e: Double) -> Bool {
        !loops && frameCount > 1 && e + 1e-6 >= start(of: frameCount - 1)
    }
}
