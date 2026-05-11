import Foundation
import KataGoInterface
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
    private let cache: CoreMLModelCache?
    private let digestFor: ((String) async throws -> String?)?
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
        self.cache = nil
        self.digestFor = nil
    }

    public init(
        defaults: UserDefaults = .standard,
        worker: @escaping Worker,
        cache: CoreMLModelCache,
        digestFor: @escaping (String) async throws -> String?
    ) {
        self.defaults = defaults
        self.worker = worker
        self.cache = cache
        self.digestFor = digestFor
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
                self.ephemeral[fileName] = nil
                await self.refreshCachedReady(for: fileName)
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

    private func refreshCachedReady(for fileName: String) async {
        guard let cache, let digestFor else {
            // Legacy init path: preserve original unconditional-insert
            // semantics so older tests don't regress.
            cachedReady.insert(fileName)
            return
        }
        do {
            guard let digest = try await digestFor(fileName) else {
                cachedReady.remove(fileName); return
            }
            if await cache.hasEntry(digest: digest) {
                cachedReady.insert(fileName)
            } else {
                cachedReady.remove(fileName)
            }
        } catch {
            log.info("refreshCachedReady.digestFailed fileName=\(fileName, privacy: .public) error=\(String(describing: error), privacy: .public)")
            cachedReady.remove(fileName)
        }
    }

    /// Replace cachedReady with the subset of `fileNames` whose projected
    /// digest is currently in the cache. Each fileName is wrapped so one
    /// failure does not abort the rest. Ephemeral state is untouched.
    public func hydrate(
        from cache: CoreMLModelCache,
        fileNames: Set<String>,
        digestFor: @escaping (String) async throws -> String?
    ) async {
        var fresh: Set<String> = []
        for fileName in fileNames {
            do {
                guard let digest = try await digestFor(fileName) else { continue }
                if await cache.hasEntry(digest: digest) {
                    fresh.insert(fileName)
                }
            } catch {
                // Hash / hasher failures during hydration are non-fatal.
                // Treat as "not ready" rather than surfacing in the badge.
                log.info("hydrate.digestFailed fileName=\(fileName, privacy: .public) error=\(String(describing: error), privacy: .public)")
                continue
            }
        }
        // Race-tolerant update: a concurrent worker that completes between
        // hydrate's last await and this assignment must not be clobbered.
        // Drop only the fileNames in the hydration set that are no longer
        // in the cache (the "evicted" case), then union in the fresh ones.
        // Entries outside `fileNames` are not the hydration target — leave them.
        for fileName in fileNames where !fresh.contains(fileName) {
            cachedReady.remove(fileName)
        }
        cachedReady.formUnion(fresh)
    }

    private var didSubscribe = false

    /// Start a long-lived task that consumes `cache.indexEvents` and
    /// re-hydrates `cachedReady` after each tick. Guarded so repeated
    /// calls (e.g., scene `.task` re-firing) are no-ops.
    public func subscribeToCacheEvents(
        _ cache: CoreMLModelCache,
        fileNames: Set<String>,
        digestFor: @escaping (String) async throws -> String?
    ) async {
        guard !didSubscribe else { return }
        didSubscribe = true
        // Register the stream synchronously (from the cache actor's POV) on
        // this call. This guarantees the continuation is installed before
        // we return — callers that fire a mutation right after subscribing
        // (e.g., the cacheEventTick test, or the post-init hydrate kick) are
        // guaranteed to see the resulting event.
        let stream = await cache.indexEvents
        Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.hydrate(from: cache, fileNames: fileNames, digestFor: digestFor)
#if DEBUG
                self._fireHydrateTickForTests()
#endif
            }
        }
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

    private var _hydrateTickContinuations: [AsyncStream<Void>.Continuation] = []

    /// Emits one element each time the cache-event consumer finishes a
    /// hydrate pass. Lets tests await a tick deterministically instead of
    /// polling against a wall-clock deadline.
    func _hydrateTickStreamForTests() -> AsyncStream<Void> {
        AsyncStream { continuation in
            _hydrateTickContinuations.append(continuation)
        }
    }

    func _fireHydrateTickForTests() {
        for c in _hydrateTickContinuations { c.yield() }
    }
#endif
}
