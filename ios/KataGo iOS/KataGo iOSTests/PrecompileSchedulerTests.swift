import Foundation
import Testing
import KataGoInterface
@testable import KataGo_Anytime

struct PrecompileSchedulerTests {
    @MainActor
    @Test func ephemeralStateAndCachedReadyMergeCorrectly() async throws {
        let scheduler = PrecompileScheduler(worker: { _ in })
        scheduler._setEphemeralForTests(["a.bin.gz": .compiling])
        scheduler._setCachedReadyForTests(["b.bin.gz", "a.bin.gz"])

        // Ephemeral wins where both exist.
        #expect(scheduler.status["a.bin.gz"] == .compiling)
        // CachedReady fills in where ephemeral is absent.
        #expect(scheduler.status["b.bin.gz"] == .ready)
        // Unknown remains nil (badge resolves to .idle via the ?? .idle
        // fallback at the call site).
        #expect(scheduler.status["c.bin.gz"] == nil)
    }


    @Test func skipsWhenBackendIsMpsGpu() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        defaults.set("mpsGPU", forKey: "backend_default_model.bin.gz")

        actor Counter { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()
        let scheduler = await PrecompileScheduler(defaults: defaults) { _ in
            await counter.inc()
        }
        await scheduler.scheduleForModel(fileName: "default_model.bin.gz")

        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.get() == 0)
    }

    @Test func runsWhenBackendIsCoreml() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        defaults.set("coremlNE", forKey: "backend_default_model.bin.gz")

        actor Counter { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()
        let scheduler = await PrecompileScheduler(defaults: defaults) { _ in
            await counter.inc()
        }
        await scheduler.scheduleForModel(fileName: "default_model.bin.gz")

        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.get() == 1)
    }

    @Test func dedupesIdenticalEnqueues() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        defaults.set("coremlNE", forKey: "backend_default_model.bin.gz")

        actor Counter { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()
        let scheduler = await PrecompileScheduler(defaults: defaults) { _ in
            await counter.inc()
            try? await Task.sleep(for: .milliseconds(50))
        }
        async let a: Void = scheduler.scheduleForModel(fileName: "default_model.bin.gz")
        async let b: Void = scheduler.scheduleForModel(fileName: "default_model.bin.gz")
        _ = await (a, b)
        try await Task.sleep(for: .milliseconds(120))
        #expect(await counter.get() == 1)
    }

    @Test func hydratePopulatesCachedReadyFromCache() async throws {
        // Stand up a real CoreMLModelCache over a temp dir, install one entry.
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = CoreMLModelCache(cacheRoot: root)
        await cache.ensureCacheTreeExistsForTests()

        let pinned = try await cache.urlForKey(digest: "fake-digest", missCallback: {
            let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
            return u
        })
        await pinned.release()

        let scheduler = await PrecompileScheduler(worker: { _ in })
        let knownFileNames: Set<String> = ["match.bin.gz", "missing.bin.gz"]
        await scheduler.hydrate(
            from: cache,
            fileNames: knownFileNames,
            digestFor: { fileName in
                fileName == "match.bin.gz" ? "fake-digest" : nil
            })

        #expect(await scheduler.status["match.bin.gz"] == .ready)
        #expect(await scheduler.status["missing.bin.gz"] == nil)
    }

    @Test func hydrateDoesNotClobberConcurrentInsertsOutsideFileNamesSet() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = CoreMLModelCache(cacheRoot: root)
        await cache.ensureCacheTreeExistsForTests()

        let scheduler = await PrecompileScheduler(worker: { _ in })
        // Simulate a concurrent worker that has already marked "other.bin.gz"
        // as ready. Hydrate should NOT erase it because it's outside the
        // fileNames set passed to hydrate.
        await scheduler._setCachedReadyForTests(["other.bin.gz"])

        let knownFileNames: Set<String> = ["match.bin.gz"]
        await scheduler.hydrate(
            from: cache,
            fileNames: knownFileNames,
            digestFor: { _ in nil })  // nothing matches the empty cache

        #expect(await scheduler.status["other.bin.gz"] == .ready)   // preserved
        #expect(await scheduler.status["match.bin.gz"] == nil)      // not in cache
    }

    @Test func cacheEventTickRefreshesCachedReady() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = CoreMLModelCache(cacheRoot: root)
        await cache.ensureCacheTreeExistsForTests()

        let scheduler = await PrecompileScheduler(worker: { _ in })
        await scheduler._setCachedReadyForTests(["a.bin.gz"])  // stale

        // Install the tick observer before subscribing so we never miss
        // the first hydrate that follows clearAll().
        var ticks = await scheduler._hydrateTickStreamForTests().makeAsyncIterator()

        let knownFileNames: Set<String> = ["a.bin.gz"]
        await scheduler.subscribeToCacheEvents(
            cache,
            fileNames: knownFileNames,
            digestFor: { _ in "absent-digest" })

        // Trigger a tick. cachedReady should drop "a.bin.gz" because
        // the digest is not in the cache.
        await cache.clearAll()

        // Deterministic wait: resume only after the consumer task has
        // finished one hydrate pass. Replaces a 500ms wall-clock poll
        // that flaked under Xcode Cloud load.
        _ = await ticks.next()

        #expect(await scheduler.status["a.bin.gz"] == nil)
    }

    @MainActor
    @Test func workerSuccessReflectsCacheState() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = CoreMLModelCache(cacheRoot: root)
        await cache.ensureCacheTreeExistsForTests()

        // Pre-install the digest the worker is supposed to warm.
        let pinned = try await cache.urlForKey(digest: "real-digest", missCallback: {
            let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
            return u
        })
        await pinned.release()

        let scheduler = PrecompileScheduler(
            worker: { _ in /* simulate successful warm */ },
            cache: cache,
            digestFor: { fileName in
                fileName == "real.bin.gz" ? "real-digest" : nil
            })
        UserDefaults.standard.set("coremlNE", forKey: "backend_real.bin.gz")

        await scheduler.scheduleForModel(fileName: "real.bin.gz")

        // Poll until the worker completes or a 500ms deadline elapses.
        let deadline1 = ContinuousClock.now + .milliseconds(500)
        while scheduler.status["real.bin.gz"] != .ready && ContinuousClock.now < deadline1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(scheduler.status["real.bin.gz"] == .ready)

        // Worker for a fileName the cache does not contain leaves cachedReady untouched.
        UserDefaults.standard.set("coremlNE", forKey: "backend_ghost.bin.gz")
        await scheduler.scheduleForModel(fileName: "ghost.bin.gz")

        let deadline2 = ContinuousClock.now + .milliseconds(500)
        while (scheduler.status["ghost.bin.gz"] == .compiling
               || scheduler.status["ghost.bin.gz"] == .queued)
              && ContinuousClock.now < deadline2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(scheduler.status["ghost.bin.gz"] == nil)

        UserDefaults.standard.removeObject(forKey: "backend_real.bin.gz")
        UserDefaults.standard.removeObject(forKey: "backend_ghost.bin.gz")
    }

    @Test func hydrateRemovesEvictedEntriesInsideFileNamesSet() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = CoreMLModelCache(cacheRoot: root)
        await cache.ensureCacheTreeExistsForTests()

        let scheduler = await PrecompileScheduler(worker: { _ in })
        // Pretend "a.bin.gz" was previously cachedReady but its cache entry
        // has since been evicted.
        await scheduler._setCachedReadyForTests(["a.bin.gz"])

        let knownFileNames: Set<String> = ["a.bin.gz"]
        await scheduler.hydrate(
            from: cache,
            fileNames: knownFileNames,
            digestFor: { _ in "stale-digest" })  // cache is empty → hasEntry false

        #expect(await scheduler.status["a.bin.gz"] == nil)
    }

    @MainActor
    @Test func cancelAllPendingPreservesCachedReady() async throws {
        let scheduler = PrecompileScheduler(worker: { _ in })
        scheduler._setCachedReadyForTests(["a.bin.gz"])
        scheduler._setEphemeralForTests(["b.bin.gz": .compiling])

        scheduler.cancelAllPending()

        // cachedReady survives — compiled entries on disk are still valid.
        #expect(scheduler.status["a.bin.gz"] == .ready)
        // Ephemeral state is cleared.
        #expect(scheduler.status["b.bin.gz"] == nil)
    }
}
