import Foundation

/// Scheduling policy for the Saved Game widget's timeline.
///
/// The widget extension is a separate process and cannot observe CloudKit
/// changes mirrored in from another device, nor in-app edits beyond the
/// `WidgetCenter.reloadAllTimelines` calls the app makes. To keep the displayed
/// game (name / first comment / board) from going stale indefinitely, the
/// timeline schedules a periodic reload that re-resolves the snapshot from the
/// shared store. Replaces the previous `policy: .never`.
public enum WidgetReloadPolicy {
    /// How long a rendered widget entry stays valid before WidgetKit is asked to
    /// reload it. One hour keeps cross-device edits reasonably fresh while
    /// staying well inside WidgetKit's daily refresh budget.
    public static let refreshInterval: TimeInterval = 60 * 60

    /// The date at which the widget should next reload, given the entry's date.
    public static func nextReloadDate(after date: Date) -> Date {
        date.addingTimeInterval(refreshInterval)
    }
}
