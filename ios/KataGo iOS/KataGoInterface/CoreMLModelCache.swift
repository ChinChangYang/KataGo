import Foundation
import OSLog

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "KataGo Anytime",
                         category: "engine.coreml.cache")

private final class StandardErrorStream: TextOutputStream {
    func write(_ string: String) {
        try? FileHandle.standardError.write(contentsOf: Data(string.utf8))
    }
}

private func printError(_ item: Any) {
    var stream = StandardErrorStream()
    print(item, to: &stream)
}

public struct IndexEntry: Codable, Sendable {
    public let digest: String
    public let epoch: UUID
    public let key: String?         // diagnostic-only; readers must tolerate nil
    public var sizeBytes: Int64
    public var lastAccessedAt: TimeInterval
    public var createdAt: TimeInterval
    public var sourceFileName: String?

    public init(digest: String, epoch: UUID, key: String? = nil,
                sizeBytes: Int64, lastAccessedAt: TimeInterval,
                createdAt: TimeInterval, sourceFileName: String? = nil) {
        self.digest = digest; self.epoch = epoch; self.key = key
        self.sizeBytes = sizeBytes; self.lastAccessedAt = lastAccessedAt
        self.createdAt = createdAt; self.sourceFileName = sourceFileName
    }
}

private struct IndexFile: Codable {
    var schemaVersion: Int
    var entries: [IndexEntry]
}

