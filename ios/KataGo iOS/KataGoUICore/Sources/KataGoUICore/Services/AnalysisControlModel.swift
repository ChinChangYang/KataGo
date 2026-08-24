//
//  AnalysisControlModel.swift
//  KataGoUICore
//
//  What the analysis (sparkle) control looks like and does, decided in one
//  place from two inputs: the user's analysis PREFERENCE (run / pause / clear
//  — owned by the user, never written by engine transitions) and the engine's
//  AVAILABILITY. The control's appearance reports analysis ACTIVITY — whether
//  anything is actually streaming — which needs both.
//
//  The grammar (ADR 0010): a bare red slash means "you turned analysis off";
//  a red slash with a warning badge means "the engine cannot analyse" (Absent,
//  Failed, Held). The badge is a SHAPE, not a colour, so the distinction
//  survives colour-blindness — and the accessibility label carries the same
//  distinction in words, because VoiceOver cannot see the badge.
//
//  Tapping follows the state: with a usable engine the tap cycles
//  run → pause → clear → run as it always has; with a resting-down engine the
//  tap opens the remedy surface (the model picker / Manage Models / the Models
//  ornament) instead — the sparkle is where a missing engine is discovered,
//  because it is the one control whose promise the outage breaks.
//
//  One rule, three hosts: iOS `StatusToolbarItems`, macOS
//  `MainWindowController.toggleAnalysis`/`refreshAnalyzeToolbarItem`, and the
//  visionOS control ornament all derive the sparkle from here.
//

import Foundation

public enum AnalysisControlModel {
    /// What a tap on the control does.
    public enum Tap: Equatable, Sendable {
        /// Cycle the user's preference (run → pause → clear → run).
        case cycle
        /// Open the remedy surface (model selection with the status header).
        case openRemedy
    }

    public struct State: Equatable, Sendable {
        /// The asset-catalog symbol to draw ("custom.sparkle" /
        /// "custom.sparkle.slash").
        public let symbolName: String
        /// Whether the symbol is tinted red (every stopped state is).
        public let isRed: Bool
        /// The engine-down badge. Bare red slash = user off; badged = engine
        /// down.
        public let showsWarningBadge: Bool
        /// False only while the engine is LAUNCHING: the wait is transient,
        /// the board's status pill narrates it, and a tap has nothing useful
        /// to do yet. Every resting state keeps the control enabled — a
        /// disabled control cannot open the remedy.
        public let isEnabled: Bool
        /// Drives the variable-color symbol effect. Analysis ACTIVITY, not
        /// preference: a `.run` preference against a down engine animates
        /// nothing, because nothing is running.
        public let isAnimating: Bool
        public let tap: Tap
        /// VoiceOver's words. Diverges where the visuals diverge: the badge's
        /// meaning must be audible, not just visible.
        public let accessibilityLabel: String

        public init(symbolName: String, isRed: Bool, showsWarningBadge: Bool,
                    isEnabled: Bool, isAnimating: Bool, tap: Tap,
                    accessibilityLabel: String) {
            self.symbolName = symbolName
            self.isRed = isRed
            self.showsWarningBadge = showsWarningBadge
            self.isEnabled = isEnabled
            self.isAnimating = isAnimating
            self.tap = tap
            self.accessibilityLabel = accessibilityLabel
        }
    }

    public static let sparkleSymbol = "custom.sparkle"
    public static let slashSymbol = "custom.sparkle.slash"

    /// - Parameter availability: nil when the host injects no `EngineStatus`
    ///   (a preview, an unconverted host) — which reads as "usable", the
    ///   pre-existing behaviour verbatim.
    public static func make(analysisStatus: AnalysisStatus,
                            availability: EngineAvailability?) -> State {
        switch availability {
        case nil, .ready:
            return usable(analysisStatus: analysisStatus,
                          isEnabled: true,
                          isAnimating: analysisStatus == .run)
        case .launching:
            // Transient: the board's status pill narrates the wait. Not
            // animating — nothing is streaming yet, and a spinning sparkle
            // over a loading engine would claim otherwise.
            return usable(analysisStatus: analysisStatus,
                          isEnabled: false,
                          isAnimating: false)
        case .absent, .failed, .held:
            return State(symbolName: slashSymbol,
                         isRed: true,
                         showsWarningBadge: true,
                         isEnabled: true,
                         isAnimating: false,
                         tap: .openRemedy,
                         accessibilityLabel: "Analysis stopped — engine unavailable. Opens model selection.")
        }
    }

    private static func usable(analysisStatus: AnalysisStatus,
                               isEnabled: Bool,
                               isAnimating: Bool) -> State {
        let label: String
        switch analysisStatus {
        case .run: label = isEnabled ? "Analysis running" : "Analysis unavailable — engine loading"
        case .pause: label = isEnabled ? "Analysis paused" : "Analysis unavailable — engine loading"
        case .clear: label = isEnabled ? "Analysis off" : "Analysis unavailable — engine loading"
        }
        return State(symbolName: analysisStatus == .clear ? slashSymbol : sparkleSymbol,
                     isRed: analysisStatus == .clear,
                     showsWarningBadge: false,
                     isEnabled: isEnabled,
                     isAnimating: isAnimating,
                     tap: .cycle,
                     accessibilityLabel: label)
    }
}
