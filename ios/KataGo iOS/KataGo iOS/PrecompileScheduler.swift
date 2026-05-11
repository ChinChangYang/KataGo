import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "KataGo Anytime",
                         category: "engine.coreml.cache")

/// Per-model precompile state observed by `ModelPickerView`'s row badges.
/// `Equatable, Sendable` so `@Observable` dictionary diffing dedupes
/// identical failure states (round 4 spec fix).
public enum PrecompileStatus: Equatable, Sendable {
    case idle
    case ready
    case queued
    case compiling
    case failed(message: String)
}

/// Schedules background Core ML precompiles. `@MainActor @Observable` so
/// SwiftUI views can bind to `status[fileName]`. Backend-aware: skips
/// enqueues when the model's persisted backend is `.mpsGPU` (no Core ML
/// compile to warm). Dedups by fileName.
@MainActor @Observable
public final class PrecompileScheduler {
    /// Worker called per task. Production wires this to a closure that
    /// invokes the C++/Swift bridge with a `BackendSettings`-derived key
    /// (Task 17/19); tests use a counter closure.
    public typealias Worker = (_ fileName: String) async throws -> Void

    private let defaults: UserDefaults
    private let worker: Worker
    private var inFlight: Set<String> = []
    private var ephemeral: [String: PrecompileStatus] = [:]
    private var cachedReady: Set<String> = []

    /// Merged read-only view used by SwiftUI bindings. Ephemeral states
    /// (queued/compiling/failed) win over cachedReady so users see live
    /// progress even when a stale cachedReady bit could otherwise show.
    public var status: [String: PrecompileStatus] {
        var merged: [String: PrecompileStatus] = [:]
        for fileName in cachedReady { merged[fileName] = .ready }
        for (fileName, state) in ephemeral { merged[fileName] = state }
        return merged
    }

    public init(defaults: UserDefaults = .standard, worker: @escaping Worker) {
        self.defaults = defaults
        self.worker = worker
    }

    /// Enqueue a precompile for the named model. Backend-skipped if the
    /// model's persisted backend is `.mpsGPU`. Dedup-skipped if already
    /// in flight. Otherwise runs the worker on a `.utility` task that
    /// inherits `@MainActor` isolation; status mutations happen on-actor
    /// and the worker's own async suspension takes it off-actor as needed.
    public func scheduleForModel(fileName: String) async {
        if defaults.string(forKey: "backend_\(fileName)") == "mpsGPU" {
            log.info("skip-precompile reason=mpsGPU fileName=\(fileName, privacy: .public)")
            return
        }
        guard !inFlight.contains(fileName) else { return }
        inFlight.insert(fileName)
        ephemeral[fileName] = .queued
        Task(priority: .utility) {
            self.ephemeral[fileName] = .compiling
            do {
                try await self.worker(fileName)
                // Behavior change in Task 10: cachedReady refresh.
                // For now keep the original semantics so this task does
                // not regress views.
                self.ephemeral[fileName] = nil
                self.cachedReady.insert(fileName)
            } catch {
                let summary = (error as NSError).localizedDescription
                log.error("precompile.failed model=\(fileName, privacy: .public) error=\(String(describing: error), privacy: .public)")
                self.ephemeral[fileName] = .failed(message: summary)
            }
            self.inFlight.remove(fileName)
        }
    }

    /// Convenience for the built-in network: delegates to
    /// `scheduleForModel(fileName: "default_model.bin.gz")`. Round-15
    /// backend-guard applies here too.
    public func scheduleBuiltIn() async {
        await scheduleForModel(fileName: "default_model.bin.gz")
    }

    /// Drop the in-flight set and ephemeral live-progress states. Leaves
    /// `cachedReady` intact because compiled-and-cached entries remain
    /// valid after cancellation — the on-disk cache is unchanged. The
    /// underlying detached Tasks were already cancelled by
    /// `CoreMLModelCache.clearAll()` (which cancels its own `inFlight`
    /// map); this just clears the scheduler's bookkeeping so subsequent
    /// enqueues are not dedup-skipped against zombie entries.
    public func cancelAllPending() {
        inFlight.removeAll()
        ephemeral.removeAll()
    }

    // MARK: - Test seams (debug-only; not reachable from release builds)

#if DEBUG
    func _setEphemeralForTests(_ map: [String: PrecompileStatus]) {
        ephemeral = map
    }
    func _setCachedReadyForTests(_ set: Set<String>) {
        cachedReady = set
    }
#endif
}
