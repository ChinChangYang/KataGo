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
    }

    /// `isSimplified` is injected (true when `\.levelOfDetail == .simplified`
    /// on visionOS, constant false elsewhere) so tests can reach both variants.
    public static func plan(family: Family, isSimplified: Bool,
                            hasComment: Bool, moveCount: Int) -> Plan {
        if isSimplified {
            return Plan(isSimplified: true, showsComment: false,
                        showsMoveCount: false, nameIsProminent: true)
        }
        switch family {
        case .small:
            // Board + caption name only.
            return Plan(isSimplified: false, showsComment: false,
                        showsMoveCount: false, nameIsProminent: false)
        case .medium, .large:
            // Comment shown iff the displayed move has one; no move count.
            return Plan(isSimplified: false, showsComment: hasComment,
                        showsMoveCount: false, nameIsProminent: false)
        case .extraLarge:
            // Comment iff non-empty, "Move N" iff any move is displayed.
            return Plan(isSimplified: false, showsComment: hasComment,
                        showsMoveCount: moveCount > 0, nameIsProminent: false)
        }
    }
}
