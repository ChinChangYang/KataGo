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
        /// The two WIDE families (medium, extraLarge) hand the board the
        /// container's full height and set the name BESIDE it, because with the
        /// comment switched off their trailing column has nothing left to
        /// justify the width it holds.
        ///
        /// False for `small` (it never showed a comment, so there is nothing to
        /// reclaim) and false for `large`, whose board already carries
        /// `.frame(maxHeight: .infinity)` and absorbs the comment's height on
        /// its own with no flag.
        ///
        /// Keyed on the SETTING, never on `showsComment`. A move that merely
        /// has no comment must keep rendering exactly as it does today — using
        /// the outcome here would silently relayout every comment-less move on
        /// medium/extraLarge for users who never touched the switch.
        public let boardFillsHeight: Bool
    }

    /// `isSimplified` is injected (true when `\.levelOfDetail == .simplified`
    /// on visionOS, constant false elsewhere) so tests can reach both variants.
    ///
    /// `commentIsEnabled` is the user's Edit Widget "Show Comment" switch,
    /// injected the same way. Neither takes a default value, so every call site
    /// — and every test — has to state both axes on purpose: a default here
    /// would let a missed plumbing edit disappear into it, which is the exact
    /// shape of the bug `SelectGameIntent`'s doc comments record.
    ///
    /// Switching the comment off is a MODE, not merely "this move has no
    /// comment": it also reclaims the space, which is why `boardFillsHeight`
    /// and the extra-large "Move N" key off `commentIsEnabled` and NOT off
    /// `showsComment`.
    public static func plan(family: Family, isSimplified: Bool,
                            commentIsEnabled: Bool,
                            hasComment: Bool, moveCount: Int) -> Plan {
        // The distance threshold wins outright and is evaluated FIRST: it
        // already drops the comment, and additionally asks for the prominent
        // name and no coordinates. The switch must not reach into that
        // treatment, so it is applied only below this return.
        if isSimplified {
            return Plan(isSimplified: true, showsComment: false,
                        showsMoveCount: false, nameIsProminent: true,
                        showsCoordinates: false, boardFillsHeight: false)
        }
        switch family {
        case .small:
            // Board + caption name only.
            return Plan(isSimplified: false, showsComment: false,
                        showsMoveCount: false, nameIsProminent: false,
                        showsCoordinates: true, boardFillsHeight: false)
        case .large:
            // Comment shown iff enabled AND the displayed move has one; no move
            // count. No `boardFillsHeight`: the large board is already the only
            // height-flexible child of its VStack, so dropping the comment Text
            // hands it those rows with no flag.
            return Plan(isSimplified: false,
                        showsComment: commentIsEnabled && hasComment,
                        showsMoveCount: false, nameIsProminent: false,
                        showsCoordinates: true, boardFillsHeight: false)
        case .medium:
            return Plan(isSimplified: false,
                        showsComment: commentIsEnabled && hasComment,
                        showsMoveCount: false, nameIsProminent: false,
                        showsCoordinates: true,
                        boardFillsHeight: !commentIsEnabled)
        case .extraLarge:
            // Comment iff enabled and non-empty. "Move N" goes WITH the comment:
            // with the switch off the trailing column is just the name.
            return Plan(isSimplified: false,
                        showsComment: commentIsEnabled && hasComment,
                        showsMoveCount: commentIsEnabled && moveCount > 0,
                        nameIsProminent: false, showsCoordinates: true,
                        boardFillsHeight: !commentIsEnabled)
        }
    }
}
