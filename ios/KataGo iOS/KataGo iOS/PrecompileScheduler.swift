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
    public var status: [String: PrecompileStatus] = [:]

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
        status[fileName] = .queued
        Task(priority: .utility) {
            self.status[fileName] = .compiling
            do {
                try await self.worker(fileName)
                self.status[fileName] = .ready
            } catch {
                let summary = (error as NSError).localizedDescription
                log.error("precompile.failed model=\(fileName, privacy: .public) error=\(String(describing: error), privacy: .public)")
                self.status[fileName] = .failed(message: summary)
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

    /// Drop the in-flight set. The underlying detached Tasks were already
    /// cancelled by `CoreMLModelCache.clearAll()` (which cancels its own
    /// `inFlight` map); this just clears the scheduler's bookkeeping so
    /// subsequent enqueues are not dedup-skipped against zombie entries.
    public func cancelAllPending() {
        inFlight.removeAll()
    }
}
