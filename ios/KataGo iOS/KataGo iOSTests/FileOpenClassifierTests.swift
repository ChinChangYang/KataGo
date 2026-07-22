import Testing
import Foundation
import UIKit
import KataGoUICore

/// Classifies a URL opened WITH the app (Files "Open in" / share sheet / Finder
/// "Open With") as image-or-not, reads its bytes for the photo-recognition
/// import, and safely cleans up share-sheet Inbox copies. The Inbox cleanup
/// carries a hard safety contract: it must be provably unable to delete an
/// in-place Files URL (the user's real file). All logic here is pure/injectable
/// so it is unit-testable apart from the SwiftUI wiring.
struct FileOpenClassifierTests {

    // MARK: - isImage via the UTType(filenameExtension:) fallback (no file)

    @Test func isImage_byExtension_imageExtensionsAreTrue() {
        #expect(FileOpenClassifier.isImage(URL(fileURLWithPath: "/nope/board.png")))
        #expect(FileOpenClassifier.isImage(URL(fileURLWithPath: "/nope/board.jpg")))
        #expect(FileOpenClassifier.isImage(URL(fileURLWithPath: "/nope/board.jpeg")))
        #expect(FileOpenClassifier.isImage(URL(fileURLWithPath: "/nope/board.heic")))
    }

    @Test func isImage_byExtension_isCaseInsensitive() {
        #expect(FileOpenClassifier.isImage(URL(fileURLWithPath: "/nope/board.PNG")))
        #expect(FileOpenClassifier.isImage(URL(fileURLWithPath: "/nope/board.JPG")))
        #expect(FileOpenClassifier.isImage(URL(fileURLWithPath: "/nope/board.HEIC")))
    }

    @Test func isImage_byExtension_nonImageExtensionsAreFalse() {
        #expect(!FileOpenClassifier.isImage(URL(fileURLWithPath: "/nope/game.sgf")))
        #expect(!FileOpenClassifier.isImage(URL(fileURLWithPath: "/nope/notes.txt")))
        #expect(!FileOpenClassifier.isImage(URL(fileURLWithPath: "/nope/extensionless")))
    }

    // MARK: - isImage / imageData via the .contentTypeKey resource value (real file)

