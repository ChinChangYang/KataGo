//
//  CustomModelStore.swift
//  KataGoUICore
//
//  Persistence for user-supplied neural networks — the ones imported from the
//  file system rather than downloaded from the built-in catalog.
//
//  Two halves, deliberately kept apart:
//
//    • the FILE lives in `Documents/CustomModels/custom-<uuid>.bin.gz`. It is
//      copied there at import rather than referenced in place, because the
//      engine holds a plain POSIX path for the whole life of a session on a
//      background thread — a security-scoped URL that must stay accessed that
//      long is a standing liability (bookmark staleness, an ejected volume, a
//      provider that dies). The uuid filename also keeps every per-model key
//      derived from `fileName` unique, so `BackendSettings` and
//      `BinFileHasher` work on custom nets with no changes at all.
//
//    • the METADATA lives here, as a Codable array in UserDefaults. NOT
//      SwiftData: that schema is frozen, and a new @Model record type would
//      change the CloudKit schema to sync metadata describing files that are
//      per-device — producing rows on other devices that point at nothing.
//
//  A value type over UserDefaults, matching `BackendSettings`. It is not
//  observable; callers re-read `records` after a mutation.
//

import Foundation

/// One user-imported network's metadata. `fileName` and `id` are fixed at
/// import; `displayName` and `notes` are what the manage UI edits.
public struct CustomModelRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public let fileName: String
    public let fileSize: Int
    public var notes: String
    public let importedAt: Date

    public init(id: UUID = UUID(),
                displayName: String,
                fileName: String,
                fileSize: Int,
                notes: String = "",
                importedAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.fileSize = fileSize
        self.notes = notes
        self.importedAt = importedAt
    }
}

/// `@unchecked` because `UserDefaults` is not marked `Sendable` even though it
/// is documented thread-safe — the same accommodation `BinFileHasher` makes for
/// the same reason. Sendability matters here: the import path reads and writes
/// this store off the main actor.
public struct CustomModelStore: @unchecked Sendable {
    /// Subdirectory of Documents holding the imported files. Keeping them out
    /// of Documents' root separates them from the catalog's downloads, which
    /// are named by the catalog and deleted by a different code path.
    public static let subdirectoryName = "CustomModels"

    private static let recordsKey = "CustomModelStore.records"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Locations

    /// Where imported files live. Not created here — `prepareDirectory()` does
    /// that at import time, so a read-only platform never tries.
    public static var directoryURL: URL {
        URL.documentsDirectory.appending(path: subdirectoryName)
    }

    /// Creates the import directory if needed. Call before copying a file in.
    @discardableResult
    public static func prepareDirectory() -> Bool {
        (try? FileManager.default.createDirectory(at: directoryURL,
                                                  withIntermediateDirectories: true)) != nil
    }

    /// The filename an import gets: unique by construction, so it can never
    /// collide with a catalog download or with another custom net, and so the
    /// `*_<fileName>` settings of a deleted net are never inherited by a
    /// re-import of the same file.
    public static func makeFileName(id: UUID, sourceExtension: String) -> String {
        "custom-\(id.uuidString.lowercased()).\(sourceExtension)"
    }

    /// The recognized model-file suffix of `url`, lowercased, or nil if it has
    /// none. Two-part suffixes win so `net.bin.gz` yields `bin.gz`, not `gz` —
    /// the engine picks its float format from exactly this distinction.
    public static func modelFileExtension(of url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        for suffix in ["bin.gz", "txt.gz", "bin", "txt", "gz"] where name.hasSuffix(".\(suffix)") {
            return suffix
        }
        return nil
    }

    // MARK: - Records

    public var records: [CustomModelRecord] {
        get {
            guard let data = defaults.data(forKey: Self.recordsKey),
                  let decoded = try? JSONDecoder().decode([CustomModelRecord].self, from: data)
            else { return [] }
            return decoded
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.recordsKey)
        }
    }

    public func record(id: UUID) -> CustomModelRecord? {
        records.first { $0.id == id }
    }

    /// Appends `record`. The caller is expected to have taken its
    /// `displayName` from `uniqueDisplayName(_:)`.
    public func add(_ record: CustomModelRecord) {
        records.append(record)
    }

    /// Renames a record, re-uniquing against every OTHER name. Returns the name
    /// actually stored, which may carry a suffix.
    @discardableResult
    public func rename(id: UUID, to newName: String) -> String? {
        var all = records
        guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
        let unique = uniqueDisplayName(newName, excluding: id)
        all[index].displayName = unique
        records = all
        return unique
    }

    public func setNotes(id: UUID, to notes: String) {
        var all = records
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].notes = notes
        records = all
    }

    /// Drops the metadata record only. File deletion and the settings sweep are
    /// `CustomModelDeletion`'s job — this is the persistence half.
    public func removeRecord(id: UUID) {
        records = records.filter { $0.id != id }
    }

    // MARK: - Naming

    /// `desired` made unique across the built-in catalog AND the other custom
    /// records, by appending " (2)", " (3)", … as needed.
    ///
    /// Uniqueness is not cosmetic. The persisted selection — the shared
    /// `ModelRunnerView.selectedModelTitle` key that iOS, macOS and visionOS
    /// all resolve through — stores a model's TITLE, so two models sharing one
    /// title makes the launched net ambiguous. Collisions with built-in titles
    /// count for the same reason.
    public func uniqueDisplayName(_ desired: String, excluding excludedID: UUID? = nil) -> String {
        let trimmed = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Custom Network" : trimmed

        var taken = Set(NeuralNetworkModel.allCases.map(\.title))
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

    // MARK: - Projection

    /// The records as `NeuralNetworkModel`s, so custom nets flow through every
    /// path that already takes one (the picker, `BackendSettings`, the Core ML
    /// cache, the engine launch).
    ///
    /// `nnLen` is 37 — the engine's compiled maximum — because a file cannot
    /// declare the largest board it was trained for. The real cap is the
    /// per-model "Max Board Size" setting, which already defaults to 19, so a
    /// freshly imported net runs at the safe size until the user says otherwise.
    ///
    /// Each model carries its record's `id`, so rebuilding this list produces
    /// values that still compare equal — `NeuralNetworkModel`'s synthesized
    /// `==` includes `id`, and a fresh UUID per rebuild would silently break
    /// every `onChange`/equality check downstream.
    public var models: [NeuralNetworkModel] {
        records.map { record in
            NeuralNetworkModel(
                id: record.id,
                title: record.displayName,
                description: record.notes.isEmpty ? Self.defaultDescription : record.notes,
                url: "",
                fileName: record.fileName,
                fileSize: record.fileSize,
                subdirectory: Self.subdirectoryName,
                isCustom: true
            )
        }
    }

    static let defaultDescription = """
This is a network you imported from your own files. The app does not know how \
it was trained, so it makes no assumptions about it.

Board sizes: set by the Max Board Size setting for this network, which starts \
at 19x19. Raise it only if you know the network handles larger boards — a \
network trained only for 19x19 can fail on bigger ones.
"""
}
