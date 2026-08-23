import Foundation

/// Pure gate for applying a latched open-game deep link on visionOS (the
/// widget/URL tap path).
///
/// It waits for exactly one thing: a RESOLVED SELECTION. Before
/// `resolveAndMountCurrentGame` has picked a record the latch must stay put —
/// that resolver consumes it, so applying here would race its consumption — and
/// after it, the tap applies immediately.
///
/// The engine is deliberately not part of this any more. It used to be ("apply
/// only when the engine is ready and no boot is in flight"), which latched a tap
/// for the whole of a cold Core ML compile even though switching games needs no
/// engine at all: the board is record-owned, and a feed offered to a shut gate is
/// dropped and repaid by the handshake's resync. Blocked boards are no exception
/// — an unsupported board is the one thing the volume cannot draw, and a widget
/// tap has to be a way out of it.
///
/// Platform-agnostic and in the Vision/ folder so the iOS-simulator test target
/// covers it.
public enum VisionDeepLinkFlow {
    public enum Disposition: Equatable, Sendable {
        case apply, keepLatched, nothingPending
    }

    public static func disposition(hasPending: Bool,
                                   hasResolvedSelection: Bool) -> Disposition {
        guard hasPending else { return .nothingPending }
        return hasResolvedSelection ? .apply : .keepLatched
    }
}
