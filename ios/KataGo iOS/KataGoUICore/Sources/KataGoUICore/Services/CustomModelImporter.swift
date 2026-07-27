//
//  CustomModelImporter.swift
//  KataGoUICore
//
//  Bringing a user-chosen network file into the app, and taking one back out.
//
//  Import is a copy, not a reference — see CustomModelStore for why — so it has
//  to behave like a copy of something potentially very large: the catalog
//  already offers an 823 MB network, and a user's own file can be larger still.
//  Hence a free-space check before a single byte moves, byte-accurate progress,
//  and a cancel that leaves nothing behind.
//
//  Deletion is the mirror image, and is deliberately thorough: the file, the
//  metadata record, every per-model UserDefaults key, and the compiled Core ML
//  artifact. None of that is reclaimable later, because a re-import of the very
//  same file is given a brand-new uuid filename.
//

import CoreMLCacheKit
import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "KataGo Anytime",
                            category: "models.custom")

public enum CustomModelImportError: LocalizedError, Equatable {
    case unsupportedFileType
    case unreadableSource
    case notEnoughSpace(needed: Int64, available: Int64)
    case copyFailed(String)
    case invalidNetwork(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "A network file must end with .bin.gz, .txt.gz, .bin or .txt."
        case .unreadableSource:
            return "That file could not be opened. If it lives in another app or on a removable drive, copy it to this device first."
        case .notEnoughSpace(let needed, let available):
            return "Not enough space: this network needs \(needed.humanFileSizeForImport), but only \(available.humanFileSizeForImport) is free."
        case .copyFailed(let reason):
            return "The network could not be copied: \(reason)"
        case .invalidNetwork(let reason):
            return reason
        }
    }
}

public enum CustomModelImporter {

    /// Copies `sourceURL` into the app's custom-network directory, checks that
    /// it really is a loadable KataGo network, records it, and returns the
    /// record.
    ///
    /// Call off the main actor — this streams the whole file. `progress` is
    /// invoked with 0…1 as bytes land, on whatever thread the copy runs on, so
    /// a UI caller must hop to the main actor itself.
    ///
    /// Cancelling the surrounding `Task` aborts mid-copy and deletes the
    /// partial file; so does any thrown error. Nothing is recorded unless the
    /// completed copy validates.
    public static func importModel(from sourceURL: URL,
                                   store: CustomModelStore = CustomModelStore(),
                                   progress: (@Sendable (Double) -> Void)? = nil)
        async throws -> CustomModelRecord {

        guard let fileExtension = CustomModelStore.modelFileExtension(of: sourceURL) else {
            throw CustomModelImportError.unsupportedFileType
        }

        // Document-picker URLs are security-scoped even for on-device files.
        // Balanced below; `startAccessing…` returning false is normal for URLs
        // the app already owns, so it is not treated as failure.
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let totalBytes = (attributes[.size] as? NSNumber)?.int64Value,
              totalBytes > 0 else {
            throw CustomModelImportError.unreadableSource
        }

        guard CustomModelStore.prepareDirectory() else {
            throw CustomModelImportError.copyFailed("the destination folder could not be created")
        }

        try checkFreeSpace(needed: totalBytes)

        let id = UUID()
        let fileName = CustomModelStore.makeFileName(id: id, sourceExtension: fileExtension)
        let destinationURL = CustomModelStore.directoryURL.appendingPathComponent(fileName)

        do {
            try copy(from: sourceURL, to: destinationURL, totalBytes: totalBytes, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            if error is CancellationError { throw error }
            throw CustomModelImportError.copyFailed(error.localizedDescription)
        }

        // Validate the COPY, not the source: it is the bytes we will actually
        // hand the engine, and this catches a truncated read as well as a file
        // that was never a network.
        if let reason = KataGoHelper.validateModelFile(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
            throw CustomModelImportError.invalidNetwork(reason)
        }

        let suggestedName = suggestedDisplayName(for: sourceURL, fileExtension: fileExtension)
        let record = CustomModelRecord(id: id,
                                       displayName: store.uniqueDisplayName(suggestedName),
                                       fileName: fileName,
                                       fileSize: Int(totalBytes))
        store.add(record)
        logger.info("Imported custom network \(record.displayName, privacy: .public) as \(fileName, privacy: .public)")
        return record
    }

    /// Removes a custom network completely: file, record, per-model settings,
    /// and compiled Core ML artifacts.
    ///
    /// Safe to call while that network is the running engine's. Unlinking a
    /// file a process has open is harmless on POSIX — the inode survives until
    /// the engine lets go — and the Core ML side tombstones a pinned entry
    /// rather than yanking it.
    public static func delete(_ record: CustomModelRecord,
                              store: CustomModelStore = CustomModelStore(),
                              defaults: UserDefaults = .standard) async {
        let fileURL = CustomModelStore.directoryURL.appendingPathComponent(record.fileName)
        try? FileManager.default.removeItem(at: fileURL)

        for key in BackendSettings.persistedKeys(forFileName: record.fileName) {
            defaults.removeObject(forKey: key)
        }
        for key in BinFileHasher.memoKeys(forFileName: record.fileName) {
            defaults.removeObject(forKey: key)
        }

        store.removeRecord(id: record.id)

        let evicted = await CoreMLModelCache.shared.invalidateAll(sourceFileName: record.fileName)
        logger.info("Deleted custom network \(record.displayName, privacy: .public); evicted \(evicted) Core ML entries")
    }

    // MARK: - Internals

    /// Free-space gate. Uses "important usage" capacity, which is what the
    /// system will actually let an app consume — the raw free-byte count
    /// overstates it. A 5% head-room margin keeps a copy that would exactly
    /// fill the volume from succeeding into an unusable device.
    private static func checkFreeSpace(needed: Int64) throws {
        let values = try? CustomModelStore.directoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        // No answer from the volume means no basis to refuse; let the copy try.
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        let required = needed + needed / 20
        if available < required {
            throw CustomModelImportError.notEnoughSpace(needed: required, available: available)
        }
    }

    /// Chunked stream copy so progress is real and cancellation is prompt.
    /// `FileManager.copyItem` would be one opaque blocking call — no progress,
    /// no way to stop, and no bound on how long a several-hundred-megabyte
    /// copy appears to hang.
    private static func copy(from sourceURL: URL,
                             to destinationURL: URL,
                             totalBytes: Int64,
                             progress: (@Sendable (Double) -> Void)?) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CustomModelImportError.copyFailed("the destination file could not be created")
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
    /// its model extension, which for a KataGo download is the informative
    /// part ("kata1-b18c384nbt-s9996604416-d4316597426").
    private static func suggestedDisplayName(for sourceURL: URL, fileExtension: String) -> String {
        let name = sourceURL.lastPathComponent
        let suffix = ".\(fileExtension)"
        let base = name.lowercased().hasSuffix(suffix)
            ? String(name.dropLast(suffix.count))
            : name
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Custom Network" : trimmed
    }
}

private extension Int64 {
    /// Byte count for import diagnostics. Local to this file so it cannot
    /// collide with the picker's `Int.humanFileSize`.
    var humanFileSizeForImport: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
