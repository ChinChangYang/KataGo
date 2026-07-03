//
//  TVStoreReset.swift
//  KataGo Anytime TV
//
//  "Re-download Library from iCloud" recovery: wipes the local SwiftData
//  store so the next launch re-imports everything from CloudKit (the tvOS
//  source of truth). Port of the macOS CloudKitStoreReset flow: the Settings
//  screen ARMS a flag and exits; the wipe happens on the NEXT launch, before
//  the lazy SharedModelContainer is first touched — the verified-good "quit
//  first, then delete" ordering. On tvOS `appGroupStoreURL()` is nil (no App
//  Group entitlement), so the reset directories collapse to Application
//  Support — exactly where `openTVOSStore` puts `default.store`.
//
//  NOTE: this fixes LOCAL store problems. It cannot repair a record that was
//  already corrupted in iCloud — the re-import downloads whatever CloudKit
//  holds. The confirmation dialog says so.
//

import Foundation
import KataGoUICore

enum TVStoreReset {
    static let flagKey = "TVSettings.storeResetRequested"

    /// Arm the reset; the caller then instructs the user and exits the app.
    static func arm() {
        UserDefaults.standard.set(true, forKey: flagKey)
        UserDefaults.standard.synchronize()
    }

    /// Called first thing in `KataGoTVApp.init()`, before anything can touch
    /// the lazy model container.
    static func performIfRequested() {
        guard UserDefaults.standard.bool(forKey: flagKey) else { return }
        // Clear the flag BEFORE wiping (anti-reset-loop, the macOS pattern):
        // if the wipe crashes we must not wipe again forever.
        UserDefaults.standard.removeObject(forKey: flagKey)
        UserDefaults.standard.synchronize()

        let fileManager = FileManager.default
        var removed: [String] = []
        for directory in SharedModelContainer.storeResetDirectories() {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in SharedModelContainer.storeArtifactNames(in: entries) {
                let url = directory.appending(path: name)
                do {
                    try fileManager.removeItem(at: url)
                    removed.append(name)
                } catch {
                    NSLog("TVStoreReset: failed to remove \(name): \(error.localizedDescription)")
                }
            }
        }
        NSLog("TVStoreReset: removed \(removed.count) store artifact(s): \(removed.joined(separator: ", "))")
    }
}
