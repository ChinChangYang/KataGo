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
/// visionOS, where the glass texture composites content over DARK glass), so
/// the whole matrix stays testable from the iOS simulator suite.
public enum WidgetBackgroundPlan {
    public enum Backplate: Equatable, Sendable {
        case wood, glass, light, dark
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
        /// Dark ink on a light surface (wood/light) vs bright text (glass/dark).
        public let textIsInk: Bool
        public let boardStyle: WidgetBoardStyle
    }

    public static func resolve(background: SavedGameBackground,
                               isAccented: Bool,
                               glassPrefersDarkScheme: Bool) -> Plan {
        if isAccented {
            return Plan(backplate: .neutralAccent,
                        colorSchemePin: glassPrefersDarkScheme ? .dark : nil,
                        boardDrawsOwnWood: false,
                        textIsInk: false,
                        boardStyle: .accented)
        }
        switch background {
        case .wood:
            return Plan(backplate: .wood,
                        colorSchemePin: .light,
                        boardDrawsOwnWood: false,
                        textIsInk: true,
                        boardStyle: .goban(drawsOwnWood: false))
        case .glass:
            return Plan(backplate: .glass,
                        colorSchemePin: glassPrefersDarkScheme ? .dark : nil,
                        boardDrawsOwnWood: true,
                        textIsInk: false,
                        boardStyle: .goban(drawsOwnWood: true))
        case .light:
            return Plan(backplate: .light,
                        colorSchemePin: .light,
                        boardDrawsOwnWood: true,
                        textIsInk: true,
                        boardStyle: .goban(drawsOwnWood: true))
        case .dark:
            return Plan(backplate: .dark,
                        colorSchemePin: .dark,
                        boardDrawsOwnWood: true,
                        textIsInk: false,
                        boardStyle: .goban(drawsOwnWood: true))
        }
    }
}
