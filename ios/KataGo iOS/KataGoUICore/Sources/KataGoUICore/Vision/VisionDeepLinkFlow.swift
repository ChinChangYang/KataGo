import Foundation

/// Pure gate for applying a latched open-game deep link on visionOS (the
/// widget/URL tap path). A pending link is applied only when the engine is
/// ready AND no boot is in flight; otherwise it stays latched for the boot
/// resolver or the post-ready drain to consume. Deliberately keyed off
/// "not booting" rather than `phase == .ready`: the Games-picker gate lets the
/// user switch out of `.unsupportedBoard`/`.boardTooLarge`, and a widget tap
/// must offer the same way out. Platform-agnostic and in the Vision/ folder so
/// the iOS-simulator test target covers it.
public enum VisionDeepLinkFlow {
    public enum Disposition: Equatable, Sendable {
        case apply, keepLatched, nothingPending
    }

    public static func disposition(hasPending: Bool, isReady: Bool,
                                   isBooting: Bool) -> Disposition {
        guard hasPending else { return .nothingPending }
        return (isReady && !isBooting) ? .apply : .keepLatched
    }
}
