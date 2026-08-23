import Observation

/// Observable bridge between the Core ML compile path (which crosses the
/// C++/Swift boundary on a non-MainActor thread) and the inline engine status
/// line's secondary caption. Producers must hop to MainActor before calling —
/// the registration seam in `CoreMLComputeHandleLoader` does that for them.
///
/// The state is a **count, not a flag**. Increments and decrements commute, so
/// a release that lands late — after the next compile has already begun —
/// cannot blank a caption that is currently true. A single assignable field
/// offers no such guarantee, and the stale-clear it allowed is one of the two
/// bugs ADR 0007 fixes.
///
/// The count is **process-wide, not per-launch**: a compile abandoned by a
/// launch the user backed out of is still real work, is still counted, and can
/// therefore light the caption on a later launch that has nothing of its own to
/// compile. That is true rather than precise, which is the trade ADR 0007 makes.
@MainActor @Observable
public final class EngineLaunchStatus {
    /// Core ML compiles currently in flight. Private so the only way to move it
    /// is the balanced `compileBegan()` / `compileEnded()` pair.
    private var activeCompiles = 0

    /// True while at least one Core ML compile is running. The status line
    /// shows its compile caption on exactly this, and on nothing else.
    public var isCompiling: Bool { activeCompiles > 0 }

    public init() {}

    public func compileBegan() {
        activeCompiles += 1
    }

    /// Clamped at zero. The launch-timeout path abandons a compile it cannot
    /// cancel (`CoreMLComputeHandleLoader.loadCoreMLHandleWithBridgeTimeout`),
    /// so that compile's release can arrive long after everything else has
    /// settled. Without the clamp it would drive the count negative and silence
    /// the *next* real compile.
    public func compileEnded() {
        activeCompiles = max(0, activeCompiles - 1)
    }

    /// The secondary caption every launch surface shows: the ADR 0007 string
    /// while a compile is genuinely running, and nothing otherwise. It lives
    /// here, next to the count that decides it, so no surface can spell it
    /// differently. There is no loading SCREEN left on any platform (ADR 0008)
    /// — the one reader is the inline engine-status line, which asks
    /// `EngineStatusText.decide(availability:isCompiling:note:)` for its words
    /// and gets exactly this string back for a *Launching* engine.
    public var compileCaption: String? {
        isCompiling ? EngineStatusText.compilingCaption : nil
    }
}