public actor CoreMLModelCache {
    public let cacheRoot: URL
    public let evictionCap: Int
    /// Source-file basenames classified as auxiliary (e.g., the bundled
    /// human SL net). Each engine launch writes one main entry and one
    /// auxiliary entry; partitioning eviction means an aux-side overflow
    /// never evicts a user-visible main entry.
    public let auxiliaryFileNames: Set<String>
    public let auxiliaryEvictionCap: Int

    private var entries: [String: IndexEntry] = [:]    // digest → entry
    private var pinnedSerials: [DigestEpoch: Set<UInt64>] = [:]
    private var nextTokenSerial: UInt64 = 0
    private var tombstones: Set<DigestEpoch> = []
    private var inFlight: [String: Task<(URL, UUID), Error>] = [:]
    private var didStartup: Bool = false
    private var indexEventContinuations: [AsyncStream<Void>.Continuation] = []

    /// Emits a value whenever the on-disk index mutates: install,
    /// `invalidate`, `clearAll`, or eviction. Multiple subscribers each get
    /// their own stream. Buffered with `.bufferingNewest(1)` so a slow
    /// consumer never falls behind further than one tick.
    public var indexEvents: AsyncStream<Void> {
        AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            indexEventContinuations.append(continuation)
            // Note: continuations are retained for the lifetime of the actor.
            // In production CoreMLModelCache.shared lives for the process
            // lifetime, so no detach logic is needed.
        }
    }

    private func emitIndexEvent() {
        for cont in indexEventContinuations { cont.yield() }
    }

    public init(
        cacheRoot: URL,
        evictionCap: Int = 8,
        auxiliaryFileNames: Set<String> = [],
        auxiliaryEvictionCap: Int = 8
    ) {
        self.cacheRoot = cacheRoot
        self.evictionCap = evictionCap
        self.auxiliaryFileNames = auxiliaryFileNames
        self.auxiliaryEvictionCap = auxiliaryEvictionCap
    }

    /// Classify an entry into the main vs auxiliary partition. Entries
    /// with no `sourceFileName` (legacy untagged entries from earlier
    /// builds) count as main so they appear in the user-visible total.
    fileprivate func isAuxiliary(_ entry: IndexEntry) -> Bool {
        guard let name = entry.sourceFileName else { return false }
        return auxiliaryFileNames.contains(name)
    }

    fileprivate static let schemaVersion = 1

    // `nonisolated` so off-actor callers (notably `prepareTmp`) can build paths
    // without going through the serial executor. Safe because `cacheRoot` is a
    // `let` and `appendingPathComponent` is a pure URL operation.
    nonisolated var modelsRoot: URL { cacheRoot.appendingPathComponent("models") }
    private var indexURL: URL  { cacheRoot.appendingPathComponent("index.json") }

    private func ensureCacheTreeExists() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        var rootURL = cacheRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try rootURL.setResourceValues(values)
        try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    }

    private func writeIndexAtomically() throws {
        let file = IndexFile(schemaVersion: Self.schemaVersion,
                             entries: entries.values.sorted { $0.digest < $1.digest })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(file)
        // Data.write(.atomic) writes to a temp file alongside `indexURL`,
        // fsyncs, and then atomic-renames to `indexURL`. This implements
        // the spec's "write to .tmp + fsync + rename" protocol in one call.
        try data.write(to: indexURL, options: .atomic)
    }

    // MARK: Test-only seams

    public func ensureCacheTreeExistsForTests() {
        try? ensureCacheTreeExists()
    }
    public func writeIndexAtomicallyForTests() {
        try? writeIndexAtomically()
    }

    // MARK: Pin management

    /// Mints a new serial, inserts it into the pin set, and returns the token.
    /// Called on the same actor turn that produced `url`. Atomic by virtue
    /// of running inside the actor (rounds 11/12).
    fileprivate func acquireLocked(digest: String, epoch: UUID, url: URL) -> PinnedCacheURL {
        nextTokenSerial &+= 1
        let serial = nextTokenSerial
        let key = DigestEpoch(digest: digest, epoch: epoch)
        pinnedSerials[key, default: []].insert(serial)
        return PinnedCacheURL(url: url, digest: digest, epoch: epoch,
                              serial: serial, cache: self)
    }

    public func release(digest: String, epoch: UUID, serial: UInt64) {
        let key = DigestEpoch(digest: digest, epoch: epoch)
        guard var set = pinnedSerials[key] else { return }
        set.remove(serial)
        if set.isEmpty { pinnedSerials.removeValue(forKey: key) }
        else            { pinnedSerials[key] = set }
        reapTombstoneIfUnpinned(key)
        // Release-triggered eviction kick (round 14): if a previous eviction
        // pass skipped a current epoch because it was pinned, this release
        // may have unblocked it. Either partition being over budget is
        // reason enough to re-run; the eviction function itself partitions.
        if isAnyPartitionOverBudget() {
            Task.detached(priority: .utility) { [weak self] in
                await self?.runEvictionIfOverBudget()
            }
        }
    }

    /// True iff either the main or the auxiliary partition currently
    /// exceeds its budget. Used to decide whether a release-triggered
    /// eviction kick is worth scheduling.
    private func isAnyPartitionOverBudget() -> Bool {
        var mainCount = 0
        var auxCount = 0
        for entry in entries.values {
            if isAuxiliary(entry) { auxCount += 1 } else { mainCount += 1 }
        }
        return mainCount > evictionCap || auxCount > auxiliaryEvictionCap
    }

    /// True iff any pin is held against the *current* epoch of `digest`
    /// (i.e. the epoch currently in `index.json`). Eviction uses this.
    public func isCurrentEpochPinned(_ digest: String) -> Bool {
        guard let entry = entries[digest] else { return false }
        let key = DigestEpoch(digest: digest, epoch: entry.epoch)
        return !(pinnedSerials[key]?.isEmpty ?? true)
    }

    // MARK: Stubs filled in by later tasks.

    /// Reap a tombstoned `(digest, epoch)` directory once its pin set is
    /// empty. Called from `release(digest:epoch:serial:)`.
    fileprivate func reapTombstoneIfUnpinned(_ key: DigestEpoch) {
        guard tombstones.contains(key),
              (pinnedSerials[key]?.isEmpty ?? true) else { return }
        try? FileManager.default.removeItem(at: epochURL(key))
        tombstones.remove(key)
    }

    /// LRU eviction, partitioned into main vs auxiliary pools so an aux
    /// overflow can never evict a user-visible main entry. Each partition
    /// runs the same LRU pass independently. Pinned-everywhere over-budget
    /// is a no-op for this pass; the next `release()` re-runs eviction.
    ///
    /// Per spec error-handling table: if `removeItem` fails for an unpinned
    /// candidate, log and LEAVE the entry — the next eviction pass retries.
    /// Removing the entry from `entries` while leaving the on-disk directory
    /// would orphan it until the next-startup orphan sweep.
    fileprivate func runEvictionIfOverBudget() async {
        var mainSorted: [IndexEntry] = []
        var auxSorted: [IndexEntry] = []
        for entry in entries.values {
            if isAuxiliary(entry) { auxSorted.append(entry) }
            else                  { mainSorted.append(entry) }
        }
        mainSorted.sort { $0.lastAccessedAt < $1.lastAccessedAt }
        auxSorted.sort  { $0.lastAccessedAt < $1.lastAccessedAt }

        evictPartition(sorted: mainSorted, cap: evictionCap)
        evictPartition(sorted: auxSorted, cap: auxiliaryEvictionCap)

        do {
            try writeIndexAtomically()
        } catch {
            log.error("evict.indexWriteFailed error=\(String(describing: error), privacy: .public)")
        }
    }

    /// Evict from one partition until its count is within `cap`. Caller
    /// passes the partition pre-sorted ascending by `lastAccessedAt`.
    private func evictPartition(sorted: [IndexEntry], cap: Int) {
        var remaining = sorted
        var liveCount = sorted.count
        var didRemoveAny = false
        while liveCount > cap, let candidate = remaining.first {
            remaining.removeFirst()
            if isCurrentEpochPinned(candidate.digest) { continue }
            let key = DigestEpoch(digest: candidate.digest, epoch: candidate.epoch)
            let url = epochURL(key)
            let removed: Bool
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                    removed = true
                } catch {
                    log.error("evict.removeFailed digest=\(candidate.digest, privacy: .public) epoch=\(candidate.epoch.uuidString.lowercased(), privacy: .public) error=\(String(describing: error), privacy: .public)")
                    removed = false
                }
            } else {
                removed = true
            }
            if removed {
                entries.removeValue(forKey: candidate.digest)
                liveCount -= 1
                didRemoveAny = true
                let freedMB = Double(candidate.sizeBytes) / (1024 * 1024)
                log.info("evicted digest=\(candidate.digest, privacy: .public) epoch=\(candidate.epoch.uuidString.lowercased(), privacy: .public) reason=lru freed=\(String(format: "%.2f", freedMB), privacy: .public)MB")
            }
        }
        if didRemoveAny { emitIndexEvent() }
    }

    // MARK: Test-only pin seams.

    public func acquireForTests(digest: String, epoch: UUID, url: URL) -> PinnedCacheURL {
        acquireLocked(digest: digest, epoch: epoch, url: url)
    }
    public func peekPinCount(key: DigestEpoch) -> Int {
        pinnedSerials[key]?.count ?? 0
    }
    public func runEvictionIfOverBudgetForTests() async {
        await runEvictionIfOverBudget()
    }
}

