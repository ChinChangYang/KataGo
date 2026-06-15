import Observation

/// Observable bridge between the engine-launch path (which crosses the
/// C++/Swift boundary on a non-MainActor thread) and `LoadingView`'s
/// secondary status string. Producers must hop to MainActor before
/// writing — see spec round 2 §LoadingView status string.
@MainActor @Observable
public final class EngineLaunchStatus {
    public enum Phase: Equatable, Sendable {
        case idle
        case compilingMissFirstLaunch    // "Compiling Core ML model — first launch only"
        case awaitingPrecompile          // "Finishing Core ML compile…"
    }
    public var phase: Phase = .idle
    public init() {}
}