    @Test func isImage_viaResourceKey_realPNGIsTrue() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("photo.png")
        try onePixelPNGData().write(to: png)
        #expect(FileOpenClassifier.isImage(png))
    }

    @Test func isImage_viaResourceKey_realSGFTextIsFalse() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sgf = dir.appendingPathComponent("game.sgf")
        try "(;GM[1]FF[4])".data(using: .utf8)!.write(to: sgf)
        #expect(!FileOpenClassifier.isImage(sgf))
    }

    @Test func imageData_realPNG_roundTripsExactBytes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("photo.png")
        let bytes = onePixelPNGData()
        try bytes.write(to: png)
        #expect(FileOpenClassifier.imageData(at: png) == bytes)
    }

    @Test func imageData_nonImage_isNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sgf = dir.appendingPathComponent("game.sgf")
        try "(;GM[1]FF[4])".data(using: .utf8)!.write(to: sgf)
        #expect(FileOpenClassifier.imageData(at: sgf) == nil)
    }

    // MARK: - cleanUpInboxFile safety contract (injected container roots)

    @Test func cleanUpInboxFile_deletesFileUnderInboxWithinARoot() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("board.png")
        try Data([0x89, 0x50]).write(to: file)

        FileOpenClassifier.cleanUpInboxFile(at: file, containerRoots: [root])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func cleanUpInboxFile_deletesBundleSuffixedInbox() throws {
        // tmp/<bundleID>-Inbox is the second real inbox shape — the parent's
        // name only ENDS with "Inbox", it is not exactly "Inbox".
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("com.example.app-Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("board.jpg")
        try Data([0xFF, 0xD8]).write(to: file)

        FileOpenClassifier.cleanUpInboxFile(at: file, containerRoots: [root])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func cleanUpInboxFile_deletesAcrossSymlinkedRootSpelling() throws {
        // On a real device the incoming URL and the FileManager-derived roots can
        // spell the same location differently across a symlink (/private/var vs
        // /var). Resolving symlinks on BOTH sides must still authorize deletion;
        // a raw string-prefix check would miss and silently leak the Inbox copy.
        let realRoot = try makeTempDir()
        let linkParent = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: realRoot)
            try? FileManager.default.removeItem(at: linkParent)
        }
        // A symlink that points at the real root — a different spelling of it.
        let linkedRoot = linkParent.appendingPathComponent("linkedRoot", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)

        // The file arrives via the real (resolved) spelling of the root...
        let inbox = realRoot.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("board.png")
        try Data([0x89, 0x50]).write(to: file)

        // ...while the container root arrives via the symlinked spelling. Only
        // resolving symlinks on both sides makes the prefix check hold and deletes.
        FileOpenClassifier.cleanUpInboxFile(at: file, containerRoots: [linkedRoot])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func cleanUpInboxFile_neverDeletesRootLevelFile() throws {
        // An in-place file that happens to sit directly under a container root
        // (no Inbox parent) is the user's real file — must survive.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("board.png")
        try Data([0x89, 0x50]).write(to: file)

        FileOpenClassifier.cleanUpInboxFile(at: file, containerRoots: [root])
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func cleanUpInboxFile_neverDeletesFileOutsideTheRoots() throws {
        // A plain file outside every container root (an in-place Files URL) —
        // must survive even though it is a plausible import target.
        let root = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let file = outside.appendingPathComponent("board.png")
        try Data([0x89, 0x50]).write(to: file)

        FileOpenClassifier.cleanUpInboxFile(at: file, containerRoots: [root])
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func cleanUpInboxFile_neverDeletesInboxDirOutsideTheRoots() throws {
        // The critical case: an "Inbox"-named directory that is NOT under any
        // container root (e.g. a folder the user opened in place from Files that
        // they happened to name "Inbox"). The Inbox-suffix match alone must not
        // authorize deletion — being under a root is also required.
        let root = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let inbox = outside.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("board.png")
        try Data([0x89, 0x50]).write(to: file)

        FileOpenClassifier.cleanUpInboxFile(at: file, containerRoots: [root])
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A real, fully-encoded 1×1 PNG (a few bytes of PNG magic would not carry a
    /// resolvable content type). `UIGraphicsImageRenderer.pngData()` is valid PNG.
    private func onePixelPNGData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}

/// The cold-launch image latch: bytes are read AT RECEIPT (the root
/// `.onOpenURL`) into `DeepLinkRouter.pendingImageImport`, then drained by
/// `GameSplitView`. Exercised on a FRESH router instance (never `.shared`, which
/// the App Intents own) so there is no cross-test residue.
struct PendingImageImportTests {
    @Test func equality_matchesOnBytesAndName() {
        let a = PendingImageImport(imageData: Data([1, 2, 3]), suggestedName: "Board")
        let b = PendingImageImport(imageData: Data([1, 2, 3]), suggestedName: "Board")
        let differentBytes = PendingImageImport(imageData: Data([1, 2, 4]), suggestedName: "Board")
        let differentName = PendingImageImport(imageData: Data([1, 2, 3]), suggestedName: "Other")
        #expect(a == b)
        #expect(a != differentBytes)
        #expect(a != differentName)
    }

    @Test @MainActor func router_latchSetAndClear_onFreshInstance() {
        let router = DeepLinkRouter()
        #expect(router.pendingImageImport == nil)

        let pending = PendingImageImport(imageData: Data([9, 8, 7]), suggestedName: "Board Photo")
        router.pendingImageImport = pending
        #expect(router.pendingImageImport == pending)

        router.pendingImageImport = nil
        #expect(router.pendingImageImport == nil)
    }
}
