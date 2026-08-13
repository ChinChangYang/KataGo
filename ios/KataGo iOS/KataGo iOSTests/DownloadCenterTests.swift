//
//  DownloadCenterTests.swift
//  KataGo AnytimeTests
//
//  The download state machine — queue, active slot, state transitions — driven
//  synchronously, with no network and no app data.
//
//  Every defect this feature has ever had lived here rather than in the
//  transport, and each one is expressible as a sequence of ordinary calls: a
//  chunk lands, a task dies, a user pauses, a relaunch snapshot arrives late.
//  The one dependency that needed a seam is `DownloadCenter.launchTask`, which
//  stands in for `session.downloadTask(with:)` and hands back the identifier
//  the callbacks carry. (A background `URLSession` ignores `URLProtocol` stubs,
//  so there is no stubbing the transport itself.)
//
//  House rules these tests keep:
//    • Never `DownloadCenter.shared`. It is a singleton with process-lifetime
//      state; tests that mutated it would contaminate each other.
//    • Every test runs against its own throwaway staging directory and
//      restores the previous override rather than nil'ing it, so it cannot
//      strand a suspended test in another suite.
//    • Every test body is SYNCHRONOUS and `@MainActor`. That is what makes the
//      process-global directory overrides safe: main-actor code with no
//      suspension point cannot interleave with anybody else's.
//    • Source URLs are `example.invalid` (RFC 2606), so even a stray retry
//      firing after a test cannot resolve a host.
//

import Foundation
import Testing
@testable import KataGoUICore

/// Records every ranged request the center would have put on the wire and
/// hands back the `taskIdentifier` its callbacks will carry.
///
/// File-scope and deliberately un-isolated: it is called from the closure
/// stored in `DownloadCenter.launchTask`, and nothing here needs to care what
/// isolation that closure is inferred to have.
private final class LaunchLog {
    /// One entry per launched task, in order.
    private(set) var keys: [String] = []
    /// The `Range` header of each launched request, in the same order.
    private(set) var ranges: [String] = []

    private var identifiers: [String: Int] = [:]
    private var next = 1

    func launch(_ request: URLRequest, _ key: String) -> Int {
        keys.append(key)
        ranges.append(request.value(forHTTPHeaderField: "Range") ?? "")
        let identifier = next
        next += 1
        identifiers[key] = identifier
        return identifier
    }

    /// The identifier of the most recent task launched for `key`.
    func identifier(for key: String) -> Int { identifiers[key] ?? 0 }
}

@MainActor
@Suite(.serialized)
struct DownloadCenterTests {

    /// A fresh center with the network seam replaced by a log and staging
    /// pointed at a throwaway directory. `body` gets the center, the temporary
    /// root (a fine home for destinations and scratch files) and the log.
    private func withCenter(_ body: (DownloadCenter, URL, LaunchLog) throws -> Void) rethrows {
        let root = URL.temporaryDirectory
            .appendingPathComponent("download-center-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousStaging = DownloadStaging._directoryOverride
        DownloadStaging._directoryOverride = root.appendingPathComponent("Staging", isDirectory: true)
        defer {
            DownloadStaging._directoryOverride = previousStaging
            try? FileManager.default.removeItem(at: root)
        }

        // `downloadsDisabled: false` explicitly: the kill switch reads the
        // host process's launch arguments, and a test must not inherit them.
        let center = DownloadCenter(downloadsDisabled: false)
        let log = LaunchLog()
        center.launchTask = { request, key in log.launch(request, key) }
        try body(center, root, log)
    }

    private func source(_ name: String) -> URL {
        URL(string: "https://example.invalid/\(name)")!
    }

    // MARK: - A background relaunch has no `Download` in memory

    /// No scene mounts on a background relaunch, so nothing ever vends a
    /// `Download` — and `absorbed` used to bail on exactly that, leaving a
    /// COMPLETE transfer sitting in staging until the next foreground launch.
    @Test func aCompletedChunkInstallsWithNoDownloadOnRecord() throws {
        try withCenter { center, root, _ in
            // Put the destination in the books directory so `finish`'s cache
            // prewarm (which only hashes networks) skips it and the test stays
            // off `UserDefaults`. Restores the previous value rather than
            // nil'ing it, so it cannot strand another suite's override.
            let previousBooks = OpeningBook._booksDirectoryOverride
            let books = root.appendingPathComponent("OpeningBooks", isDirectory: true)
            OpeningBook._booksDirectoryOverride = books
            defer { OpeningBook._booksDirectoryOverride = previousBooks }

            let destination = books.appendingPathComponent("book-under-test.kbook.gz")
            let key = DownloadStaging.key(for: destination)

            // Exactly what the relaunched process finds: a complete partial and
            // its sidecar on disk, and nothing whatsoever in memory.
            let temp = root.appendingPathComponent("body")
            try Data(repeating: 0x5A, count: 64).write(to: temp)
            #expect(DownloadStaging.replacePartial(withTemp: temp, forKey: key) == 64)
            DownloadStaging.writeMetadata(
                PartialMetadata(destinationPath: destination.path,
                                sourceURLString: "https://example.invalid/book.kbook.gz",
                                etag: nil,
                                declaredTotal: 64,
                                pausedByUser: false),
                forKey: key)

            center.absorbed(key: key,
                            taskIdentifier: 11,
                            assembled: 64,
                            total: 64,
                            wasRestart: false,
                            etag: nil)

            #expect(FileManager.default.fileExists(atPath: destination.path))
            #expect(try Data(contentsOf: destination) == Data(repeating: 0x5A, count: 64))
            #expect(center.lastFinishedDestination?.standardizedFileURL
                    == destination.standardizedFileURL)
            #expect(center.finishedGeneration == 1)
            // Installed means installed: the partial is gone, sidecar and all.
            #expect(DownloadStaging.partialSize(forKey: key) == 0)
            #expect(DownloadStaging.readMetadata(forKey: key) == nil)
        }
    }