extension CoreMLModelCache {
    /// Index-only lookup. Returns `(url, epoch)` iff `index.json` has an
    /// entry for `digest` whose `epoch` is NOT in `tombstones`. Filesystem
    /// state is never consulted (round 13: tombstoned-but-undeleted dirs
    /// must be invisible to lookup).
    func lookupOnDisk(digest: String) -> (url: URL, epoch: UUID)? {
        guard let entry = entries[digest] else { return nil }
        let key = DigestEpoch(digest: digest, epoch: entry.epoch)
        guard !tombstones.contains(key) else { return nil }
        return (epochURL(key), entry.epoch)
    }

    /// Index-only lookup. Returns true iff a non-tombstoned entry exists
    /// for `digest` in memory. No I/O. Used by `PrecompileScheduler`'s
    /// `cachedReady` projection.
    public func hasEntry(digest: String) -> Bool {
        guard let entry = entries[digest] else { return false }
        let key = DigestEpoch(digest: digest, epoch: entry.epoch)
        return !tombstones.contains(key)
    }

    /// Resolve a (digest, epoch) pair to its on-disk `.mlmodelc/` URL.
    /// Used by both lookup and the atomic-write protocol's commit step.
    ///
    /// **On-disk case contract:** the UUID segment is lowercased so it
    /// matches the adoption-pass regex `^[0-9a-f-]{36}\.mlmodelc$` from
    /// spec §Adoption (Task 15). `Foundation.UUID.uuidString` returns
    /// uppercase by default; without the `.lowercased()` here, every
    /// directory `epochURL` produces would be silently deleted as
    /// "orphaned" by the adoption pass.
    func epochURL(_ key: DigestEpoch) -> URL {
        modelsRoot
            .appendingPathComponent(key.digest)
            .appendingPathComponent("\(key.epoch.uuidString.lowercased()).mlmodelc")
    }

    // MARK: Test-only seams.

    public func lookupOnDiskForTests(digest: String) -> (url: URL, epoch: UUID)? {
        lookupOnDisk(digest: digest)
    }
    public func injectEntryForTests(_ entry: IndexEntry) {
        entries[entry.digest] = entry
    }
    public func injectTombstoneForTests(_ key: DigestEpoch) {
        tombstones.insert(key)
    }
}

// MARK: - Store / Invalidate

