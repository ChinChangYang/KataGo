import Foundation

/// Distinguishes the main app process from an app-extension process (the widget
/// and its configuration intent). An app extension is a SECOND sandbox over the
/// same CloudKit-synced App-Group store, so it must never create, migrate, or
/// write that store — only the main app does. Lifted here from
/// `GameEntityQuery.isAppExtension` so both `GameEntity` and
/// `SharedModelContainer` share one detector.
public enum ProcessKind {
    /// True when running inside an app extension (packaged as a `.appex` bundle);
    /// the host app is not.
    public static var isAppExtension: Bool {
        isAppExtension(bundlePath: Bundle.main.bundlePath)
    }

    /// Pure, injectable form for testing.
    public static func isAppExtension(bundlePath: String) -> Bool {
        bundlePath.hasSuffix(".appex")
    }
}
