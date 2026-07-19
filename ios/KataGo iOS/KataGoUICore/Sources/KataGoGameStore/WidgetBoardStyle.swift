import Foundation

/// Resolved drawing decisions for `WidgetBoardView`. `.standard` is the
/// historical full-color rendering; `.accented` is the two-tone adaptation for
/// the widget accented/tinted rendering mode (visionOS tint palettes, iOS
/// tinted Home Screen, macOS tinted widgets). Platform-neutral on purpose: the
/// widget view resolves `\.widgetRenderingMode` and passes a style in, so this
/// type never touches WidgetKit and stays buildable (and testable) everywhere
/// `KataGoGameStore` compiles, including tvOS which has no WidgetKit.
public struct WidgetBoardStyle: Equatable, Sendable {
    public let isAccented: Bool

    public static let standard = WidgetBoardStyle(isAccented: false)
    public static let accented = WidgetBoardStyle(isAccented: true)

    /// The wood slab would render as one big flat tinted rectangle in accented
    /// mode, so it is dropped and the system tint/glass shows through instead.
    public var showsWoodBackground: Bool { !isAccented }

    /// Grid + hoshi opacity. Accented mode dims the lines further so the
    /// two-tone stones carry the position against the tinted backdrop.
    public var gridOpacity: Double { isAccented ? 0.35 : 0.55 }

    /// Accented mode renders black stones as SOLID accent-colored discs
    /// (a full-luminance fill handed to the system tint via widgetAccentable).
    public var blackStoneIsAccentFill: Bool { isAccented }

    /// Accented mode renders white stones as accent-colored OUTLINES over a
    /// faint neutral interior — a different treatment from black by design, so
    /// the two colors stay distinguishable under any single tint.
    public var whiteStoneIsAccentOutline: Bool { isAccented }

    /// The green/yellow/orange candidate-rank hues are meaningless once the
    /// system supplies one tint; accented mode conveys rank by opacity instead.
    public var usesRankHueDots: Bool { !isAccented }

    /// Candidate-dot opacity for a 0-based rank (0 = strongest move). Standard
    /// mode keeps dots fully opaque (rank is the hue). Accented mode steps the
    /// opacity down and clamps past the third rank, mirroring the historical
    /// `min(rank, rankColors.count - 1)` hue clamp.
    public func candidateDotOpacity(rank: Int) -> Double {
        guard isAccented else { return 1 }
        let steps: [Double] = [0.9, 0.65, 0.45]
        return steps[min(max(rank, 0), steps.count - 1)]
    }
}
