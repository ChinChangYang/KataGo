//
//  CaptureGuidance.swift
//  GobanRecogKit
//
//  Pure, platform-neutral value types describing the actionable guidance a live
//  camera-capture screen shows while a user photographs a physical Go board
//  ("board cut off", "too dark", "shadow on the board", ...).
//
//  These are UX-guidance types only. They carry NO AVFoundation / Vision /
//  UIKit dependency (Foundation + CoreGraphics value types), so they compile in
//  the GobanRecogKit SwiftPM target for both iOS and macOS and are unit-testable
//  without a camera. The math that produces them lives in
//  `CaptureQualityAnalyzer`.
//

import CoreGraphics
import Foundation

/// A single actionable problem with the current camera framing / exposure of a
/// board, from a live preview frame.
///
/// Declaration order IS the priority order (most urgent first): when several
/// issues are present at once the capture UI surfaces the earliest one here.
/// `noBoard` is the most urgent (there is nothing to guide toward yet).
public enum GuidanceIssue: CaseIterable, Sendable, Equatable {
    /// No board quad was detected in the frame.
    case noBoard
    /// The detected board touches (or nearly touches) a frame edge.
    case boardCutOff
    /// The board is too small in frame (move closer).
    case tooFar
    /// The board is viewed at too steep an angle (shoot from directly above).
    case tooTilted
    /// The board region is under-exposed (too dark).
    case tooDark
    /// A blown-out highlight covers part of the board (glare).
    case glare
    /// A soft shadow falls across part of the board.
    case shadow

    /// Priority rank; lower is more urgent. Derived from declaration order so
    /// the enum stays the single source of truth for ordering.
    var priority: Int {
        Self.allCases.firstIndex(of: self) ?? Int.max
    }
}

/// The result of analyzing one live preview frame: the detected board quad (if
/// any) and the prioritized guidance issues for it.
///
/// `quad`, when present, is exactly 4 points in normalized `[0, 1]` image
/// coordinates (origin top-left) in corner order TL, TR, BR, BL. `nil` means no
/// board was found this frame.
public struct CaptureGuidance: Sendable, Equatable {
    /// Detected board corners in normalized `[0, 1]` image coordinates
    /// (TL, TR, BR, BL), or `nil` when no board was found.
    public let quad: [CGPoint]?
    /// The issues found, sorted by priority (most urgent first). May be empty.
    public let issues: [GuidanceIssue]

    public init(quad: [CGPoint]?, issues: [GuidanceIssue]) {
        self.quad = quad
        self.issues = issues
    }

    /// The single most-urgent issue to surface, or `nil` when there is nothing
    /// to fix (that `nil` reads as "Looks good"). Robust to an unsorted
    /// `issues` array: it always returns the highest-priority member.
    public var primary: GuidanceIssue? {
        issues.min { $0.priority < $1.priority }
    }

    /// True when a board was found and it has no outstanding issues.
    public var looksGood: Bool {
        quad != nil && issues.isEmpty
    }
}

/// A tightly packed 8-bit grayscale image: one `UInt8` luma sample per pixel,
/// row-major, `width * height` samples total.
///
/// The failable initializer enforces that invariant so downstream math can index
/// `pixels[y * width + x]` without bounds surprises.
public struct LumaGrid: Sendable {
    public let pixels: [UInt8]
    public let width: Int
    public let height: Int

    /// Fails (returns `nil`) unless `pixels.count == width * height` with both
    /// dimensions strictly positive.
    public init?(pixels: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.pixels = pixels
        self.width = width
        self.height = height
    }
}
