//
//  CustomBookImporter.swift
//  KataGoUICore
//
//  Bringing a user-chosen opening book into the app, and taking one back out.
//
//  Mirrors `CustomModelImporter`: a free-space check before a byte moves,
//  byte-accurate progress, a cancel that leaves nothing behind, and full
//  validation of the COPY — the KBOK structural parse, not just the magic —
//  so a corrupt or truncated book is rejected at the door instead of showing
//  up later as a silently blank overlay.
//
//  Deletion sweeps the file, the decompressed cache entry, every per-size
//  active-book selection pointing at the book, and the metadata record.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "KataGo Anytime",
                            category: "books.custom")

public enum CustomBookImportError: LocalizedError, Equatable {
    case unreadableSource
    case notEnoughSpace(needed: Int64, available: Int64)
    case copyFailed(String)
    case notABook
    case unsupportedBookVersion(UInt32)
    case unsupportedBoardSize(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadableSource:
            return "That file could not be opened. If it lives in another app or on a removable drive, copy it to this device first."
        case .notEnoughSpace(let needed, let available):
            return "Not enough space: this book needs \(needed.humanFileSizeForBookImport), but only \(available.humanFileSizeForBookImport) is free."
        case .copyFailed(let reason):
            return "The book could not be copied: \(reason)"
        case .notABook:
            return "That file is not a KataGo opening book (.kbook or .kbook.gz)."
        case .unsupportedBookVersion(let version):
            return "This book uses format version \(version), made for a newer format this version of the app does not read."
        case .unsupportedBoardSize(let size):
            return "This book is for a \(size)x\(size) board. Only square boards from 2x2 to 15x15 are supported."
        }
    }
}

public enum CustomBookImporter {

