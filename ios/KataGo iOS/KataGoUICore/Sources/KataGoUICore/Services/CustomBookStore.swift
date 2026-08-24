//
//  CustomBookStore.swift
//  KataGoUICore
//
//  Persistence for user-imported opening books — `.kbook`/`.kbook.gz` files
//  brought in from the file system rather than downloaded from the catalog.
//
//  Mirrors `CustomModelStore`: the FILE lives in
//  `Documents/CustomBooks/custom-<uuid>.kbook[.gz]` (copied at import; the
//  uuid name can never collide with a catalog download, another import, or a
//  stale decompressed-cache entry), and the METADATA lives here as a Codable
//  array in UserDefaults. NOT SwiftData: that schema is frozen, and books are
//  per-device files — synced metadata would point at nothing elsewhere.
//
//  This store also owns the per-size ACTIVE-BOOK selection: which book a board
//  size uses when more than one claims it. An absent key means automatic
//  resolution (see `BookResolver`).
//

import Foundation

/// One imported opening book's metadata. Everything is fixed at import;
/// `displayName` is uniquified against the catalog and other imports.
public struct CustomBookRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public let fileName: String
    public let fileSize: Int
    public let boardSize: Int
    public let importedAt: Date

    public init(id: UUID = UUID(),
                displayName: String,
                fileName: String,
                fileSize: Int,
                boardSize: Int,
                importedAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.fileSize = fileSize
        self.boardSize = boardSize
        self.importedAt = importedAt
    }

    /// The stable identity the active-book selection persists. Catalog books
    /// use their `fileName`; imports use the import UUID, which survives
    /// renames and can never be inherited by a re-import.
    public var identity: String { id.uuidString.lowercased() }

    /// The imported file on disk.
    public var fileURL: URL {
        CustomBookStore.directoryURL.appendingPathComponent(fileName)
    }

    public var isOnDisk: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Size in bytes of the file on disk, or nil if missing.
    public var onDiskSize: Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int else { return nil }
        return size
    }

    /// Where `BookLookup.loadBinaryBook` caches the decompressed book: Caches,
    /// keyed by the source name minus its last extension. Only a gzipped
    /// import ever writes here — a plain `.kbook` is mapped directly and
    /// bypasses the cache — but removing it unconditionally on delete is
    /// harmless either way.
    public var decompressedCacheURL: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let name = fileURL.deletingPathExtension().lastPathComponent
        return cacheDir.appendingPathComponent(name)
    }
}

/// `@unchecked` for the same reason as `CustomModelStore`: `UserDefaults` is
/// documented thread-safe but not marked `Sendable`, and the import path uses
/// this store off the main actor.
public struct CustomBookStore: @unchecked Sendable {
    /// Subdirectory of Documents holding the imported files.
    public static let subdirectoryName = "CustomBooks"

    private static let recordsKey = "CustomBookStore.records"

    /// The per-size active-book selection key. Value = an identity string
    /// (catalog `fileName` or import UUID). Absent = automatic resolution.
    static func activeBookKey(forBoardSize size: Int) -> String {
        "CustomBookStore.activeBook.\(size)"
    }

