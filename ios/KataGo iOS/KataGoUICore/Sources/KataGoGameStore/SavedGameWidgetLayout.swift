import Foundation

/// Content rules for the Saved Game widget, split out of the view so the
/// per-family layouts AND the visionOS distance (level-of-detail) variants are
/// plain data the iOS-hosted tests can pin. The widget view maps
/// `WidgetFamily` / `\.levelOfDetail` into these inputs; the enum deliberately
/// mirrors the four supported families instead of exposing `WidgetFamily`,
/// because `KataGoGameStore` also compiles for tvOS, which has no WidgetKit.
public enum SavedGameWidgetLayout {
    public enum Family: Equatable, Sendable {
        case small, medium, large, extraLarge
    }

    public struct Plan: Equatable, Sendable {
        /// Distance threshold: board + prominent name only.
        public let isSimplified: Bool
        public let showsComment: Bool
        public let showsMoveCount: Bool
        /// Large-type name treatment, exclusive to the simplified threshold.
        public let nameIsProminent: Bool
        /// Coordinate labels around the board. The distance threshold drops
        /// them: from across the room a 5–10 pt label is noise on a view whose
        /// whole point is the stones and the name. `WidgetBoardView` applies
        /// its own cell-pitch gate on top of this, so a nearby board that is
        /// simply too small still hides them.
        public let showsCoordinates: Bool
    }

    /// `isSimplified` is injected (true when `\.levelOfDetail == .simplified`
    /// on visionOS, constant false elsewhere) so tests can reach both variants.
    public static func plan(family: Family, isSimplified: Bool,
                            hasComment: Bool, moveCount: Int) -> Plan {
        if isSimplified {
            return Plan(isSimplified: true, showsComment: false,
                        showsMoveCount: false, nameIsProminent: true,
                        showsCoordinates: false)
        }
        switch family {
        case .small:
            // Board + caption name only.
            return Plan(isSimplified: false, showsComment: false,
                        showsMoveCount: false, nameIsProminent: false,
                        showsCoordinates: true)
        case .medium, .large:
            // Comment shown iff the displayed move has one; no move count.
            return Plan(isSimplified: false, showsComment: hasComment,
                        showsMoveCount: false, nameIsProminent: false,
                        showsCoordinates: true)
        case .extraLarge:
            // Comment iff non-empty, "Move N" iff any move is displayed.
            return Plan(isSimplified: false, showsComment: hasComment,
                        showsMoveCount: moveCount > 0, nameIsProminent: false,
                        showsCoordinates: true)
        }
    }
}