extension CoreMLModelCache {
    /// Off-actor (`nonisolated`) preparation step — runs the slow move
    /// (cross-volume EXDEV-tolerant copy on macOS) without holding the
    /// actor's serial executor. Mints a fresh `epoch` UUID and stages
    /// the compiled output at `<digest>/<epoch>.tmp`.
    public nonisolated func prepareTmp(
        digest: String, compiledURL: URL
    ) async throws -> (epoch: UUID, tmpURL: URL) {
        try Task.checkCancellation()
        let epoch = UUID()
        let lowerEpoch = epoch.uuidString.lowercased()
        // Reuse the actor's `modelsRoot` so this hand-built path can never
        // drift from the layout `epochURL` produces (round-9 review I-1).
        let digestDir = modelsRoot.appendingPathComponent(digest)
        let tmpURL = digestDir.appendingPathComponent("\(lowerEpoch).tmp")
        try FileManager.default.createDirectory(at: digestDir,
                                                withIntermediateDirectories: true)
        // FileManager.moveItem handles cross-volume by falling back to copy + remove.
        try FileManager.default.moveItem(at: compiledURL, to: tmpURL)
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: tmpURL)
            throw CancellationError()
        }
        return (epoch, tmpURL)
    }

    /// On-actor commit step — cancellation re-check, dedup re-check,
    /// same-volume rename of `<epoch>.tmp` → `<epoch>.mlmodelc`, index update.
    public func commitStore(
        digest: String, epoch: UUID, tmpURL: URL,
        sourceFileName: String? = nil
    ) throws -> (url: URL, epoch: UUID) {
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: tmpURL)
            throw CancellationError()
        }
        if let hit = lookupOnDisk(digest: digest) {
            // Another precompile finished while we compiled — drop our work.
            try? FileManager.default.removeItem(at: tmpURL)
            return hit
        }
        let key = DigestEpoch(digest: digest, epoch: epoch)
        let finalURL = epochURL(key)
        try FileManager.default.moveItem(at: tmpURL, to: finalURL)
        let now = Date().timeIntervalSince1970
        injectEntry(IndexEntry(
            digest: digest, epoch: epoch,
            sizeBytes: directorySize(finalURL),
            lastAccessedAt: now, createdAt: now,
            sourceFileName: sourceFileName))
        try writeIndexAtomically()
        emitIndexEvent()
        return (finalURL, epoch)
    }

    /// Caller passes the SPECIFIC epoch they failed on. If the index has
    /// already moved on to a different epoch — because a concurrent caller
    /// already invalidated and recompiled — this is a no-op so we don't
    /// spuriously evict a freshly-good entry.
    public func invalidate(digest: String, epoch: UUID) {
        let key = DigestEpoch(digest: digest, epoch: epoch)
        if let entry = entries[digest], entry.epoch == epoch {
            entries.removeValue(forKey: digest)
            try? writeIndexAtomically()
            emitIndexEvent()
        }
        // Tombstone-or-delete is keyed on (digest, epoch), not on whether
        // we just touched the index — the caller's failed pin is what matters.
        if pinnedSerials[key]?.isEmpty == false {
            tombstones.insert(key)
        } else {
            try? FileManager.default.removeItem(at: epochURL(key))
        }
    }

    fileprivate func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let v = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(v?.fileSize ?? 0)
        }
        return total
    }

    /// Internal helper used by commitStore. Kept private to the actor body.
    fileprivate func injectEntry(_ entry: IndexEntry) {
        entries[entry.digest] = entry
    }
}

// MARK: - MLModelCompiler

/// Identity passthrough for the cache's compile step.
///
/// **Architectural note (Task 16):** the original spec had this enum wrap
/// `MLModel.compileModel(at:)` directly so the cache would receive a
/// `.mlpackage` from `missCallback` and compile it inline. We instead
/// keep `compile(at:)` as the identity function and have the C++/Swift
/// bridge (Task 19) do BOTH conversion AND compilation inside its
/// `missCallback`, returning a ready `.mlmodelc/` directly.
///
/// Trade-offs:
/// - Pro: the cache stores opaque `.mlmodelc/` directories without
///   knowing about Core ML at all. `KataGoInterface` does not need to
///   `import CoreML`.
/// - Pro: existing unit tests can pass fabricated `.mlmodelc/` fixtures
///   through `urlForKey` without needing real Core ML inputs.
/// - Con: `missCallback` is conceptually two operations (convert +
///   compile). The bridge documents the order explicitly.
///
/// This identity function exists so the call site in `joinOrInstall`
/// remains unchanged and a future redesign that moves compilation back
/// inside the cache only has to swap this body.
enum MLModelCompiler {
    static func compile(at url: URL) async throws -> URL { url }
}

