import Foundation

public extension Bundle {
    /// The KataGoGameStore package resource bundle. Home of the app's board
    /// wood texture ("Wood"), which lives at the bottom of the bridge-free
    /// dependency stack so the widget appex and the in-app boards
    /// (BoardLineView) draw the SAME asset. `Bundle.module` is internal
    /// per-target, hence this public door.
    static var kataGoGameStore: Bundle { .module }
}
