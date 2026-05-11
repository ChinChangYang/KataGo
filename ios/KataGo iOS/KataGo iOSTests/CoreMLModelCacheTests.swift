import Foundation
import Testing
@testable import KataGoInterface

struct CoreMLModelCacheTests {
    private func tempCacheRoot() -> URL {
        URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func ensureCacheTreeCreatesRootAndModels() async throws {
        let root = tempCacheRoot()
        let cache = CoreMLModelCache(cacheRoot: root)
        await cache.ensureCacheTreeExistsForTests()

        let fm = FileManager.default
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue)
        let modelsDir = root.appendingPathComponent("models")
        #expect(fm.fileExists(atPath: modelsDir.path, isDirectory: &isDir) && isDir.boolValue)

        // isExcludedFromBackup is set on the cache root.
        let resourceValues = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(resourceValues.isExcludedFromBackup == true)
    }

    @Test func emptyIndexJsonIsWrittenOnFirstCall() async throws {
        let root = tempCacheRoot()
        let cache = CoreMLModelCache(cacheRoot: root)
        await cache.ensureCacheTreeExistsForTests()
        await cache.writeIndexAtomicallyForTests()

        let indexURL = root.appendingPathComponent("index.json")
        let data = try Data(contentsOf: indexURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((json?["schemaVersion"] as? Int) == 1)
        #expect((json?["entries"] as? [Any])?.count == 0)
    }

    @Test func releaseIsIdempotent() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        let token = await cache.acquireForTests(
            digest: "d", epoch: UUID(),
            url: URL(fileURLWithPath: "/tmp/x"))
        let key = DigestEpoch(digest: token.digest, epoch: token.epoch)

        await token.release()
        #expect(await cache.peekPinCount(key: key) == 0)
        await token.release()                       // idempotent
        #expect(await cache.peekPinCount(key: key) == 0)
    }

    @Test func independentTokensSamePathHavePinIndependence() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        let epoch = UUID()
        let url = URL(fileURLWithPath: "/tmp/x")
        let a = await cache.acquireForTests(digest: "d", epoch: epoch, url: url)
        let b = await cache.acquireForTests(digest: "d", epoch: epoch, url: url)
        let key = DigestEpoch(digest: "d", epoch: epoch)