    #if DEBUG
    /// Test-only overrides so the resolver path reached through
    /// `BookLookup.loadIfNeeded`/`isAvailable` — which constructs the default
    /// store itself — never touches real Documents or standard defaults.
    /// Process-global: every test that sets either lives in one serialized
    /// suite. Never set in production.
    nonisolated(unsafe) public static var _directoryOverride: URL?
    nonisolated(unsafe) public static var _defaultsOverride: UserDefaults?
    #endif

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        #if DEBUG
        self.defaults = defaults ?? Self._defaultsOverride ?? .standard
        #else
        self.defaults = defaults ?? .standard
        #endif
    }

    // MARK: - Locations

    /// Where imported book files live. Not created here — `prepareDirectory()`
    /// does that at import time.
    public static var directoryURL: URL {
        #if DEBUG
        if let override = _directoryOverride { return override }
        #endif
        return URL.documentsDirectory.appending(path: subdirectoryName)
    }

    /// Creates the import directory if needed and marks it excluded from
    /// backup. Books are excluded (unlike `Documents/CustomModels`) because a
    /// book is a rebuildable artifact of a published pipeline, not unique
    /// user data.
    @discardableResult
    public static func prepareDirectory() -> Bool {
        let fm = FileManager.default
        let dir = directoryURL
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
            return false
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDir = dir
        try? mutableDir.setResourceValues(values)
        return true
    }

    /// The filename an import gets: unique by construction. The extension is
    /// chosen by content sniff at import (gzip magic vs KBOK magic), never
    /// from the source filename.
    public static func makeFileName(id: UUID, isGzipped: Bool) -> String {
        "custom-\(id.uuidString.lowercased()).\(isGzipped ? "kbook.gz" : "kbook")"
    }

    // MARK: - Records

    /// NOTE: `add`/`removeRecord` are non-atomic read-modify-write cycles over
    /// one UserDefaults key. Today that is safe because the import UIs hold a
    /// modal, dismissal-disabled progress sheet for the whole import (so the
    /// off-main `add` can never interleave with a main-thread delete). A
    /// second off-main writer would need a serialization point here.
    public var records: [CustomBookRecord] {
        get {
            guard let data = defaults.data(forKey: Self.recordsKey),
                  let decoded = try? JSONDecoder().decode([CustomBookRecord].self, from: data)
            else { return [] }
            return decoded
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.recordsKey)
        }
    }

    public func record(id: UUID) -> CustomBookRecord? {
        records.first { $0.id == id }
    }

    public func records(forBoardSize size: Int) -> [CustomBookRecord] {
        records.filter { $0.boardSize == size }
    }

    /// Appends `record`. The caller is expected to have taken its
    /// `displayName` from `uniqueDisplayName(_:)`.
    public func add(_ record: CustomBookRecord) {
        records.append(record)
    }

    /// Drops the metadata record only. File deletion and the selection sweep
    /// are `CustomBookImporter.delete`'s job — this is the persistence half.
    public func removeRecord(id: UUID) {
        records = records.filter { $0.id != id }
    }

    // MARK: - Active-book selection

    /// The explicitly chosen identity for `size`, or nil for automatic
    /// resolution. A stored identity may dangle (its book deleted); the
    /// resolver treats that the same as nil.
    public func activeBookIdentity(forBoardSize size: Int) -> String? {
        defaults.string(forKey: Self.activeBookKey(forBoardSize: size))
    }

    /// Stores an explicit choice for `size`; nil removes the key and returns
    /// the size to automatic resolution.
    public func setActiveBookIdentity(_ identity: String?, forBoardSize size: Int) {
        let key = Self.activeBookKey(forBoardSize: size)
        if let identity {
            defaults.set(identity, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Removes every per-size selection pointing at `identity` (used when the
    /// book behind it is deleted, so the sizes fall back automatically).
    public func clearSelections(pointingTo identity: String) {
        for size in 2...15 where activeBookIdentity(forBoardSize: size) == identity {
            setActiveBookIdentity(nil, forBoardSize: size)
        }
    }

    // MARK: - Naming

    /// `desired` made unique across the catalog's book titles AND the other
    /// imported records, by appending " (2)", " (3)", … as needed. Uniqueness
    /// here is cosmetic (identity is the UUID, not the title), but duplicate
    /// names in a picker are indistinguishable to the user.
    public func uniqueDisplayName(_ desired: String, excluding excludedID: UUID? = nil) -> String {
        let trimmed = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Custom Opening Book" : trimmed

        var taken = Set(OpeningBook.allCases.map(\.title))
        for record in records where record.id != excludedID {
            taken.insert(record.displayName)
        }

        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) (\(suffix))") {
            suffix += 1
        }
        return "\(base) (\(suffix))"
    }
}