// MARK: - PinnedCacheURL

/// Pin token returned by `urlForKey` (Task 10). Holds the cache pin until
/// `release()` is called or the token is deinitialized.
///
/// Per spec round 12: `serial: UInt64` is the stable per-token identity —
/// `ObjectIdentifier(self)` is the object's address and is unsafe across
/// deallocation (allocator can reuse a freed slot for a new instance with
/// the same OI). The actor mints a fresh serial at acquire time so the
/// deferred `deinit`-spawned release cannot strip a different live pin.
public final class PinnedCacheURL: @unchecked Sendable {
    public let url: URL
    public let digest: String
    public let epoch: UUID
    public let serial: UInt64
    private weak var cache: CoreMLModelCache?

    init(url: URL, digest: String, epoch: UUID, serial: UInt64, cache: CoreMLModelCache) {
        self.url = url; self.digest = digest; self.epoch = epoch
        self.serial = serial; self.cache = cache
    }

    /// Idempotent. Safe to call from any actor.
    public func release() async {
        guard let cache else { return }
        await cache.release(digest: digest, epoch: epoch, serial: serial)
    }

    deinit {
        // Safety net for callers that forget to call release().
        // Capture by value — self is dying.
        guard let cache else { return }
        let d = digest, e = epoch, s = serial
        Task.detached { await cache.release(digest: d, epoch: e, serial: s) }
    }
}

// MARK: - urlForKey + joinOrInstall

extension CoreMLModelCache {
    /// Cache-hit-or-compile entry point. Returns a `PinnedCacheURL` token
    /// that must be `release()`ed by the caller (deinit is a safety net).
    /// `priority` controls the inner compile task's priority — engine
    /// launches default to `.userInitiated`; `PrecompileScheduler` passes
    /// `.utility` (Task 14).
    public func urlForKey(
        digest: String,
        priority: TaskPriority = .userInitiated,
        sourceFileName: String? = nil,
        missCallback: @Sendable @escaping () async throws -> URL
    ) async throws -> PinnedCacheURL {
        if let hit = lookupOnDisk(digest: digest) {
            // Touch lastAccessedAt to mark MRU for LRU eviction (Task 11).
            entries[digest]?.lastAccessedAt = Date().timeIntervalSince1970
            printError("CoreMLCache hit: \(sourceFileName ?? "?") digest=\(digest.prefix(12))")
            return acquireLocked(digest: digest, epoch: hit.epoch, url: hit.url)
        }
        return try await joinOrInstall(digest: digest, priority: priority,
                                       sourceFileName: sourceFileName,
                                       missCallback: missCallback)
    }

    /// Recursive helper. The head-check + assignment in this method
    /// happen on the same actor turn (no `await` between them), which is
    /// what serializes installs across concurrent callers.
    /// CAS-guarded clear: every clear of `inFlight[digest]` is gated on
    /// `inFlight[digest] == task` (Task is a struct with identity-based
    /// equality). Failures recurse through `joinOrInstall` rather than
    /// returning the error.
    private func joinOrInstall(
        digest: String,
        priority: TaskPriority,
        sourceFileName: String? = nil,
        missCallback: @Sendable @escaping () async throws -> URL
    ) async throws -> PinnedCacheURL {
        if let existing = inFlight[digest] {
            do {
                let (url, epoch) = try await existing.value
                return acquireLocked(digest: digest, epoch: epoch, url: url)
            } catch {
                // CAS-clear: only retract the slot if it still holds the
                // task whose failure we observed.
                if inFlight[digest] == existing { inFlight[digest] = nil }
                return try await joinOrInstall(digest: digest, priority: priority,
                                               sourceFileName: sourceFileName,
                                               missCallback: missCallback)
            }
        }

        // Slot is empty — install our own compile task. The detached task
        // returns (url, epoch) so multiple awaiters can pin the same epoch.
        // Post-commit, kick LRU eviction in case this install pushed the
        // cache over budget (round 14: a release-only trigger isn't enough,
        // because pins held for the analysis-session lifetime would never
        // fire `release()` while the cache continues to grow).
        let task = Task.detached(priority: priority) { [weak self] () async throws -> (URL, UUID) in
            guard let self else { throw CancellationError() }
            let mlpackageURL = try await missCallback()
            let compiledURL = try await MLModelCompiler.compile(at: mlpackageURL)
            let prep = try await self.prepareTmp(digest: digest, compiledURL: compiledURL)
            let stored = try await self.commitStore(digest: digest,
                                                    epoch: prep.epoch,
                                                    tmpURL: prep.tmpURL,
                                                    sourceFileName: sourceFileName)
            Task.detached(priority: .utility) { [weak self] in
                await self?.runEvictionIfOverBudget()
            }
            return stored
        }
        inFlight[digest] = task

        let result: Result<(URL, UUID), Error>
        do { result = .success(try await task.value) }
        catch { result = .failure(error) }

        // CAS-clear on either success or failure. The Task is a struct;
        // `==` is identity-based.
        if inFlight[digest] == task { inFlight[digest] = nil }

        let (url, epoch) = try result.get()
        return acquireLocked(digest: digest, epoch: epoch, url: url)
    }
}

