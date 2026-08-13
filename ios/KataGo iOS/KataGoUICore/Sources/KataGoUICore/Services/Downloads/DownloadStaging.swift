//
//  DownloadStaging.swift
//  KataGo Anytime
//
//  Where a partial lives while it is incomplete, and the one place that moves
//  a finished file to its destination.
//
//  Partials are kept OUT of every destination directory on purpose: eleven
//  `fileExists` predicates across the app decide "this asset is downloaded"
//  and not one of them checks a size, so a half-written file on a destination
//  path would read as downloaded forever. Caches is no good either — the
//  system evicts it under storage pressure, which would silently reintroduce
//  the restart-from-zero bug this feature exists to remove.
//

import Foundation
import CryptoKit

/// The sidecar written beside a partial: everything needed to resume it after
/// the app has been quit, and nothing that could be recomputed.
public struct PartialMetadata: Codable, Equatable, Sendable {
    /// Where the bytes are headed. Also how a relaunch rebuilds the download
    /// without the UI having been on screen.
    public var destinationPath: String
    /// The stable catalog URL, never a resolved redirect — GitHub's expires in
    /// about thirty minutes.
    public var sourceURLString: String
    /// Sent back as `If-Range` so a changed asset restarts instead of
    /// splicing new bytes onto old ones.
    public var etag: String?
    /// The total the server declared. The authority for both progress and
    /// verification; the catalog's `fileSize` is not.
    public var declaredTotal: Int64?
    /// True when the user stopped it. A paused download never resumes itself.
    public var pausedByUser: Bool

    public init(destinationPath: String,
                sourceURLString: String,
                etag: String?,
                declaredTotal: Int64?,
                pausedByUser: Bool) {
        self.destinationPath = destinationPath
        self.sourceURLString = sourceURLString
        self.etag = etag
        self.declaredTotal = declaredTotal
        self.pausedByUser = pausedByUser
    }
}

/// One partial as found on disk by a sweep.
public struct StagedPartial: Equatable, Sendable {
    public let key: String
    public let modified: Date
    public let hasMetadata: Bool
    public let destinationExists: Bool

    public init(key: String, modified: Date, hasMetadata: Bool, destinationExists: Bool) {
        self.key = key
        self.modified = modified
        self.hasMetadata = hasMetadata
        self.destinationExists = destinationExists
    }
}

/// The garbage-collection rule, kept pure so it can be tested without a disk.
public enum StagingSweep {
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Discard a partial when it is orphaned (no sidecar, so it can never be
    /// resumed), superseded (its destination already holds a complete file),
    /// or simply stale. Nothing garbage-collected partials before, because
    /// none existed; this ships with the feature rather than after it.
    public static func keysToDiscard(_ partials: [StagedPartial],
                                     now: Date,
                                     maxAge: TimeInterval = maxAge) -> [String] {
        partials.filter { partial in
            !partial.hasMetadata
                || partial.destinationExists
                || now.timeIntervalSince(partial.modified) > maxAge
        }.map(\.key)
    }
}

public enum DownloadStaging {
    #if DEBUG
    /// Test-only override so unit tests never touch real app data. Never set
    /// in production (mirrors `OpeningBook._booksDirectoryOverride`).
    nonisolated(unsafe) public static var _directoryOverride: URL?
    #endif

    private static let partialExtension = "partial"
    private static let metadataExtension = "partialmeta"

    /// `Application Support/<bundleID>/Downloads/`.
    public static func directory() -> URL {
        #if DEBUG
        if let override = _directoryOverride { return override }
        #endif
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "KataGoAnytime"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    @discardableResult
    public static func ensureDirectory() throws -> URL {
        let dir = directory()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dir
        try? mutable.setResourceValues(values)
        return dir
    }

    /// A download is identified by **where it is going**, not by file name —
    /// that is what makes a second concurrent transfer of the same asset
    /// unrepresentable. The key is a digest so it is a legal file name and
    /// carries no path separators.
    public static func key(for destinationURL: URL) -> String {
        let canonical = destinationURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    public static func partialURL(forKey key: String) -> URL {
        directory().appendingPathComponent(key).appendingPathExtension(partialExtension)
    }

    public static func metadataURL(forKey key: String) -> URL {
        directory().appendingPathComponent(key).appendingPathExtension(metadataExtension)
    }

    public static func readMetadata(forKey key: String) -> PartialMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(forKey: key)) else { return nil }
        return try? JSONDecoder().decode(PartialMetadata.self, from: data)
    }

    public static func writeMetadata(_ metadata: PartialMetadata, forKey key: String) {
        try? ensureDirectory()
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataURL(forKey: key), options: .atomic)
    }

