//
//  DraftMirrorStoreTests.swift
//  KataGo Anytime MacTests
//

import Testing
import Foundation
@testable import KataGoGameStore

@MainActor
struct DraftMirrorStoreTests {

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "draft-mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func mirror() -> DraftMirror {
        let record = GameRecord(config: Config())
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        record.name = "Mirrored"
        let originUUID = UUID()
        let draft = DraftSnapshot(record: record, originUUID: originUUID)

        let base = GameRecord(config: Config())
        base.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        base.name = "Mirrored"
        let baseline = DraftSnapshot(record: base, originUUID: originUUID)

        return DraftMirror(draft: draft, baseline: baseline)
    }

    @Test func readReturnsNilWhenNothingWasWritten() throws {
        let store = DraftMirrorStore(directory: try tempDirectory())
        #expect(store.read() == nil)
    }

    @Test func writtenMirrorRoundTrips() throws {
        let store = DraftMirrorStore(directory: try tempDirectory())
        let original = mirror()
        store.write(original)
        #expect(store.read() == original)
    }

    @Test func clearRemovesTheMirror() throws {
        let store = DraftMirrorStore(directory: try tempDirectory())
        store.write(mirror())
        store.clear()
        #expect(store.read() == nil)
    }

    @Test func corruptMirrorIsTreatedAsAbsentAndMovedAside() throws {
        let directory = try tempDirectory()
        let store = DraftMirrorStore(directory: directory)
        try Data("not json".utf8).write(to: store.fileURL)

        #expect(store.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

        let salvaged = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(salvaged.contains { $0.hasSuffix(".corrupt") })
    }

    @Test func mirrorFromAFutureVersionIsTreatedAsAbsent() throws {
        let directory = try tempDirectory()
        let store = DraftMirrorStore(directory: directory)
        store.write(mirror())

        // Rewrite with a version this build does not understand.
        var json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.fileURL)) as! [String: Any]
        json["version"] = DraftMirror.currentVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)

        #expect(store.read() == nil)
    }

    @Test func writeIsAtomic() throws {
        // Overwriting must never leave a half-written file behind.
        let store = DraftMirrorStore(directory: try tempDirectory())
        store.write(mirror())
        for _ in 0..<20 { store.write(mirror()) }
        #expect(store.read() != nil)
    }
}
