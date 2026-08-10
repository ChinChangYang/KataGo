//
//  KataGoTVApp.swift
//  KataGo Anytime TV
//
//  tvOS "Review & spectate" app: browse iCloud-synced games and watch live AI
//  analysis on the big screen. The in-process engine loads both the built-in b18
//  net and the human-SL net, running on CoreML/NE only. The ~2.1 GB Apple TV 4K
//  (A12) per-process memory limit is the operational constraint; Phase-0 validation
//  predates the second net and dual-net memory validation on device is pending.
//

import SwiftUI
import os
import KataGoUICore

@main
struct KataGoTVApp: App {
    @State private var engineLaunchStatus: EngineLaunchStatus

    init() {
        // Create the EngineLaunchStatus object first so we can capture a
        // direct reference to it in the updater closure — at init() time
        // the @State wrapper backing store isn't yet reachable via `self`
        // (mirrors KataGo_iOSApp).
        let status = EngineLaunchStatus()
        _engineLaunchStatus = State(initialValue: status)

        // A user-armed "Re-download Library from iCloud" wipes the local store
        // HERE — before the lazy SharedModelContainer is first touched in
        // `body` — so the container always opens fresh and re-imports.
        TVStoreReset.performIfRequested()

        // Wire the cache-aware CoreML bridge into the KataGoSwift seam before any
        // engine launch (mirrors the iOS app), and force the engine stack to link.
        registerCoreMLBridge()

        // Wire the engine-launch status updater seam so TVLoadingView can
        // show a secondary caption during cache-miss compiles.
        registerEngineLaunchStatusUpdater { phase in
            await MainActor.run { status.phase = phase }
        }
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(engineLaunchStatus)
        }
        .modelContainer(SharedModelContainer.shared)
    }
}

/// On-device memory readout for the Phase-0 / Phase-1 re-measure. `Available`
/// (`os_proc_available_memory()`) is the real per-process jetsam budget — not
/// device RAM. Surfaced as a small overlay so an operator can watch the plateau
/// with the real UI attached.
enum MemoryProbe {
    struct Reading { var availableMB: Double; var footprintMB: Double }

    static func reading() -> Reading {
        Reading(availableMB: Double(os_proc_available_memory()) / 1_048_576.0,
                footprintMB: footprintMB())
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576.0
    }
}
