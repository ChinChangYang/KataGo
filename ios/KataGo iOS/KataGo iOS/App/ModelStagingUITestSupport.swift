//
//  ModelStagingUITestSupport.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2026/8/9.
//
//  DEBUG-only test support: places an already-bundled network into Documents so
//  a UI test sees it as an ALREADY-DOWNLOADED model. Runs only when its launch
//  argument is present, is idempotent, and is compiled out of Release.
//

#if DEBUG
import Foundation
import KataGoUICore

/// Stages a catalog network on disk so the app treats it as downloaded.
///
/// **Why this exists: UI tests must not touch the network.**
/// `CoreMLCacheFooterUITests` needs a model that is *not* the bundled built-in
/// — its whole subject is that launching a DOWNLOADED model writes a Core ML
/// cache entry, which a bundled model cannot exercise. The only way it had to
/// get one was to pull ~2 MB from media.katagotraining.org inside a 180 s
/// ceiling, which turns an offline machine, a captive portal, a DNS hiccup or a
/// slow mirror into a red run — for an assertion that is not about downloading.
///
/// **The staged file is the real thing, not a stand-in.** The app already ships
/// `lionffen_b24c64_3x3_v3_12300.bin.gz` inside its own Safari-extension appex,
/// and the catalog's "Lionffen b24c64 Network" entry names that exact file at
/// that exact byte count (4,842,138). Copying it to the entry's own
/// `downloadedURL` leaves the app in a state that is byte-for-byte what a real
/// download would have produced, so nothing downstream can tell the difference
/// and the test still exercises the launch-a-downloaded-model path it guards.
/// Note it must stay a *different* network from the built-in: the Core ML cache
/// is keyed by model identity, so staging a copy of the built-in would hit the
/// same entry and the footer count under test would never move.
enum ModelStagingUITestSupport {

    /// Pass in `XCUIApplication.launchArguments` to stage the network.
    static let launchArg = "--uitest-stage-downloaded-model"

    /// The catalog entry to stage. Matched by file name rather than title so a
    /// user-visible rename cannot silently turn this into a no-op.
    static let stagedFileName = "lionffen_b24c64_3x3_v3_12300.bin.gz"

    /// Copies the bundled network to the catalog entry's download location.
    ///
    /// Call from `init()`, before any view body runs: `ModelPickerView` decides
    /// whether to show a model as downloaded by testing for the file, so
    /// staging it after the picker has rendered would race the very state the
    /// test reads.
    static func stageIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains(launchArg) else { return }

        guard let model = NeuralNetworkModel.allAvailable
            .first(where: { $0.fileName == stagedFileName }) else {
            // Deliberately loud. A silent return here would leave the test to
            // fail much later with "no trash button", which reads as a UI
            // regression rather than a catalog rename.
            print("UITEST STAGING FAILED — no catalog entry named \(stagedFileName)")
            return
        }
        guard let destination = model.downloadedURL else {
            print("UITEST STAGING FAILED — \(model.title) has no downloadedURL")
            return
        }
        guard let source = bundledSourceURL else {
            print("UITEST STAGING FAILED — \(stagedFileName) is not in the app bundle " +
                  "or any of its app extensions")
            return
        }

        let fm = FileManager.default
        // Idempotent: the simulator's Documents directory survives across runs,
        // so on the second run the file is already in place. Re-copy only if it
        // is missing or the wrong length, which also self-heals a truncated
        // copy from an interrupted run.
        let existingSize = (try? fm.attributesOfItem(atPath: destination.path)[.size]) as? Int
        if existingSize == model.fileSize { return }

        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)
            print("UITEST STAGING — staged \(model.title) at \(destination.path)")
        } catch {
            print("UITEST STAGING FAILED — copy to \(destination.path): \(error)")
        }
    }

    /// The bundled copy of `stagedFileName`, whether it ships in the app itself
    /// or — as today — inside one of its embedded app extensions. Searching
    /// both means adding or removing the Safari extension's copy does not
    /// silently break the staging.
    private static var bundledSourceURL: URL? {
        if let url = Bundle.main.url(forResource: stagedFileName, withExtension: nil) {
            return url
        }
        guard let plugIns = Bundle.main.builtInPlugInsURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: plugIns, includingPropertiesForKeys: nil) else { return nil }
        for appex in entries where appex.pathExtension == "appex" {
            let candidate = appex.appendingPathComponent(stagedFileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
#endif
