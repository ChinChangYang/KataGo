/// The one authority for how the Saved Game widget dresses itself: which
/// backplate fills `containerBackground`, whether the color scheme is pinned
/// (so text contrast is deterministic per backplate instead of inherited from
/// a scheme that may not match what's actually behind the labels — the
/// generalization of the visionOS glass black-on-black fix), whether the
/// board renders its own wood card, and which `WidgetBoardStyle` it draws in.
///
/// Tint wins: in the accented rendering mode the system recolors the widget
/// with the user's palette, so the background choice is set aside entirely
/// and the pre-existing two-tone accent treatment takes over unchanged.
///
/// Platform variance is injected (`glassPrefersDarkScheme` is true only on
/// visionOS, where the widget's system glass texture composites content over
/// DARK glass — only the accented plan still composites over it), so the
/// whole matrix stays testable from the iOS simulator suite.
public enum WidgetBackgroundPlan {
    public enum Backplate: Equatable, Sendable {
        case wood, light, dark
        /// A full-bleed procedural texture (`WidgetBackplateTexture`) the
        /// board's own wood card sits on.
        case material(WidgetBackplateMaterial)
        /// The neutral system material behind the accent-tinted board.
        case neutralAccent
    }

    public enum SchemePin: Equatable, Sendable {
        case light, dark
    }

    public struct Plan: Equatable, Sendable {
        public let backplate: Backplate
        /// nil = inherit the environment scheme (adaptive).
        public let colorSchemePin: SchemePin?
        /// Whether the board draws its own wood card. False for the full-bleed
        /// Wood backplate — one wood surface at a time, so no grain seam can
        /// exist between the board and its margins.
        public let boardDrawsOwnWood: Bool
        /// Dark ink on a light surface (wood/light/tatami/sky) vs bright
        /// text on a dark one (dark/grass/slate).
        public let textIsInk: Bool
        public let boardStyle: WidgetBoardStyle
    }

    /// `usesAppBoardStyle` is the injected platform variance (like
    /// `glassPrefersDarkScheme`): true on iOS/macOS, where every non-accented
    /// plan swaps its `.goban` board for the app-parity `.appGoban` — same
    /// `drawsOwnWood` wiring, so the no-seam rule is untouched. visionOS
    /// passes false and keeps the goban-palette look. The accented plan
    /// ignores the flag: tint wins.
    public static func resolve(background: SavedGameBackground,
                               isAccented: Bool,
                               glassPrefersDarkScheme: Bool,
                               usesAppBoardStyle: Bool) -> Plan {
        if isAccented {
            return Plan(backplate: .neutralAccent,
                        colorSchemePin: glassPrefersDarkScheme ? .dark : nil,
                        boardDrawsOwnWood: false,
                        textIsInk: false,
                        boardStyle: .accented)
        }
        func boardStyle(drawsOwnWood: Bool) -> WidgetBoardStyle {
            usesAppBoardStyle
                ? .appGoban(drawsOwnWood: drawsOwnWood)
                : .goban(drawsOwnWood: drawsOwnWood)
        }
        switch background {
        case .wood:
            return Plan(backplate: .wood,
                        colorSchemePin: .light,
                        boardDrawsOwnWood: false,
                        textIsInk: true,
                        boardStyle: boardStyle(drawsOwnWood: false))
        case .grass:
            return materialPlan(.grass, pin: .dark, boardStyle: boardStyle(drawsOwnWood: true))
        case .tatami:
            return materialPlan(.tatami, pin: .light, boardStyle: boardStyle(drawsOwnWood: true))
        case .slate:
            return materialPlan(.slate, pin: .dark, boardStyle: boardStyle(drawsOwnWood: true))
        case .sky:
            return materialPlan(.sky, pin: .light, boardStyle: boardStyle(drawsOwnWood: true))
        case .light:
            return Plan(backplate: .light,
                        colorSchemePin: .light,
                        boardDrawsOwnWood: true,
                        textIsInk: true,
                        boardStyle: boardStyle(drawsOwnWood: true))
        case .dark:
            return Plan(backplate: .dark,
                        colorSchemePin: .dark,
                        boardDrawsOwnWood: true,
                        textIsInk: false,
                        boardStyle: boardStyle(drawsOwnWood: true))
        }
    }

    /// A goban resting on the material: full-bleed texture backplate, the
    /// board as its own wood card, and the scheme pinned for legibility over
    /// that material — ink text over the pale ones, bright over the dark.
    private static func materialPlan(_ material: WidgetBackplateMaterial,
                                     pin: SchemePin,
                                     boardStyle: WidgetBoardStyle) -> Plan {
        Plan(backplate: .material(material),
             colorSchemePin: pin,
             boardDrawsOwnWood: true,
             textIsInk: pin == .light,
             boardStyle: boardStyle)
    }
}