    /// Copies `sourceURL` into the app's imported-books directory, validates
    /// that it really is a KBOK v1 book (full structural parse of the copy),
    /// records it, and returns the record.
    ///
    /// Call off the main actor — this streams the whole file. `progress` is
    /// invoked with 0…1 as bytes land, on whatever thread the copy runs on.
    /// Cancelling the surrounding `Task` aborts mid-copy and deletes the
    /// partial file; so does any thrown error. Nothing is recorded unless the
    /// completed copy validates.
    public static func importBook(from sourceURL: URL,
                                  store: CustomBookStore = CustomBookStore(),
                                  progress: (@Sendable (Double) -> Void)? = nil)
        async throws -> CustomBookRecord {

        // Document-picker URLs are security-scoped even for on-device files.
        // `startAccessing…` returning false is normal for URLs the app already
        // owns, so it is not treated as failure.
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let totalBytes = (attributes[.size] as? NSNumber)?.int64Value,
              totalBytes > 0 else {
            throw CustomBookImportError.unreadableSource
        }

        // Sniff before copying: the stored extension comes from the CONTENT
        // (gzip magic vs KBOK magic), never from the source filename. A file
        // that is neither is refused before a byte moves.
        let isGzipped = try sniffIsGzipped(sourceURL)

        guard CustomBookStore.prepareDirectory() else {
            throw CustomBookImportError.copyFailed("the destination folder could not be created")
        }

        try checkFreeSpace(needed: totalBytes)

        let id = UUID()
        let fileName = CustomBookStore.makeFileName(id: id, isGzipped: isGzipped)
        let destinationURL = CustomBookStore.directoryURL.appendingPathComponent(fileName)

        do {
            try copy(from: sourceURL, to: destinationURL, totalBytes: totalBytes, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            if error is CancellationError { throw error }
            throw CustomBookImportError.copyFailed(error.localizedDescription)
        }

        // Validate the COPY, fully: it is the bytes BookLookup will actually
        // parse, and the structural walk catches truncation the magic cannot.
        // Cancellation is honored around the validation too — for a large
        // gzipped book the decompress is the long pole, and a cancel during it
        // must leave nothing behind, not a recorded import.
        let summary: BookLookup.BookHeaderSummary
        do {
            try Task.checkCancellation()
            guard let data = try? Data(contentsOf: destinationURL, options: .mappedIfSafe) else {
                throw CustomBookImportError.unreadableSource
            }
            summary = try BookLookup.validateImportedBook(data).summary
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            if error is CancellationError { throw error }
            throw mapValidationError(error)
        }

        let suggestedName = suggestedDisplayName(for: sourceURL)
        let record = CustomBookRecord(id: id,
                                      displayName: store.uniqueDisplayName(suggestedName),
                                      fileName: fileName,
                                      fileSize: Int(totalBytes),
                                      boardSize: summary.boardSize)
        store.add(record)
        logger.info("Imported book \(record.displayName, privacy: .public) (\(summary.boardSize)x\(summary.boardSize)) as \(fileName, privacy: .public)")
        return record
    }

    /// Removes an imported book completely: file, decompressed cache entry,
    /// every selection pointing at it, and the metadata record. The caller
    /// reconciles any live `BookLookup` afterwards (the resolver's fallback
    /// makes the affected size fall back to the catalog or another import).
    public static func delete(_ record: CustomBookRecord,
                              store: CustomBookStore = CustomBookStore()) {
        try? FileManager.default.removeItem(at: record.fileURL)
        try? FileManager.default.removeItem(at: record.decompressedCacheURL)
        store.clearSelections(pointingTo: record.identity)
        store.removeRecord(id: record.id)
        logger.info("Deleted imported book \(record.displayName, privacy: .public)")
    }

    // MARK: - Internals

    /// First-bytes sniff: gzip (`1f 8b`) → true, KBOK magic → false, anything
    /// else → `.notABook`. Reads at most 4 bytes.
    private static func sniffIsGzipped(_ sourceURL: URL) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: sourceURL) else {
            throw CustomBookImportError.unreadableSource
        }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 4), prefix.count >= 4 else {
            throw CustomBookImportError.unreadableSource
        }
        if prefix[prefix.startIndex] == 0x1f, prefix[prefix.startIndex + 1] == 0x8b { return true }
        // "KBOK" little-endian: 4B 4F 42 4B
        if prefix.elementsEqual([0x4B, 0x4F, 0x42, 0x4B]) { return false }
        throw CustomBookImportError.notABook
    }

    private static func mapValidationError(_ error: Error) -> Error {
        switch error {
        case let importError as CustomBookImportError:
            return importError
        case BookLookup.BookValidationError.unsupportedVersion(let version):
            return CustomBookImportError.unsupportedBookVersion(version)
        case BookLookup.BookValidationError.unsupportedBoardSize(let size):
            return CustomBookImportError.unsupportedBoardSize(Int(size))
        default:
            return CustomBookImportError.notABook
        }
    }

    /// Free-space gate, matching `CustomModelImporter`'s: "important usage"
    /// capacity with a 5% head-room margin. tvOS has no such key (and no
    /// import UI), so there the check is simply absent.
    private static func checkFreeSpace(needed: Int64) throws {
        #if !os(tvOS)
        let values = try? CustomBookStore.directoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        // No answer from the volume means no basis to refuse; let the copy try.
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        let required = needed + needed / 20
        if available < required {
            throw CustomBookImportError.notEnoughSpace(needed: required, available: available)
        }
        #endif
    }

    /// Chunked stream copy so progress is real and cancellation is prompt.
    private static func copy(from sourceURL: URL,
                             to destinationURL: URL,
                             totalBytes: Int64,
                             progress: (@Sendable (Double) -> Void)?) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CustomBookImportError.copyFailed("the destination file could not be created")
        }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        var copied: Int64 = 0
        progress?(0)
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try input.read(upToCount: 1 << 20) } ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            progress?(min(1, Double(copied) / Double(totalBytes)))
        }
        try output.synchronize()
    }

    /// The name the manage UI starts with: the source file's own name minus
    /// its book extension.
    private static func suggestedDisplayName(for sourceURL: URL) -> String {
        var name = sourceURL.lastPathComponent
        for suffix in [".kbook.gz", ".kbook"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Custom Opening Book" : trimmed
    }
}

private extension Int64 {
    /// Byte count for import diagnostics. Local to this file so it cannot
    /// collide with other formatting helpers.
    var humanFileSizeForBookImport: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
