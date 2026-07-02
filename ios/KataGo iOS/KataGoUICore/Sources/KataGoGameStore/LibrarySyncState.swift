//
//  LibrarySyncState.swift
//  KataGoGameStore
//
//  Pure decision logic for the tvOS library's empty state. On Apple TV,
//  CloudKit is the sole inbound path for games, so an empty @Query can mean
//  four very different things — initial sync still running, signed out of
//  iCloud, the store degraded to local-only/in-memory, or genuinely no games.
//  These functions turn the observable signals into the one state the UI
//  should show. Platform-agnostic and side-effect-free so the iOS-simulator
//  test target can exercise the full truth table (TV-target code is
//  unreachable from tests).
//

/// Which rung of the store-open ladder produced the shared container.
public enum LibraryStoreMode: Sendable, Equatable {
    /// The normal store, mirrored to the private CloudKit database.
    case cloudKit
    /// CloudKit open failed; same store without sync (retried next launch).
    case localOnly
    /// Even the local store failed; ephemeral in-memory placeholder.
    case inMemory
}

/// The iCloud account signal from `CKContainer.accountStatus()`.
public enum ICloudAccountState: Sendable, Equatable {
    /// Not yet determined, or a transient status (`couldNotDetermine`,
    /// `temporarilyUnavailable`). Treated optimistically like `available` —
    /// the async check resolves in about a second, and a wrong "Sign in to
    /// iCloud" flash is worse than a moment of spinner.
    case unknown
    /// Signed in (`available`).
    case available
    /// Signed out or restricted (`noAccount`, `restricted`) — waiting for a
    /// sync that can never start.
    case unavailable
}

/// What the library should render while the game query is empty.
public enum EmptyLibraryState: Sendable, Equatable {
    /// Games may still be on their way — show a spinner, not a verdict.
    case syncing
    /// No iCloud account: guide the user to Settings.
    case signedOut
    /// The store opened without CloudKit this launch: sync cannot happen.
    case unavailable
    /// Sync is idle and the account really has no games yet.
    case empty
}

public enum LibrarySyncPolicy {
    /// The empty-state decision, consulted only when the game query is empty
    /// (a non-empty grid never shows an empty state). A priority cascade —
    /// first match wins:
    ///
    /// 1. A degraded store means sync literally cannot happen; beats everything.
    /// 2. Signed out means the wait would never end; beats syncing.
    /// 3–4. An import in flight or fresh remote-change activity means data is
    ///    actively landing.
    /// 5. Within the launch grace window, stay optimistic — the first import
    ///    of a slow initial sync can take a while to produce any signal.
    /// 6. Only then is "No games yet" an honest verdict.
    public static func emptyLibraryState(storeMode: LibraryStoreMode,
                                         accountState: ICloudAccountState,
                                         importInFlight: Bool,
                                         recentRemoteActivity: Bool,
                                         graceExpired: Bool) -> EmptyLibraryState {
        guard storeMode == .cloudKit else { return .unavailable }
        guard accountState != .unavailable else { return .signedOut }
        if importInFlight { return .syncing }
        if recentRemoteActivity { return .syncing }
        if !graceExpired { return .syncing }
        return .empty
    }

    /// Whether the populated grid shows its "Syncing — N games so far…" pill:
    /// only while games can and do actively land (an import in flight or a
    /// remote-change burst), never on a degraded store or signed-out account.
    public static func isSyncBannerVisible(storeMode: LibraryStoreMode,
                                           accountState: ICloudAccountState,
                                           importInFlight: Bool,
                                           recentRemoteActivity: Bool) -> Bool {
        storeMode == .cloudKit
            && accountState != .unavailable
            && (importInFlight || recentRemoteActivity)
    }
}
