//
//  DownloadStagingTests.swift
//  KataGo AnytimeTests
//
//  Pins staging: keys are stable and destination-specific, the sidecar
//  round-trips, appending grows a partial, installing only ever moves a
//  verified file, and the sweep discards exactly the orphaned, superseded and
//  stale partials — nothing else.
//

import Foundation
import Testing
@testable import KataGoUICore

struct StagingSweepTests {
    private func partial(_ key: String,
                         ageDays: Double = 0,
                         hasMetadata: Bool = true,
                         destinationExists: Bool = false,
                         now: Date) -> StagedPartial {
        StagedPartial(key: key,
                      modified: now.addingTimeInterval(-ageDays * 24 * 60 * 60),
                      hasMetadata: hasMetadata,
                      destinationExists: destinationExists)
    }

    @Test func aFreshTrackedPartialSurvives() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keep = partial("a", ageDays: 2, now: now)
        #expect(StagingSweep.keysToDiscard([keep], now: now).isEmpty)
    }

    @Test func aPartialWithNoSidecarIsOrphaned() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let orphan = partial("a", hasMetadata: false, now: now)
        #expect(StagingSweep.keysToDiscard([orphan], now: now) == ["a"])
    }

    @Test func aPartialWhoseDestinationAlreadyExistsIsSuperseded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let done = partial("a", destinationExists: true, now: now)
        #expect(StagingSweep.keysToDiscard([done], now: now) == ["a"])
    }

    @Test func sevenDaysIsTheCutoff() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let justUnder = partial("young", ageDays: 6.9, now: now)
        let justOver = partial("old", ageDays: 7.1, now: now)
        #expect(StagingSweep.keysToDiscard([justUnder, justOver], now: now) == ["old"])
    }

    @Test func nothingInMeansNothingOut() {
        #expect(StagingSweep.keysToDiscard([], now: Date()).isEmpty)
    }
}

@MainActor
struct DownloadStagingTests {
    /// Every test runs against its own throwaway directory, so none of them
    /// can see, corrupt or depend on real app data.
    private func withTemporaryStaging(_ body: (URL) throws -> Void) rethrows {
        let root = URL.temporaryDirectory
            .appendingPathComponent("staging-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        DownloadStaging._directoryOverride = root
        defer {
            DownloadStaging._directoryOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    @Test func keysAreStableAndDestinationSpecific() {
        let a = URL(fileURLWithPath: "/tmp/models/fd3.bin.gz")
        let b = URL(fileURLWithPath: "/tmp/models/m2.bin.gz")
        #expect(DownloadStaging.key(for: a) == DownloadStaging.key(for: a))
        #expect(DownloadStaging.key(for: a) != DownloadStaging.key(for: b))
        #expect(DownloadStaging.key(for: a).count == 32)
    }

    @Test func keysIgnorePathNoise() {
        let plain = URL(fileURLWithPath: "/tmp/models/fd3.bin.gz")
        let noisy = URL(fileURLWithPath: "/tmp/models/./fd3.bin.gz")
        #expect(DownloadStaging.key(for: plain) == DownloadStaging.key(for: noisy))
    }

    @Test func sidecarRoundTrips() throws {
        try withTemporaryStaging { _ in
            let key = "abc123"
            let written = PartialMetadata(destinationPath: "/tmp/books/9x9.kbook.gz",
                                          sourceURLString: "https://example.invalid/9x9.kbook.gz",
                                          etag: "\"deadbeef\"",
                                          declaredTotal: 240_027_267,
                                          pausedByUser: true)
            DownloadStaging.writeMetadata(written, forKey: key)
            #expect(DownloadStaging.readMetadata(forKey: key) == written)
        }
    }

    @Test func missingSidecarReadsAsNil() throws {
        try withTemporaryStaging { _ in
            #expect(DownloadStaging.readMetadata(forKey: "never-written") == nil)
        }
    }

    @Test func appendingGrowsThePartial() throws {
        try withTemporaryStaging { root in
            let key = "grow"
            let first = root.appendingPathComponent("chunk1")
            let second = root.appendingPathComponent("chunk2")
            try Data(repeating: 0x41, count: 10).write(to: first)
            try Data(repeating: 0x42, count: 5).write(to: second)

            #expect(DownloadStaging.partialSize(forKey: key) == 0)
            #expect(DownloadStaging.replacePartial(withTemp: first, forKey: key) == 10)
            #expect(DownloadStaging.appendChunk(from: second, toKey: key) == 15)

            let bytes = try Data(contentsOf: DownloadStaging.partialURL(forKey: key))
            #expect(bytes == Data(repeating: 0x41, count: 10) + Data(repeating: 0x42, count: 5))
        }
    }

    @Test func installMovesThePartialAndClearsTheSidecar() throws {
        try withTemporaryStaging { root in
            let key = "install"
            let temp = root.appendingPathComponent("body")
            try Data(repeating: 0x2A, count: 32).write(to: temp)
            _ = DownloadStaging.replacePartial(withTemp: temp, forKey: key)
            DownloadStaging.writeMetadata(PartialMetadata(destinationPath: "x",
                                                          sourceURLString: "y",
                                                          etag: nil,
                                                          declaredTotal: 32,
                                                          pausedByUser: false),
                                          forKey: key)

            let destination = root
                .appendingPathComponent("dest", isDirectory: true)
                .appendingPathComponent("asset.bin.gz")
            #expect(DownloadStaging.install(key: key, destination: destination))

            #expect(FileManager.default.fileExists(atPath: destination.path))
            #expect(try Data(contentsOf: destination).count == 32)
            #expect(!FileManager.default.fileExists(atPath: DownloadStaging.partialURL(forKey: key).path))
            #expect(DownloadStaging.readMetadata(forKey: key) == nil)
        }
    }

    @Test func discardRemovesBothFiles() throws {
        try withTemporaryStaging { root in
            let key = "discard"
            let temp = root.appendingPathComponent("body")
            try Data(repeating: 1, count: 4).write(to: temp)
            _ = DownloadStaging.replacePartial(withTemp: temp, forKey: key)
            DownloadStaging.writeMetadata(PartialMetadata(destinationPath: "x",
                                                          sourceURLString: "y",
                                                          etag: nil,
                                                          declaredTotal: nil,
                                                          pausedByUser: false),
                                          forKey: key)

            DownloadStaging.discardPartial(forKey: key)

            #expect(DownloadStaging.partialSize(forKey: key) == 0)
            #expect(DownloadStaging.readMetadata(forKey: key) == nil)
        }
    }

    @Test func scanSeesWhatWasStaged() throws {
        try withTemporaryStaging { root in
            let temp = root.appendingPathComponent("body")
            try Data(repeating: 9, count: 3).write(to: temp)
            _ = DownloadStaging.replacePartial(withTemp: temp, forKey: "scanned")

            let found = DownloadStaging.scan()
            #expect(found.map(\.key) == ["scanned"])
            #expect(found.first?.hasMetadata == false)
        }
    }
}