    /// Bytes already on disk for this key. 0 when there is no partial — which
    /// is also the offset the next request should ask for.
    public static func partialSize(forKey key: String) -> Int64 {
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: partialURL(forKey: key).path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Replaces `destination` with `source` without ever leaving neither in
    /// place. `replaceItemAt` swaps atomically; `moveItem` is the fresh-file
    /// case it cannot handle, since it requires something to replace.
    /// - Returns: true when `destination` now holds `source`'s bytes.
    private static func swapIntoPlace(source: URL, destination: URL) -> Bool {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: source)
            } else {
                try fm.moveItem(at: source, to: destination)
            }
            return true
        } catch {
            return false
        }
    }

    /// Replaces the partial wholesale. Used for the first chunk and whenever
    /// the server answered a ranged request with the entire asset. Swaps
    /// atomically, so a failed replace leaves the previous partial (if any)
    /// exactly as it was — the size this returns is always truthful, never a
    /// silently-discarded partial reporting back as 0.
    /// - Returns: the partial's new size in bytes.
    @discardableResult
    public static func replacePartial(withTemp temp: URL, forKey key: String) -> Int64 {
        try? ensureDirectory()
        _ = swapIntoPlace(source: temp, destination: partialURL(forKey: key))
        return partialSize(forKey: key)
    }

    /// Appends one ranged chunk. Streams rather than loading the chunk into
    /// memory, so a 32 MiB chunk of a 240 MB book costs a 1 MiB buffer.
    ///
    /// A read failure and a clean end-of-file both end the loop the same way,
    /// and a write failure is likewise dropped: that is deliberate, not an
    /// oversight. A truncated append is never reported as one — it surfaces
    /// downstream as a size mismatch when the assembled bytes are checked
    /// against the total the server declared, and the next attempt resumes
    /// from the partial's real offset, so the missing bytes are refetched
    /// rather than silently skipped. The size returned below is always read
    /// back from disk, never assumed from the chunk that was sent in.
    /// - Returns: the partial's new size in bytes.
    @discardableResult
    public static func appendChunk(from temp: URL, toKey key: String) -> Int64 {
        try? ensureDirectory()
        let destination = partialURL(forKey: key)
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else {
            return replacePartial(withTemp: temp, forKey: key)
        }
        guard let sink = try? FileHandle(forWritingTo: destination),
              let source = try? FileHandle(forReadingFrom: temp) else {
            return partialSize(forKey: key)
        }
        defer {
            try? sink.close()
            try? source.close()
        }
        _ = try? sink.seekToEnd()
        while let chunk = try? source.read(upToCount: 1 << 20), !chunk.isEmpty {
            try? sink.write(contentsOf: chunk)
        }
        return partialSize(forKey: key)
    }

    /// Moves a verified partial to its destination and clears the sidecar.
    /// The caller has already checked the size; this never verifies, so that
    /// there is exactly one gate and it is impossible to bypass by calling
    /// the wrong function. Swaps atomically, so a failure — e.g. no partial
    /// staged for this key — leaves any existing destination file untouched
    /// rather than deleting a known-good asset before its replacement is
    /// confirmed.
    public static func install(key: String, destination: URL) -> Bool {
        prepareDestinationDirectory(for: destination)
        guard swapIntoPlace(source: partialURL(forKey: key), destination: destination) else {
            return false
        }
        try? FileManager.default.removeItem(at: metadataURL(forKey: key))
        return true
    }

    public static func discardPartial(forKey key: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: partialURL(forKey: key))
        try? fm.removeItem(at: metadataURL(forKey: key))
    }

    /// Creates the destination's directory. The center must do this itself:
    /// both book download paths used to call `OpeningBook.ensureBooksDirectory()`
    /// from the view immediately before downloading, and after a relaunch there
    /// is no view left to do it — the final move would fail silently.
    public static func prepareDestinationDirectory(for destination: URL) {
        let dir = destination.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Books are large and re-downloadable, so their directory stays out of
        // iCloud backup exactly as `OpeningBook.ensureBooksDirectory()` marks
        // it. Documents' root must NOT be excluded, so this is targeted rather
        // than applied to whatever directory happens to be created.
        if dir.standardizedFileURL == OpeningBook.booksDirectory().standardizedFileURL {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = dir
            try? mutable.setResourceValues(values)
        }
    }

    /// Every partial currently on disk, for the startup sweep.
    public static func scan() -> [StagedPartial] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory(),
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }

        return entries.compactMap { url -> StagedPartial? in
            guard url.pathExtension == partialExtension else { return nil }
            let key = url.deletingPathExtension().lastPathComponent
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let metadata = readMetadata(forKey: key)
            let destinationExists = metadata.map {
                fm.fileExists(atPath: $0.destinationPath)
            } ?? false
            return StagedPartial(key: key,
                                 modified: modified,
                                 hasMetadata: metadata != nil,
                                 destinationExists: destinationExists)
        }
    }
}
