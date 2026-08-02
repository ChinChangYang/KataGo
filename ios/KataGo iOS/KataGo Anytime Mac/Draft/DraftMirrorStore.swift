//
//  DraftMirrorStore.swift
//  KataGo Anytime Mac
//

import Foundation
import OSLog

/// The crash-safe payload.
///
/// It carries the BASELINE as well as the draft, not just the draft: a
/// restored draft rests on an ancestor that may since have gone stale, and
/// without the baseline the conflict check cannot run after a restore.
struct DraftMirror: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var draft: DraftSnapshot
    var baseline: DraftSnapshot

    init(draft: DraftSnapshot, baseline: DraftSnapshot) {
        self.version = Self.currentVersion
        self.draft = draft
        self.baseline = baseline
    }
}

/// Reads and writes the single draft mirror file.
///
/// Single, not a collection: leaving a dirty game always forces Save · Discard
/// · Cancel, so at most one draft is ever open.
///
/// It lives outside SwiftData because the `@Model` schema is CloudKit-frozen —
/// drafts cannot be flagged inside the store — and because the entire point is
/// that a draft never enters the synced store.
final class DraftMirrorStore {
    private static let logger = Logger(subsystem: "KataGo Anytime", category: "DraftMirror")
    private static let fileName = "mac-draft.json"

    let fileURL: URL
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory) {
        self.directory = directory
        self.fileURL = directory.appending(path: Self.fileName)
    }

    /// A failed write is logged and swallowed: losing the crash mirror is bad,
    /// but blocking the user's editing over a full disk is worse.
    func write(_ mirror: DraftMirror) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(mirror)
            // Atomic so a crash mid-write cannot leave a half-file behind.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("draft mirror write failed: \(error.localizedDescription)")
        }
    }

    /// Returns the stored mirror, or nil when there is none, it is unreadable,
    /// or it was written by a newer build. In the latter two cases the file is
    /// moved aside rather than deleted, so a bad decode never silently destroys
    /// the only copy of the user's work.
    func read() -> DraftMirror? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let mirror = try JSONDecoder().decode(DraftMirror.self, from: data)
            guard mirror.version == DraftMirror.currentVersion else {
                Self.logger.error("draft mirror version \(mirror.version) is not readable by this build")
                moveAside()
                return nil
            }
            return mirror
        } catch {
            Self.logger.error("draft mirror unreadable: \(error.localizedDescription)")
            moveAside()
            return nil
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func moveAside() {
        let salvage = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: salvage)
        try? FileManager.default.moveItem(at: fileURL, to: salvage)
    }
}
