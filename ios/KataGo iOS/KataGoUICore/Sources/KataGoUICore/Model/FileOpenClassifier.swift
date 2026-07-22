//
//  FileOpenClassifier.swift
//  KataGoUICore
//
//  Classifies a URL opened WITH the app (Files "Open in" / share sheet / Finder
//  "Open With") and reads its bytes for the existing board-photo-recognition
//  import. Kept to Foundation + UniformTypeIdentifiers so the package stays
//  platform-clean for its watchOS / tvOS builds.
//

import Foundation
import UniformTypeIdentifiers

public enum FileOpenClassifier {
    /// True when `url` is an image. Mirrors `GameSplitView.imageDataIfImage`'s
    /// check: the file's `.contentTypeKey` when available (a real file on disk),
    /// falling back to the filename extension (a cold-launch URL whose backing
    /// file may not be reachable yet), then `conforms(to: .image)`.
    public static func isImage(_ url: URL) -> Bool {
        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let contentType else { return false }
        return contentType.conforms(to: .image)
    }

    /// The image bytes when `url` is an image, otherwise nil. Reads inside a
    /// security-scoped access (mirroring `GameRecord.readSgfContent`) so a
    /// Files "Open in" URL can be read; a non-security-scoped URL simply reads
    /// directly.
    public static func imageData(at url: URL) -> Data? {
        guard isImage(url) else { return nil }
        let hasSecurityAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try? Data(contentsOf: url)
    }

    /// Deletes a share-sheet / Mail Inbox copy after its bytes have been latched.
    ///
    /// Safety contract: deletes ONLY when the file lives under one of
    /// `containerRoots` (the app's own Documents + tmp) AND its parent directory
    /// name ends in "Inbox" — covering `Documents/Inbox` and
    /// `tmp/<bundleID>-Inbox`, the two shapes the system uses for opened-in
    /// copies. It can therefore never delete an in-place Files URL (the user's
    /// real file), which lives outside these roots. `containerRoots` is injected
    /// so the guarantee is unit-testable; on macOS this is never called (no
    /// Inbox mechanism, and Powerbox originals must never be deleted).
    public static func cleanUpInboxFile(at url: URL,
                                        containerRoots: [URL] = defaultContainerRoots) {
        let fileURL = url.standardizedFileURL
        // Require an "*Inbox" parent directory (Documents/Inbox or the
        // tmp/<bundleID>-Inbox variant, whose name only ENDS with "Inbox").
        guard fileURL.deletingLastPathComponent().lastPathComponent.hasSuffix("Inbox") else {
            return
        }
        // AND require the file to live under one of the app's own container
        // roots. The Inbox-suffix match alone must never authorize deletion — a
        // user could open in place a folder they happened to name "Inbox".
        let filePath = fileURL.path
        let isUnderContainerRoot = containerRoots.contains { root in
            let rootPath = root.standardizedFileURL.path
            return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
        }
        guard isUnderContainerRoot else { return }

        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The app's own container roots under which an Inbox copy may legitimately
    /// live: the sandbox `Documents` directory (`Documents/Inbox`) and the
    /// temporary directory (`tmp/<bundleID>-Inbox`).
    public static var defaultContainerRoots: [URL] {
        var roots = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        roots.append(FileManager.default.temporaryDirectory)
        return roots
    }
}
