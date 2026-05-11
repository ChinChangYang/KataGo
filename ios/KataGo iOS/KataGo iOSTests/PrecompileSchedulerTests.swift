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

        let knownFileNames: Set<String> = ["a.bin.gz"]
        await scheduler.subscribeToCacheEvents(
            cache,
            fileNames: knownFileNames,
            digestFor: { _ in "absent-digest" })

        // Trigger a tick. cachedReady should drop "a.bin.gz" because
        // the digest is not in the cache.
        await cache.clearAll()

        // Allow one runloop turn for the subscription to react.
        try await Task.sleep(for: .milliseconds(50))

        #expect(await scheduler.status["a.bin.gz"] == nil)
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
}
