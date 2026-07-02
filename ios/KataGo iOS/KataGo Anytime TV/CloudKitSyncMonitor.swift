//
//  CloudKitSyncMonitor.swift
//  KataGo Anytime TV
//
//  Observes the signals that tell the library whether an empty game list means
//  "still syncing", "signed out", "store degraded", or "genuinely no games":
//  CloudKit import events, remote-change heartbeats, and the iCloud account
//  status. All decision logic is the pure LibrarySyncPolicy (KataGoGameStore,
//  unit-tested); this class only turns notifications into its inputs.
//
//  Robust to missing signals by construction: `eventChangedNotification` from
//  SwiftData's internal NSPersistentCloudKitContainer is observed behavior,
//  not API contract — with zero event notifications the remote-change
//  heartbeat plus the launch grace window still resolve syncing → empty/grid.
//

import SwiftUI
import CoreData
import CloudKit
import KataGoUICore

@MainActor
@Observable
final class CloudKitSyncMonitor {
    /// iCloud account signal, refreshed at start and on `.CKAccountChanged`.
    private(set) var accountState: ICloudAccountState = .unknown
    /// A CloudKit import (or setup) event has started and not yet ended.
    private(set) var importInFlight = false
    /// A `.NSPersistentStoreRemoteChange` landed within the last few seconds —
    /// CloudKit posts a burst of these while merging the initial sync.
    private(set) var recentRemoteActivity = false
    /// The launch grace window has run out with no signal renewing it: an
    /// empty library is now an honest "No games yet", not "still checking".
    private(set) var graceExpired = false

    #if DEBUG
    /// Preview seam: previews must never touch the real store (the
    /// `tvStoreMode` getter would open it). Fixtures always set this.
    var storeModeOverride: LibraryStoreMode?
    #endif

    var storeMode: LibraryStoreMode {
        #if DEBUG
        if let storeModeOverride { return storeModeOverride }
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return .cloudKit
        }
        #endif
        return SharedModelContainer.tvStoreMode
    }

    func emptyLibraryState() -> EmptyLibraryState {
        LibrarySyncPolicy.emptyLibraryState(storeMode: storeMode,
                                            accountState: accountState,
                                            importInFlight: importInFlight,
                                            recentRemoteActivity: recentRemoteActivity,
                                            graceExpired: graceExpired)
    }

    var isSyncBannerVisible: Bool {
        LibrarySyncPolicy.isSyncBannerVisible(storeMode: storeMode,
                                              accountState: accountState,
                                              importInFlight: importInFlight,
                                              recentRemoteActivity: recentRemoteActivity)
    }

    /// Observer tokens. `nonisolated(unsafe)` so the nonisolated `deinit` can
    /// read them to unregister: written once in `start()` (on the main actor)
    /// and read once in `deinit`, so there is no actual concurrent access
    /// (the LibraryStore pattern). `@ObservationIgnored` keeps this a plain
    /// stored property — without it the @Observable macro's transform silently
    /// drops the `nonisolated(unsafe)`.
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    // The grace deadline is "last re-arm wins": normally 90 s (fresh launch,
    // import start, remote activity), but a successfully COMPLETED import is
    // CloudKit's definitive answer, so only a 10 s tail remains — a genuinely
    // empty account resolves to "No games yet" quickly, while a multi-cycle
    // initial sync keeps re-arming via the next import's start. Two fixed-delay
    // CoalescedTriggers (cross-cancelled) implement the two delays.
    private let graceLong = CoalescedTrigger(delay: .seconds(90))
    private let graceShort = CoalescedTrigger(delay: .seconds(10))
    /// Trailing-edge reset of `recentRemoteActivity` after the burst quiets;
    /// this is also what auto-hides the grid's sync pill.
    private let activityQuiet = CoalescedTrigger(delay: .seconds(10))

    private var started = false

    /// Idempotent; called once at launch (in parallel with the engine
    /// handshake, so sync gets a head start behind "Loading engine…").
    func start() {
        guard !started else { return }
        started = true

        armGrace(shortTail: false)
        refreshAccountStatus()

        observers = [
            // Import lifecycle from SwiftData's internal CloudKit container
            // (`object: nil` — the instance isn't reachable). Only Sendable
            // scalars leave the closure: `Event` itself must not cross into
            // the Task. `.setup` counts as import-like (it precedes the first
            // import); `.export` is deliberately ignored — opening a game on
            // the TV mutates its record, and the resulting export must not
            // drive "syncing" UI.
            NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event else { return }
                let isImportLike = (event.type == .import || event.type == .setup)
                let ended = (event.endDate != nil)
                let succeeded = event.succeeded
                Task { @MainActor in
                    self?.handleCloudKitEvent(isImportLike: isImportLike,
                                              ended: ended,
                                              succeeded: succeeded)
                }
            },
            // Activity heartbeat: CloudKit merges post a burst of these during
            // initial sync (proven on this stack by the macOS LibraryStore).
            NotificationCenter.default.addObserver(
                forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.noteRemoteActivity() }
            },
            NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshAccountStatus() }
            },
        ]
    }

    deinit {
        // Block-based observers are not auto-removed on dealloc.
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func handleCloudKitEvent(isImportLike: Bool, ended: Bool, succeeded: Bool) {
        guard isImportLike else { return }
        if !ended {
            importInFlight = true
            armGrace(shortTail: false)
        } else {
            importInFlight = false
            // A failed import re-arms nothing: the 90 s window from its start
            // keeps running, so an offline TV still settles to a verdict.
            if succeeded {
                armGrace(shortTail: true)
            }
        }
    }

    private func noteRemoteActivity() {
        recentRemoteActivity = true
        armGrace(shortTail: false)
        activityQuiet.schedule { [weak self] in
            self?.recentRemoteActivity = false
        }
    }

    private func armGrace(shortTail: Bool) {
        graceLong.cancel()
        graceShort.cancel()
        let trigger = shortTail ? graceShort : graceLong
        trigger.schedule { [weak self] in
            self?.graceExpired = true
        }
    }

    private func refreshAccountStatus() {
        Task { @MainActor [weak self] in
            // Always the app's explicit container — `CKContainer.default()`
            // derives from the bundle ID and would name the wrong container.
            let status = try? await CKContainer(identifier: SharedModelContainer.cloudKitContainerID)
                .accountStatus()
            guard let self else { return }
            switch status {
            case .available:
                self.accountState = .available
            case .noAccount, .restricted:
                self.accountState = .unavailable
            default:
                // Transient (`couldNotDetermine`, `temporarilyUnavailable`, or
                // the call threw): must not show "Sign in to iCloud" copy.
                self.accountState = .unknown
            }
        }
    }
}

// MARK: - Preview support

#if DEBUG
extension CloudKitSyncMonitor {
    /// A monitor with force-set state that never observes anything — for
    /// previews of the four empty states and the sync pill. Defaults
    /// `storeMode` to `.cloudKit` so no preview ever opens the real store.
    static func fixture(accountState: ICloudAccountState = .available,
                        importInFlight: Bool = false,
                        recentRemoteActivity: Bool = false,
                        graceExpired: Bool = false,
                        storeMode: LibraryStoreMode = .cloudKit) -> CloudKitSyncMonitor {
        let monitor = CloudKitSyncMonitor()
        monitor.accountState = accountState
        monitor.importInFlight = importInFlight
        monitor.recentRemoteActivity = recentRemoteActivity
        monitor.graceExpired = graceExpired
        monitor.storeModeOverride = storeMode
        return monitor
    }
}
#endif