        #expect(await cache.peekPinCount(key: key) == 2)
        await a.release()
        #expect(await cache.peekPinCount(key: key) == 1)
        await b.release()
        #expect(await cache.peekPinCount(key: key) == 0)
    }

    @Test func lookupOnDiskReturnsNilWhenIndexEmpty() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        #expect(await cache.lookupOnDiskForTests(digest: "d") == nil)
    }

    @Test func lookupOnDiskReturnsUrlAndEpochWhenIndexed() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        let epoch = UUID()
        await cache.injectEntryForTests(IndexEntry(
            digest: "d", epoch: epoch,
            sizeBytes: 0, lastAccessedAt: 0, createdAt: 0))

        let hit = try #require(await cache.lookupOnDiskForTests(digest: "d"))
        #expect(hit.epoch == epoch)
        // Per epochURL contract: the UUID segment is lowercased so it
        // matches the Task 15 adoption regex `^[0-9a-f-]{36}\.mlmodelc$`.
        #expect(hit.url.lastPathComponent == "\(epoch.uuidString.lowercased()).mlmodelc")
    }

    @Test func lookupOnDiskIgnoresTombstonedEpoch() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        let epoch = UUID()
        await cache.injectEntryForTests(IndexEntry(
            digest: "d", epoch: epoch,
            sizeBytes: 0, lastAccessedAt: 0, createdAt: 0))
        await cache.injectTombstoneForTests(DigestEpoch(digest: "d", epoch: epoch))

        #expect(await cache.lookupOnDiskForTests(digest: "d") == nil)
    }

    @Test func prepareTmpAndCommitStoreYieldEpochInIndex() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()

        // Stage a fake compiled directory with a coremldata.bin so the
        // commit lands a real on-disk artifact.
        let stagingURL = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: stagingURL.appendingPathComponent("coremldata.bin"))
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let prep = try await cache.prepareTmp(digest: "d", compiledURL: stagingURL)
        let stored = try await cache.commitStore(digest: "d",
                                                 epoch: prep.epoch,
                                                 tmpURL: prep.tmpURL)
        #expect(stored.epoch == prep.epoch)
        let hit = try #require(await cache.lookupOnDiskForTests(digest: "d"))
        #expect(hit.epoch == prep.epoch)
        #expect(FileManager.default.fileExists(atPath: hit.url.appendingPathComponent("coremldata.bin").path))
    }

    @Test func invalidatePinnedDeferDelete() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()
        let staging = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data().write(to: staging.appendingPathComponent("coremldata.bin"))
        let prep = try await cache.prepareTmp(digest: "d", compiledURL: staging)
        let stored = try await cache.commitStore(digest: "d", epoch: prep.epoch, tmpURL: prep.tmpURL)

        let pin = await cache.acquireForTests(digest: "d", epoch: stored.epoch, url: stored.url)
        await cache.invalidate(digest: "d", epoch: stored.epoch)

        // Index entry gone; on-disk dir still present (because of the pin).
        #expect(await cache.lookupOnDiskForTests(digest: "d") == nil)
        #expect(FileManager.default.fileExists(atPath: stored.url.path))

        await pin.release()
        // Reap fired on release.
        #expect(!FileManager.default.fileExists(atPath: stored.url.path))
    }

    @Test func invalidateNoOpWhenIndexMovedOn() async throws {
        // Round-13 guard: invalidate(digest:epoch:) must NOT remove the index
        // entry if the index has already moved on to a different epoch
        // (because some concurrent invalidate-and-recompile cycle won the race).
        // The orphaned (digest, oldEpoch) directory still gets cleaned up on
        // the filesystem side, but the live entry survives.
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()

        // Stage commit #1, then commit #2 for the same digest. commitStore's
        // dedup re-check would normally short-circuit #2, so we simulate the
        // post-invalidate-then-recompile path by manually injecting a fresh
        // entry over the original.
        let staging1 = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
        try FileManager.default.createDirectory(at: staging1, withIntermediateDirectories: true)
        try Data().write(to: staging1.appendingPathComponent("coremldata.bin"))
        let prep1 = try await cache.prepareTmp(digest: "d", compiledURL: staging1)
        _ = try await cache.commitStore(digest: "d", epoch: prep1.epoch, tmpURL: prep1.tmpURL)
        let oldEpoch = prep1.epoch

        // Move the index forward to a fresh epoch (test seam — production
        // would do this via invalidate + recompile).
        let newEpoch = UUID()
        await cache.injectEntryForTests(IndexEntry(
            digest: "d", epoch: newEpoch,
            sizeBytes: 0, lastAccessedAt: 0, createdAt: 0))

        // Now invalidate the OLD epoch. The index already points at newEpoch.
        await cache.invalidate(digest: "d", epoch: oldEpoch)

        // Index still has the new entry (round-13 guard); old epoch's dir
        // tombstoned-or-deleted from disk.
        let hit = try #require(await cache.lookupOnDiskForTests(digest: "d"))
        #expect(hit.epoch == newEpoch)
    }

    @Test func urlForKeyMissThenHit() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()

        let pinned1 = try await cache.urlForKey(digest: "abc", missCallback: {
            let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            try Data("c".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
            return u
        })
        let firstEpoch = pinned1.epoch
        await pinned1.release()

        let pinned2 = try await cache.urlForKey(digest: "abc", missCallback: {
            Issue.record("missCallback should not run on hit")
            throw CancellationError()
        })
        #expect(pinned2.epoch == firstEpoch)
        await pinned2.release()
    }

    @Test func threeCallerRaceAfterFailureSpawnsAtMostTwoCompiles() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()

        actor Counter { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()

        let goodCb: @Sendable () async throws -> URL = {
            await counter.inc()
            let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            try Data("c".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
            return u
        }
        let failingCb: @Sendable () async throws -> URL = {
            await counter.inc()
            throw NSError(domain: "test", code: 1)
        }

        // Originator (will fail) starts first.
        async let a = cache.urlForKey(digest: "abc", missCallback: failingCb)
        try await Task.sleep(for: .milliseconds(20))
        async let b = cache.urlForKey(digest: "abc", missCallback: goodCb)
        async let c = cache.urlForKey(digest: "abc", missCallback: goodCb)

        _ = try? await a
        let pb = try await b
        let pc = try await c

        // missCallback was invoked once for the failed task and once for the
        // replacement — never three times.
        let total = await counter.get()
        #expect(total == 2)
        #expect(pb.epoch == pc.epoch)
        await pb.release()
        await pc.release()
    }

    @Test func evictionRemovesOldestWhenOverCap() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot(), evictionCap: 2)
        await cache.ensureCacheTreeExistsForTests()
        for i in 0..<3 {
            await cache.injectEntryForTests(IndexEntry(
                digest: "d\(i)", epoch: UUID(),
                sizeBytes: 0, lastAccessedAt: Double(i),
                createdAt: 0))
        }
        await cache.runEvictionIfOverBudgetForTests()
        // Oldest (lastAccessedAt = 0) was evicted.
        #expect(await cache.lookupOnDiskForTests(digest: "d0") == nil)
        #expect(await cache.lookupOnDiskForTests(digest: "d1") != nil)
        #expect(await cache.lookupOnDiskForTests(digest: "d2") != nil)
    }

    @Test func evictionSkipsPinnedCurrentEpoch() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot(), evictionCap: 1)
        await cache.ensureCacheTreeExistsForTests()
        let e0 = UUID(), e1 = UUID()
        await cache.injectEntryForTests(IndexEntry(
            digest: "d0", epoch: e0,
            sizeBytes: 0, lastAccessedAt: 0, createdAt: 0))
        await cache.injectEntryForTests(IndexEntry(
            digest: "d1", epoch: e1,
            sizeBytes: 0, lastAccessedAt: 1, createdAt: 0))
        let pin = await cache.acquireForTests(digest: "d0", epoch: e0,
                                              url: URL(fileURLWithPath: "/tmp"))

        await cache.runEvictionIfOverBudgetForTests()
        // d0 is pinned + over cap; d1 is unpinned. Eviction must keep d0 and drop d1.
        #expect(await cache.lookupOnDiskForTests(digest: "d0") != nil)
        #expect(await cache.lookupOnDiskForTests(digest: "d1") == nil)
        await pin.release()
    }

    @Test func clearAllWipesIndexAndModelsButPreservesTreeInvariant() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()
        let staging = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data().write(to: staging.appendingPathComponent("coremldata.bin"))
        let prep = try await cache.prepareTmp(digest: "d", compiledURL: staging)
        _ = try await cache.commitStore(digest: "d", epoch: prep.epoch, tmpURL: prep.tmpURL)

        await cache.clearAll()

        // index.json's lookups now miss; models/ exists; root has isExcludedFromBackup.
        let modelsDir = await cache.cacheRoot.appendingPathComponent("models")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: modelsDir.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(await cache.lookupOnDiskForTests(digest: "d") == nil)
    }

    @Test func orphanSweepRemovesUnreferencedDirs() async throws {
        let root = tempCacheRoot()
        let cache = CoreMLModelCache(cacheRoot: root)
        await cache.ensureCacheTreeExistsForTests()

        // Plant an orphaned <D>/<E>.mlmodelc/ that has no index entry.
        // Use lowercase digest + lowercase UUID to match the adoption regex.
        let digest = String(repeating: "a", count: 32)
        let epochString = UUID().uuidString.lowercased()
        let orphan = root.appendingPathComponent("models/\(digest)/\(epochString).mlmodelc")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data().write(to: orphan.appendingPathComponent("coremldata.bin"))

        // Write a fresh empty index so the runStartup path takes the
        // "index valid → orphan sweep" branch rather than the "index
        // missing → adoption" branch.
        await cache.writeIndexAtomicallyForTests()
        await cache.runStartupSweepForTests()

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func adoptionAdoptsValidDirsWhenIndexMissing() async throws {
        let root = tempCacheRoot()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("models"),
                               withIntermediateDirectories: true)
        let digest = String(repeating: "a", count: 32)
        let epoch = UUID()
        let entry = root.appendingPathComponent(
            "models/\(digest)/\(epoch.uuidString.lowercased()).mlmodelc")
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data("c".utf8).write(to: entry.appendingPathComponent("coremldata.bin"))

        // No index.json on disk → loadOrInitIndex takes the adoption branch.
        let cache = CoreMLModelCache(cacheRoot: root)
        await cache.runStartupSweepForTests()

        let hit = try #require(await cache.lookupOnDiskForTests(digest: digest))
        #expect(hit.epoch == epoch)
    }

    @Test func hasEntryReturnsFalseForUnknownDigest() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()
        #expect(await cache.hasEntry(digest: "unknown") == false)
    }

    @Test func hasEntryReturnsTrueAfterInstall() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()

        let pinned = try await cache.urlForKey(digest: "abc123", missCallback: {
            let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
            return u
        })
        await pinned.release()

        #expect(await cache.hasEntry(digest: "abc123") == true)
        #expect(await cache.hasEntry(digest: "missing") == false)
    }

    @Test func indexEventsTicksAfterUrlForKeyInstall() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()

        var iter = await cache.indexEvents.makeAsyncIterator()
        async let tick: Void? = iter.next()

        let pinned = try await cache.urlForKey(digest: "evt1", missCallback: {
            let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
            return u
        })
        await pinned.release()

        let observed = await tick
        #expect(observed != nil)
    }

    @Test func indexEventsTicksAfterClearAll() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()

        var iter = await cache.indexEvents.makeAsyncIterator()
        async let tick: Void? = iter.next()

        await cache.clearAll()
        let observed = await tick
        #expect(observed != nil)
    }

    @Test func indexEventsNoTickOnStaleEpochInvalidate() async throws {
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()

        // Subscribe BEFORE the invalidate so the bufferingNewest(1) buffer
        // can hold any tick that would be emitted.
        let stream = await cache.indexEvents

        // Call invalidate with an epoch that doesn't match any entry —
        // the in-memory index is unchanged, so no tick should be emitted.
        await cache.invalidate(digest: "no-such-digest", epoch: UUID())

        // Race-tolerant assertion: race next() against a short sleep.
        // If next() wins, an unwanted tick was emitted (bad). If the sleep
        // wins, no tick landed within the window (good).
        let result: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iter = stream.makeAsyncIterator()
                _ = await iter.next()
                return true   // tick observed (bad)
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(100))
                return false  // no tick within window (good)
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(result == false)
    }

    @Test func projectedDigestReturnsNilForMissingFile() async throws {
        let missingPath = URL.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID()).bin.gz").path
        let result = try await CoreMLModelCache.projectedDigest(
            forSourcePath: missingPath,
            nnXLen: 19, nnYLen: 19,
            requireExactNNLen: false, useFP16: true, maxBatchSize: 1,
            downloadedHasher: { _ in "stub" })
        #expect(result == nil)
    }

    @Test func projectedDigestMatchesCacheKeyDigest() async throws {
        let tmpFile = URL.temporaryDirectory.appendingPathComponent("\(UUID()).bin.gz")
        try Data("dummy".utf8).write(to: tmpFile)

        let key = try await CoreMLModelCache.cacheKey(
            forSourcePath: tmpFile.path,
            nnXLen: 19, nnYLen: 19,
            requireExactNNLen: false, useFP16: true, maxBatchSize: 1,
            downloadedHasher: { _ in "stub-hash" })

        let projected = try await CoreMLModelCache.projectedDigest(
            forSourcePath: tmpFile.path,
            nnXLen: 19, nnYLen: 19,
            requireExactNNLen: false, useFP16: true, maxBatchSize: 1,
            downloadedHasher: { _ in "stub-hash" })

        #expect(projected == key.digest)
    }

    @Test func warmInstallsEntryAndReleasesPin() async throws {
        let tmpFile = URL.temporaryDirectory.appendingPathComponent("\(UUID()).bin.gz")
        try Data("warm-src".utf8).write(to: tmpFile)
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()

        actor Counter { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }
        let compiled = Counter()
        try await cache.warm(
            forSourcePath: tmpFile.path,
            nnXLen: 19, nnYLen: 19,
            requireExactNNLen: false, useFP16: true, maxBatchSize: 1,
            sourceFileName: "warm.bin.gz",
            downloadedHasher: { _ in "stub-hash" },
            missCallback: {
                await compiled.inc()
                let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
                try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
                try Data("c".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
                return u
            })
        #expect(await compiled.get() == 1)

        // Calling warm again must hit the cache (no second compile).
        try await cache.warm(
            forSourcePath: tmpFile.path,
            nnXLen: 19, nnYLen: 19,
            requireExactNNLen: false, useFP16: true, maxBatchSize: 1,
            sourceFileName: "warm.bin.gz",
            downloadedHasher: { _ in "stub-hash" },
            missCallback: {
                Issue.record("missCallback should not run on second warm")
                throw CancellationError()
            })
        #expect(await compiled.get() == 1)

        // Pin must not survive — clearAll relies on no live pins to fully wipe.
        await cache.clearAll()
        let stats = await cache.statsByCategory()
        #expect(stats.main.count == 0)
        #expect(stats.auxiliary.count == 0)
    }

    @Test func warmIsNoOpWhenSourceFileMissing() async throws {
        let missing = URL.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID()).bin.gz").path
        let cache = CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()

        try await cache.warm(
            forSourcePath: missing,
            nnXLen: 19, nnYLen: 19,
            requireExactNNLen: false, useFP16: true, maxBatchSize: 1,
            sourceFileName: nil,
            downloadedHasher: { _ in "stub" },
            missCallback: {
                Issue.record("missCallback should not run when file missing")
                throw CancellationError()
            })
        // No throw; nothing installed.
    }
}