// MARK: - Stats (Task 20/21)

extension CoreMLModelCache {
    public struct Stats: Sendable {
        public let count: Int
        public let totalBytes: Int64
    }

    public func statsForUI() -> Stats {
        var total: Int64 = 0
        var count = 0
        for entry in entriesSnapshot { total += entry.sizeBytes; count += 1 }
        return Stats(count: count, totalBytes: total)
    }

    /// Stats with entries whose `sourceFileName` matches any name in
    /// `excludedFileNames` filtered out. Kept for callers that need a
    /// single combined number with an explicit filter set.
    public func statsForUI(excludingFileNames excludedFileNames: Set<String>) -> Stats {
        var total: Int64 = 0
        var count = 0
        for entry in entriesSnapshot {
            if let name = entry.sourceFileName, excludedFileNames.contains(name) {
                continue
            }
            total += entry.sizeBytes
            count += 1
        }
        return Stats(count: count, totalBytes: total)
    }

    /// Per-category stats partitioned by `auxiliaryFileNames`. The footer
    /// shows both lines so the user sees the actual cache state instead
    /// of a single number that hides aux entries.
    public func statsByCategory() -> (main: Stats, auxiliary: Stats) {
        var mainTotal: Int64 = 0, mainCount = 0
        var auxTotal: Int64 = 0,  auxCount = 0
        for entry in entriesSnapshot {
            if isAuxiliary(entry) {
                auxTotal += entry.sizeBytes
                auxCount += 1
            } else {
                mainTotal += entry.sizeBytes
                mainCount += 1
            }
        }
        return (
            Stats(count: mainCount, totalBytes: mainTotal),
            Stats(count: auxCount,  totalBytes: auxTotal)
        )
    }

    private var entriesSnapshot: [IndexEntry] {
        Array(entries.values)
    }
}

// MARK: - clearAll

extension CoreMLModelCache {
    /// Wipe the entire cache. Cancel in-flight compile tasks, delete the
    /// cache root, re-establish the invariant tree, write a fresh empty
    /// index, and reset all in-memory state.
    ///
    /// Caller is responsible for kicking any re-warm (per spec: clearAll
    /// has no opinion on which model is currently selected). Production
    /// callers (the Clear Cache button) follow this with
    /// `PrecompileScheduler.scheduleBuiltIn()`.
    public func clearAll() async {
        for task in inFlight.values { task.cancel() }
        try? FileManager.default.removeItem(at: cacheRoot)
        try? ensureCacheTreeExists()
        entries.removeAll()
        pinnedSerials.removeAll()
        tombstones.removeAll()
        inFlight.removeAll()
        try? writeIndexAtomically()
        emitIndexEvent()
    }
}

// MARK: - Adoption / Orphan sweep