    // MARK: - A queued download survives its own late callbacks

    /// Pause a transfer another download is queued behind, resume it before the
    /// cancellation callback lands, and that callback used to overwrite the
    /// resumed download's `.waiting` — after which the retry no-oped on
    /// `enqueue`'s `!queue.contains` guard and `advanceQueue` dropped the key
    /// with its budget already spent.
    @Test func aFailureForAQueuedDownloadLeavesItWaitingAndItStillStarts() {
        withCenter { center, root, log in
            let a = center.download(for: root.appendingPathComponent("a.bin.gz"))
            let b = center.download(for: root.appendingPathComponent("b.bin.gz"))
            center.start(a, from: source("a.bin.gz"))
            center.start(b, from: source("b.bin.gz"))
            #expect(a.state == .transferring)
            #expect(b.state == .waiting)

            let firstTask = log.identifier(for: a.key)
            center.pause(a)
            #expect(b.state == .transferring)

            // Resume A before its cancellation callback has landed: A goes to
            // the back of the queue, behind B.
            center.start(a, from: source("a.bin.gz"))
            #expect(a.state == .waiting)

            // ... and now it lands.
            center.failed(key: a.key, taskIdentifier: firstTask)
            #expect(a.state == .waiting)

            // The whole point: A is still queued, and freeing the slot starts
            // it, with no retry budget spent getting there.
            center.pause(b)
            #expect(a.state == .transferring)
            #expect(a.attempt == 0)
            #expect(log.keys == [a.key, b.key, a.key])
        }
    }

    // MARK: - Restore must not cancel a healthy transfer

    /// `restoreOnLaunch` asks `getAllTasks` and finishes asynchronously, so a
    /// `start` can land in between: our own live task is then in the snapshot
    /// AND already holds the active slot. Cancelling it there killed a transfer
    /// that was perfectly fine.
    @Test func restoreDoesNotCancelTheTransferItAlreadyOwns() {
        withCenter { center, root, log in
            let a = center.download(for: root.appendingPathComponent("a.bin.gz"))
            center.start(a, from: source("a.bin.gz"))
            #expect(a.state == .transferring)

            center.finishRestore(liveKeys: [a.key])

            #expect(a.state == .transferring)
            // Nothing was requeued, so nothing was restarted either.
            #expect(log.keys == [a.key])
        }
    }

    // MARK: - The active slot is never stolen

    /// A chunk absorbed for a download that no longer holds the slot used to
    /// claim it anyway. After that, Stop on the download that DID hold it found
    /// `activeKey != download.key`, cancelled nothing and recorded nothing: the
    /// UI said Paused while the bytes kept coming.
    @Test func aLateChunkCannotStealTheActiveSlot() {
        withCenter { center, root, log in
            let a = center.download(for: root.appendingPathComponent("a.bin.gz"))
            let b = center.download(for: root.appendingPathComponent("b.bin.gz"))
            center.start(a, from: source("a.bin.gz"))
            let aTask = log.identifier(for: a.key)

            // A's transport drops, so the slot is free and B takes it.
            center.failed(key: a.key, taskIdentifier: aTask)
            center.start(b, from: source("b.bin.gz"))
            #expect(b.state == .transferring)

            // A's chunk lands late, with most of the asset still to fetch.
            center.absorbed(key: a.key,
                            taskIdentifier: aTask,
                            assembled: 32,
                            total: 1024,
                            wasRestart: false,
                            etag: nil)

            #expect(a.state == .waiting)
            #expect(b.state == .transferring)
            #expect(log.keys == [a.key, b.key])

            // A was queued, not lost: B's Stop still works and hands the slot on.
            center.pause(b)
            #expect(b.state == .paused)
            #expect(a.state == .transferring)

            // Leave no sleeping back-off behind.
            a.retryTask?.cancel()
        }
    }

    // MARK: - Callbacks belong to a task, not to a download

    /// Pause then resume the same download and two tasks exist for one key: the
    /// cancelled one and the live one. The dead task's `failed` used to clear
    /// the LIVE task's bookkeeping and arm a retry, which would then start a
    /// third task while the second was still appending to the same partial.
    @Test func aStaleFailureCannotClearAFreshTasksBookkeeping() {
        withCenter { center, root, log in
            let a = center.download(for: root.appendingPathComponent("a.bin.gz"))
            center.start(a, from: source("a.bin.gz"))
            let firstTask = log.identifier(for: a.key)

            center.pause(a)
            center.start(a, from: source("a.bin.gz"))
            let secondTask = log.identifier(for: a.key)
            #expect(secondTask != firstTask)
            #expect(a.state == .transferring)

            // Nothing was ever absorbed, so the resumed task asks for the same
            // first chunk as the original one.
            let firstChunk = "bytes=0-\(DownloadCenter.chunkSize - 1)"
            #expect(log.ranges == [firstChunk, firstChunk])

            // The FIRST task's cancellation, arriving after the second started.
            center.failed(key: a.key, taskIdentifier: firstTask)
            #expect(a.state == .transferring)
            // No third task: the stale callback armed no retry.
            #expect(log.keys.count == 2)

            // Positive control — the guard ignores stale callbacks, not all of
            // them. The live task's own failure still lands.
            center.failed(key: a.key, taskIdentifier: secondTask)
            #expect(a.state == .interrupted)

            // Leave no sleeping back-off behind.
            a.retryTask?.cancel()
        }
    }
}
