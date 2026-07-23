import Foundation

/// Resolved drawing decisions for `WidgetBoardView`. `.standard` is the
/// historical full-color rendering the watch, Messages, and TV consumers
/// still use; `.goban` is the Saved Game widget's faux-3D match of the
/// in-app goban (real wood grain, ink grid, spherical stones); `.accented`
/// is the two-tone adaptation for the widget accented/tinted rendering mode
/// (visionOS tint palettes, iOS tinted Home Screen, macOS tinted widgets).
/// Platform-neutral on purpose: the widget view resolves
/// `\.widgetRenderingMode` and passes a style in, so this type never touches
/// WidgetKit and stays buildable (and testable) everywhere `KataGoGameStore`
/// compiles, including tvOS which has no WidgetKit.
public struct WidgetBoardStyle: Equatable, Sendable {
    public enum Variant: Equatable, Sendable {
        case standard
        /// `drawsOwnWood: false` when the widget backplate already IS the
        /// wood (full-bleed Wood background) — one wood surface at a time,
        /// so the board and its margins can never show a grain seam.
        case goban(drawsOwnWood: Bool)
        /// The iOS/macOS (and tvOS in-app) miniature of the in-app 2D goban:
        /// the bundled "Wood" asset instead of the procedural grain, opaque
        /// black grid/hoshi, and the app's bold shrink-to-fit coordinate
        /// labels. `.goban` stays byte-identical for visionOS.
        case appGoban(drawsOwnWood: Bool)
        case accented
    }

    public let variant: Variant

    public static let standard = WidgetBoardStyle(variant: .standard)
    public static let accented = WidgetBoardStyle(variant: .accented)
    public static func goban(drawsOwnWood: Bool) -> WidgetBoardStyle {
        WidgetBoardStyle(variant: .goban(drawsOwnWood: drawsOwnWood))
    }
    public static func appGoban(drawsOwnWood: Bool) -> WidgetBoardStyle {
        WidgetBoardStyle(variant: .appGoban(drawsOwnWood: drawsOwnWood))
    }

    public var isAccented: Bool { variant == .accented }

    public var isGoban: Bool {
        if case .goban = variant { return true }
        return false
    }

    public var isAppGoban: Bool {
        if case .appGoban = variant { return true }
        return false
    }

    /// The two faux-3D goban renderings (spherical stones, millimeter-scaled
    /// grid) — everything they share hangs off this.
    public var isGobanFamily: Bool { isGoban || isAppGoban }

    /// The exact palette of `BoardTopTexture`: grid/hoshi ink RGB(95, 65, 25)
    /// composited over wood around RGB(216, 185, 92). The vector grid uses the
    /// same ink, and the no-image fallback the same wood, so the two renderers
    /// always agree.
    public struct RGB: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public static let gobanInk = RGB(red: 95 / 255, green: 65 / 255, blue: 25 / 255)
    public static let gobanWood = RGB(red: 216 / 255, green: 185 / 255, blue: 92 / 255)

    /// Spherical-stone drop shadow, as ratios of the stone diameter. Raised
    /// from 0.30/0.06/0.05: at widget cell sizes that shadow blurred into
    /// the wood and the stones read as flat discs.
    public static let stoneShadowOpacity = 0.42
    public static let stoneShadowRadiusRatio = 0.11
    public static let stoneShadowYOffsetRatio = 0.08

    /// The wood slab would render as one big flat tinted rectangle in accented
    /// mode, so it is dropped and the system tint/glass shows through instead.
    /// The goban variant only draws wood when the backplate isn't already wood.
    public var showsWoodBackground: Bool {
        switch variant {
        case .standard: return true
        case .goban(let drawsOwnWood), .appGoban(let drawsOwnWood): return drawsOwnWood
        case .accented: return false
        }
    }

    /// Goban wood is the real grain image, not the legacy flat tan color.
    /// (Procedural CGImage — appGoban draws the bundled asset instead.)
    public var usesWoodImage: Bool { isGoban }

    /// appGoban wood is the app's bundled "Wood" asset — the exact texture
    /// `BoardLineView` draws — so the widget board matches the in-app board.
    public var usesBundledWoodAsset: Bool { isAppGoban }

    /// Grid + hoshi opacity. Accented mode dims the lines further so the
    /// two-tone stones carry the position; the goban family's lines are
    /// opaque — ink like the texture generator's, or the app's plain black.
    public var gridOpacity: Double {
        switch variant {
        case .standard: return 0.55
        case .goban, .appGoban: return 1
        case .accented: return 0.35
        }
    }

    /// Goban-family stones render with a radial highlight and drop shadow that
    /// read as the 3D stones; the other variants keep flat discs.
    public var stonesAreSpherical: Bool { isGobanFamily }

    /// Grid stroke width for a cell size. The goban family scales the
    /// texture's 0.8 mm line on its 22 mm grid (the app's fixed 1 pt doesn't
    /// scale down to widget cells); the flat consumers keep the historical
    /// 0.5 pt hairline.
    public func gridLineWidth(cellSize: Double) -> Double {
        isGobanFamily ? max(cellSize * 0.8 / 22, 0.5) : 0.5
    }

    /// Hoshi dot diameter for a cell size. The goban scales the texture's
    /// 2 mm-radius star point; appGoban adopts the app board's quarter-cell
    /// dot (`squareLengthDiv4`); the flat consumers keep the historical
    /// 0.16-of-a-cell dot. All keep a legibility floor.
    public func hoshiDiameter(cellSize: Double) -> Double {
        switch variant {
        case .goban: return max(cellSize * 4.0 / 22, 2)
        case .appGoban: return max(cellSize * 0.25, 2)
        case .standard, .accented: return max(cellSize * 0.16, 2)
        }
    }

    /// appGoban coordinate labels use the app board's exact idiom: bold black
    /// size-500 text shrunk to fit a cell-sized frame (`BoardLineView`).
    public var usesAppCoordinateLabels: Bool { isAppGoban }

    /// Bold labels: appGoban for app parity; accented also bolds (same weight
    /// treatment) while keeping its adaptive light color.
    public var coordinateLabelsAreBold: Bool { isAppGoban || isAccented }

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
    /// and goban keep dots fully opaque (rank is the hue). Accented mode steps
    /// the opacity down and clamps past the third rank, mirroring the historical
    /// `min(rank, rankColors.count - 1)` hue clamp.
    public func candidateDotOpacity(rank: Int) -> Double {
        guard isAccented else { return 1 }
        let steps: [Double] = [0.9, 0.65, 0.45]
        return steps[min(max(rank, 0), steps.count - 1)]
    }
}
