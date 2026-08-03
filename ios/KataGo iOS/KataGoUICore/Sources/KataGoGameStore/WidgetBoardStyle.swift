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
        /// `appGoban` plus the app's **Classic** stone style: the very same
        /// `ShaderLibrary.stone` Metal shader `StoneView` draws, so a board
        /// here is pixel-comparable to the in-app board with Stone Style set
        /// to Classic. The Messages extension uses this; it needs the host
        /// target to compile `Shaders.metal` (the appex does — see
        /// `add_shader_to_messages_target.rb`).
        ///
        /// ⚠️ watchOS has no `ShaderLibrary`/`colorEffect` at all, so this
        /// variant degrades to `appGoban`'s spherical stones there rather
        /// than failing to compile. Nothing on watchOS asks for it today.
        case classicGoban(drawsOwnWood: Bool)
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
    public static func classicGoban(drawsOwnWood: Bool) -> WidgetBoardStyle {
        WidgetBoardStyle(variant: .classicGoban(drawsOwnWood: drawsOwnWood))
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

    public var isClassicGoban: Bool {
        if case .classicGoban = variant { return true }
        return false
    }

    /// Everything `classicGoban` inherits from `appGoban` — the Wood asset,
    /// the plain black grid, the quarter-cell hoshi, the app's coordinate
    /// labels. Only the stones differ between the two.
    public var usesAppBoardSurface: Bool { isAppGoban || isClassicGoban }

    /// The faux-3D goban renderings (millimeter-scaled grid, non-flat stones)
    /// — everything they share hangs off this.
    public var isGobanFamily: Bool { isGoban || isAppGoban || isClassicGoban }

    /// Whether the stones are drawn by the app's `ShaderLibrary.stone` Metal
    /// shader. Only `classicGoban` asks for it, and only where SwiftUI has a
    /// shader to give: watchOS ships no `ShaderLibrary`, so the variant falls
    /// back to the spherical vector stones there instead of failing to build.
    public var usesShaderStones: Bool {
        #if os(watchOS)
        return false
        #else
        return isClassicGoban
        #endif
    }

    /// Stone diameter as a fraction of the cell pitch. The classic variant
    /// uses the app board's exact 0.95 (`Dimensions.stoneLength`) because the
    /// shader's uv constants are calibrated against it — `div4_ratio` is
    /// literally `(1/4)/0.95` — so a 0.92 sprite would put the highlight in
    /// the wrong place. The other variants keep the historical 0.92.
    public var stoneDiameterRatio: Double { isClassicGoban ? 0.95 : 0.92 }

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

    /// The in-app board's fill for the STRONGEST analysis candidate, stated as
    /// RGB rather than as `Color.cyan` — the system cyan is an adaptive
    /// dynamic color and is not this value.
    ///
    /// `AnalysisView` colors each candidate by `analysisBaseColor(visits:
    /// maxVisits:)`. Feed that ramp `visits == maxVisits` and the ratio is 1,
    /// so `fraction = 2 / ((1/1 - 1)^0.9 + 1) = 2`; the `fraction >= 1` branch
    /// gives `hue = 1 - sqrt(2 - 2)/2 = 1`, the discretizer leaves it at 1,
    /// and the final `/ 2` maps it to hue 0.5 at saturation 1, brightness 1 —
    /// i.e. RGB(0, 1, 1). A cached best move is by definition the top move, so
    /// it always lands on this one color and the ramp itself (which lives in
    /// KataGoUICore, above this target) never has to cross module lines.
    public static let bestMoveFill = RGB(red: 0, green: 1, blue: 1)

    /// The opacity `AnalysisView` draws a non-hidden candidate at.
    public static let bestMoveFillOpacity = 0.8

    /// Ring width for the best-move marker, as a ratio of the cell pitch —
    /// `AnalysisView` strokes it at `squareLengthDiv16`.
    public static func bestMoveRingWidth(cellSize: Double) -> Double {
        max(cellSize / 16, 0.5)
    }

    /// Spherical-stone drop shadow, as ratios of the stone diameter. Raised
    /// from 0.30/0.06/0.05: at widget cell sizes that shadow blurred into
    /// the wood and the stones read as flat discs.
    public static let stoneShadowOpacity = 0.42
    public static let stoneShadowRadiusRatio = 0.11
    public static let stoneShadowYOffsetRatio = 0.08

    /// How far a spherical stone's drop shadow reaches beyond the stone, as a
    /// ratio of its diameter. `SphericalStoneLayer` pads its Canvas sprite by
    /// this much, because a Canvas symbol is rasterized at its LAYOUT size and
    /// anything drawn outside is shorn off.
    ///
    /// The blur factor is 6, NOT the textbook 3. Measured 2026-08-04 by
    /// A/B-rendering the batched Canvas against the per-view drawing it
    /// replaced: at a factor of 3 the stones' total ink came out 5.41% LIGHT
    /// against a near-identical 50%-contrast edge radius — i.e. the stone was
    /// the right size but its shadow was being clipped. The gap closes to
    /// 0.05% from a factor of ~5 upward, so SwiftUI's `.shadow(radius:)`
    /// spreads visibly wider than 3x that radius and `radius` is not the
    /// Gaussian sigma. 6 is the smallest verified-converged value with margin.
    ///
    /// Cost of the margin is negligible: a board rasterizes exactly TWO
    /// sprites (one per color) regardless of how many stones it draws.
    public static func stoneShadowExtent(diameter: Double) -> Double {
        diameter * (stoneShadowRadiusRatio * 6 + stoneShadowYOffsetRatio)
    }

    /// The smallest shadow extent measured to render indistinguishably from
    /// the per-view drawing, as a ratio of the stone diameter. Pinned so a
    /// future tightening of `stoneShadowExtent` that would start clipping the
    /// shadow again fails a test instead of shipping.
    public static let stoneShadowExtentFloorRatio = 0.55

    /// The drop shadow the whole BOARD casts, as ratios of the cell pitch —
    /// the app board's own (`BoardLineView` shadows its wood slab with
    /// `radius: squareLength / 16` at an offset of `squareLength / 8`).
    ///
    /// `WidgetBoardView` deliberately does NOT apply this itself: its wood is
    /// full-bleed on a backplate that is often already wood, so it would have
    /// nothing to cast onto. Consumers that float the board on some other
    /// surface — the Messages sheet and its bubble raster — cast it, and they
    /// must cast it from a single opaque rect rather than from the board:
    /// `.shadow` on a composite view shadows every leaf separately, which
    /// would halo each grid line, stone and coordinate label.
    public static func boardShadowRadius(cellSize: Double) -> Double { cellSize / 16 }
    public static func boardShadowOffset(cellSize: Double) -> Double { cellSize / 8 }

    /// How far the shadow reaches beyond the slab, so a caller can guarantee
    /// it room. A surface that cannot reserve this much has to derive the
    /// shadow from a smaller pitch instead, or the shadow is sheared off square
    /// at the clipping edge.
    public static func boardShadowExtent(cellSize: Double) -> Double {
        boardShadowRadius(cellSize: cellSize) * 3 + boardShadowOffset(cellSize: cellSize)
    }

    /// The wood slab would render as one big flat tinted rectangle in accented
    /// mode, so it is dropped and the system tint/glass shows through instead.
    /// The goban variant only draws wood when the backplate isn't already wood.
    public var showsWoodBackground: Bool {
        switch variant {
        case .standard: return true
        case .goban(let drawsOwnWood), .appGoban(let drawsOwnWood),
             .classicGoban(let drawsOwnWood): return drawsOwnWood
        case .accented: return false
        }
    }

    /// Goban wood is the real grain image, not the legacy flat tan color.
    /// (Procedural CGImage — the app-surface variants draw the bundled asset
    /// instead.)
    public var usesWoodImage: Bool { isGoban }

    /// The app-surface variants' wood is the app's bundled "Wood" asset — the
    /// exact texture `BoardLineView` draws — so the board matches the app's.
    public var usesBundledWoodAsset: Bool { usesAppBoardSurface }

    /// Grid + hoshi opacity. Accented mode dims the lines further so the
    /// two-tone stones carry the position; the goban family's lines are
    /// opaque — ink like the texture generator's, or the app's plain black.
    public var gridOpacity: Double {
        switch variant {
        case .standard: return 0.55
        case .goban, .appGoban, .classicGoban: return 1
        case .accented: return 0.35
        }
    }

    /// Goban-family stones render with a radial highlight and drop shadow that
    /// read as the 3D stones; the other variants keep flat discs. The classic
    /// variant hands its stones to the Metal shader instead — except on
    /// watchOS, where `usesShaderStones` is false and this takes over.
    public var stonesAreSpherical: Bool { isGobanFamily && !usesShaderStones }

    /// Grid stroke width for a cell size. The goban family scales the
    /// texture's 0.8 mm line on its 22 mm grid (the app's fixed 1 pt doesn't
    /// scale down to widget cells); the flat consumers keep the historical
    /// 0.5 pt hairline.
    public func gridLineWidth(cellSize: Double) -> Double {
        isGobanFamily ? max(cellSize * 0.8 / 22, 0.5) : 0.5
    }

    /// Hoshi dot diameter for a cell size. The goban scales the texture's
    /// 2 mm-radius star point; the app-surface variants adopt the app board's
    /// quarter-cell dot (`squareLengthDiv4`); the flat consumers keep the
    /// historical 0.16-of-a-cell dot. All keep a legibility floor.
    public func hoshiDiameter(cellSize: Double) -> Double {
        switch variant {
        case .goban: return max(cellSize * 4.0 / 22, 2)
        case .appGoban, .classicGoban: return max(cellSize * 0.25, 2)
        case .standard, .accented: return max(cellSize * 0.16, 2)
        }
    }

    /// The app-surface variants' coordinate labels use the app board's exact
    /// idiom: bold black size-500 text shrunk to fit a cell-sized frame
    /// (`BoardLineView`).
    public var usesAppCoordinateLabels: Bool { usesAppBoardSurface }

    /// Bold labels: the app-surface variants for app parity; accented also
    /// bolds (same weight treatment) while keeping its adaptive light color.
    public var coordinateLabelsAreBold: Bool { usesAppBoardSurface || isAccented }

    /// The classic variant marks the last move the way the app board does
    /// (`MoveNumberView.lastMoveMarker`): a SOLID red dot at 0.3 of the cell.
    /// The other variants keep the historical hollow 0.6-cell ring.
    public var lastMoveIsFilledDot: Bool { isClassicGoban }

    /// Last-move marker diameter for a cell size, paired with the flag above.
    public func lastMoveMarkerDiameter(cellSize: Double) -> Double {
        lastMoveIsFilledDot ? cellSize * 0.3 : cellSize * 0.6
    }

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