extension CoreMLModelCache {
    /// Decide adoption-vs-orphan-sweep at first actor use.
    /// - Index missing / unreadable / wrong-schema → discard entries,
    ///   delete index, walk `models/`, and adopt complete entries.
    /// - Index valid → load entries from JSON, then orphan-sweep
    ///   directories not referenced by the index.
    fileprivate func loadOrInitIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let file = try? JSONDecoder().decode(IndexFile.self, from: data),
              file.schemaVersion == Self.schemaVersion else {
            adoptDirs()
            return
        }
        for entry in file.entries { entries[entry.digest] = entry }
        orphanSweep()
    }

    private func adoptDirs() {
        try? FileManager.default.removeItem(at: indexURL)
        try? ensureCacheTreeExists()
        let modelsRoot = self.modelsRoot
        let fm = FileManager.default
        let digestRegex = try! NSRegularExpression(pattern: "^[0-9a-f]{32}$")
        let epochRegex = try! NSRegularExpression(pattern: "^[0-9a-f-]{36}\\.mlmodelc$")

        guard let digestDirs = try? fm.contentsOfDirectory(at: modelsRoot,
            includingPropertiesForKeys: nil) else { return }
        for digestDir in digestDirs {
            let dname = digestDir.lastPathComponent
            guard digestRegex.firstMatch(in: dname,
                  range: NSRange(location: 0, length: dname.utf16.count)) != nil
            else {
                try? fm.removeItem(at: digestDir); continue
            }
            guard let leaves = try? fm.contentsOfDirectory(at: digestDir,
                includingPropertiesForKeys: nil) else { continue }
            var adoptedOne = false
            for leaf in leaves {
                let lname = leaf.lastPathComponent
                let isEpochLeaf = epochRegex.firstMatch(in: lname,
                    range: NSRange(location: 0, length: lname.utf16.count)) != nil
                let coremlDataPath = leaf.appendingPathComponent("coremldata.bin").path
                let hasWeights = fm.fileExists(atPath: coremlDataPath)
                let uuidString = String(lname.dropLast(".mlmodelc".count))
                guard isEpochLeaf, hasWeights, !adoptedOne,
                      let epoch = UUID(uuidString: uuidString) else {
                    try? fm.removeItem(at: leaf); continue
                }
                let now = Date().timeIntervalSince1970
                entries[dname] = IndexEntry(
                    digest: dname, epoch: epoch, key: nil,
                    sizeBytes: directorySize(leaf),
                    lastAccessedAt: now, createdAt: now)
                adoptedOne = true
                // Don't `break` — fall through so additional leaves
                // for the same digest are still cleaned up by the
                // first-iteration `try? fm.removeItem` branch above.
            }
        }
        try? writeIndexAtomically()
    }

    private func orphanSweep() {
        let fm = FileManager.default
        guard let digestDirs = try? fm.contentsOfDirectory(at: modelsRoot,
            includingPropertiesForKeys: nil) else { return }
        for digestDir in digestDirs {
            let dname = digestDir.lastPathComponent
            guard let entry = entries[dname] else {
                try? fm.removeItem(at: digestDir); continue
            }
            let expected = "\(entry.epoch.uuidString.lowercased()).mlmodelc"
            guard let leaves = try? fm.contentsOfDirectory(at: digestDir,
                includingPropertiesForKeys: nil) else { continue }
            for leaf in leaves where leaf.lastPathComponent != expected {
                try? fm.removeItem(at: leaf)
            }
        }
    }

    /// Public test seam — invokes the actor's startup sweep on demand.
    /// Production callers (Task 17) invoke `loadOrInitIndex()` once at
    /// `CoreMLModelCache.shared` factory time.
    public func runStartupSweepForTests() {
        try? ensureCacheTreeExists()
        loadOrInitIndex()
    }
}

// MARK: - Cache key helper (Task 17)

/// Declare the C symbol so `KataGoInterface` can call it without importing
/// `KataGoSwift`. The definition lives in `metalbackend.cpp` (wrapped in
/// an `extern "C"` block) and is re-exported through `KataGoSwift.framework`.
/// `KataGoInterface` already links `KataGoSwift`, so the symbol resolves at
/// link time.
@_silgen_name("katagocoreml_converter_version")
private func katagocoreml_converter_version_cstr() -> UnsafePointer<CChar>?

extension CoreMLModelCache {
    /// Build a `CoreMLCacheKey` from the bridge's input parameters.
    /// Used by the Task-19 cache-aware compute-handle path.
    ///
    /// `downloadedHasher` defaults to throwing
    /// `CoreMLCacheKeyError.downloadedHasherNotInjected` — production callers
    /// must inject the real hasher (Task 23 wires `BinFileHasher.shared`).
    public static func cacheKey(
        forSourcePath sourcePath: String,
        nnXLen: Int32, nnYLen: Int32,
        requireExactNNLen: Bool, useFP16: Bool, maxBatchSize: Int,
        downloadedHasher: @Sendable (URL) async throws -> String = { _ in
            throw CoreMLCacheKeyError.downloadedHasherNotInjected
        }
    ) async throws -> CoreMLCacheKey {
        let identity = try await CoreMLCacheKey.sourceIdentity(
            for: sourcePath,
            downloadedHasher: downloadedHasher)
        let converterVersion: String
        if let cstr = katagocoreml_converter_version_cstr() {
            converterVersion = String(cString: cstr)
        } else {
            converterVersion = "unknown"
        }
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return CoreMLCacheKey(
            sourceIdentity: identity,
            boardXLen: nnXLen, boardYLen: nnYLen,
            computePrecision: useFP16 ? "FP16" : "FP32",
            optimizeIdentityMask: requireExactNNLen,
            minBatchSize: 1, maxBatchSize: maxBatchSize,
            converterVersion: converterVersion,
            osMajorVersion: osMajor)
    }

    /// Returns the digest the next engine launch would compute for these
    /// inputs, or nil if the source file is not present on disk. Production
    /// callers use the persisted `BackendSettings` for the model to choose
    /// the primitive arguments so the projection matches what the launch
    /// path computes via `cacheKey(forSourcePath:...)`.
    public static func projectedDigest(
        forSourcePath sourcePath: String,
        nnXLen: Int32, nnYLen: Int32,
        requireExactNNLen: Bool, useFP16: Bool, maxBatchSize: Int,
        downloadedHasher: @Sendable (URL) async throws -> String
    ) async throws -> String? {
        // Built-in models live in the bundle; downloaded models live under
        // Documents/. A missing file is the "model not yet downloaded" case
        // and should yield nil, not throw.
        if !FileManager.default.fileExists(atPath: sourcePath) { return nil }
        let key = try await cacheKey(
            forSourcePath: sourcePath,
            nnXLen: nnXLen, nnYLen: nnYLen,
            requireExactNNLen: requireExactNNLen,
            useFP16: useFP16, maxBatchSize: maxBatchSize,
            downloadedHasher: downloadedHasher)
        return key.digest
    }

    /// Compute the projected digest and warm the cache. On miss, the
    /// provided callback is invoked exactly once and the resulting
    /// `.mlmodelc` is committed via the standard install path. On hit,
    /// nothing runs. Either way the pin is released immediately because
    /// `warm` has no consumer for the URL; the on-disk entry persists.
    ///
    /// Returns early without throwing if the source file is missing
    /// (mirrors `projectedDigest`'s nil case — pre-download is not an
    /// error).
    public func warm(
        forSourcePath sourcePath: String,
        nnXLen: Int32, nnYLen: Int32,
        requireExactNNLen: Bool, useFP16: Bool, maxBatchSize: Int,
        sourceFileName: String?,
        downloadedHasher: @Sendable @escaping (URL) async throws -> String,
        missCallback: @Sendable @escaping () async throws -> URL
    ) async throws {
        guard let digest = try await Self.projectedDigest(
            forSourcePath: sourcePath,
            nnXLen: nnXLen, nnYLen: nnYLen,
            requireExactNNLen: requireExactNNLen,
            useFP16: useFP16, maxBatchSize: maxBatchSize,
            downloadedHasher: downloadedHasher)
        else { return }

        let pinned = try await urlForKey(
            digest: digest,
            priority: .utility,
            sourceFileName: sourceFileName,
            missCallback: missCallback)
        await pinned.release()
    }
}

// MARK: - Shared singleton + startup

extension CoreMLModelCache {
    /// Process-wide cache singleton. Backed by
    /// `Application Support/<bundle>/coreml/`. Use `await cache.start()`
    /// once at app startup to run the adoption-or-orphan-sweep pass.
    nonisolated public static let shared: CoreMLModelCache = {
        let fm = FileManager.default
        let appSupport: URL
        do {
            appSupport = try fm.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
        } catch {
            // Application Support is essentially always writable on iOS.
            // If it isn't (test environments, sandboxed weirdness),
            // fall back to temporary directory so the cache at least
            // has a place to write — degrades gracefully rather than
            // crashing the engine boot.
            appSupport = URL.temporaryDirectory
        }
        let bundle = Bundle.main.bundleIdentifier ?? "KataGo Anytime"
        let root = appSupport.appendingPathComponent(
            "\(bundle)/coreml", isDirectory: true)
        // The bundled human SL net is loaded alongside the user-selected
        // model on every launch. Partition it into its own LRU pool so
        // eviction can't drop a user-visible main entry to keep an aux one.
        return CoreMLModelCache(
            cacheRoot: root,
            evictionCap: 4,
            auxiliaryFileNames: ["b18c384nbt-humanv0.bin.gz"],
            auxiliaryEvictionCap: 4)
    }()

    /// Idempotent startup. Runs the adoption-or-orphan-sweep dispatch
    /// once. Subsequent calls are no-ops. Production callers should
    /// `await CoreMLModelCache.shared.start()` once at app boot before
    /// the first `urlForKey` call; tests use `runStartupSweepForTests()`.
    public func start() async {
        guard !didStartup else { return }
        didStartup = true
        try? ensureCacheTreeExists()
        loadOrInitIndex()
    }
}
