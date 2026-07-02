//
//  LibrarySyncStateTests.swift
//  KataGo iOSTests
//
//  Truth-table coverage for the pure empty-library decision cascade behind the
//  tvOS library's empty state (LibrarySyncPolicy in KataGoGameStore). Named
//  cases pin each cascade rule; the exhaustive sweep proves the closed-form
//  invariants over every input combination so no future reordering of the
//  cascade can silently change a cell.
//

import Testing
import KataGoUICore

@Suite("LibrarySyncPolicy")
struct LibrarySyncStateTests {

    private static let storeModes: [LibraryStoreMode] = [.cloudKit, .localOnly, .inMemory]
    private static let accountStates: [ICloudAccountState] = [.unknown, .available, .unavailable]
    private static let bools = [false, true]

    @Test("A degraded store is .unavailable no matter what else is true")
    func unavailableBeatsEverything() {
        for mode in [LibraryStoreMode.localOnly, .inMemory] {
            let state = LibrarySyncPolicy.emptyLibraryState(storeMode: mode,
                                                            accountState: .available,
                                                            importInFlight: true,
                                                            recentRemoteActivity: true,
                                                            graceExpired: false)
            #expect(state == .unavailable)
        }
    }

    @Test("Signed out beats syncing — waiting would never end")
    func signedOutBeatsSyncing() {
        let state = LibrarySyncPolicy.emptyLibraryState(storeMode: .cloudKit,
                                                        accountState: .unavailable,
                                                        importInFlight: true,
                                                        recentRemoteActivity: true,
                                                        graceExpired: false)
        #expect(state == .signedOut)
    }

    @Test("An import in flight holds .syncing past grace expiry")
    func importInFlightHoldsSyncingPastGrace() {
        let state = LibrarySyncPolicy.emptyLibraryState(storeMode: .cloudKit,
                                                        accountState: .available,
                                                        importInFlight: true,
                                                        recentRemoteActivity: false,
                                                        graceExpired: true)
        #expect(state == .syncing)
    }

    @Test("Recent remote activity holds .syncing past grace expiry")
    func recentActivityHoldsSyncingPastGrace() {
        let state = LibrarySyncPolicy.emptyLibraryState(storeMode: .cloudKit,
                                                        accountState: .available,
                                                        importInFlight: false,
                                                        recentRemoteActivity: true,
                                                        graceExpired: true)
        #expect(state == .syncing)
    }

    @Test("Fresh launch with no signals yet is .syncing (grace optimism)")
    func quietBeforeGraceIsSyncing() {
        let state = LibrarySyncPolicy.emptyLibraryState(storeMode: .cloudKit,
                                                        accountState: .available,
                                                        importInFlight: false,
                                                        recentRemoteActivity: false,
                                                        graceExpired: false)
        #expect(state == .syncing)
    }

    @Test("Quiet after grace is the honest .empty verdict")
    func quietAfterGraceIsEmpty() {
        let state = LibrarySyncPolicy.emptyLibraryState(storeMode: .cloudKit,
                                                        accountState: .available,
                                                        importInFlight: false,
                                                        recentRemoteActivity: false,
                                                        graceExpired: true)
        #expect(state == .empty)
    }

    @Test("An unknown account behaves exactly like an available one")
    func unknownAccountBehavesLikeAvailable() {
        for mode in Self.storeModes {
            for inFlight in Self.bools {
                for activity in Self.bools {
                    for grace in Self.bools {
                        let unknown = LibrarySyncPolicy.emptyLibraryState(storeMode: mode,
                                                                          accountState: .unknown,
                                                                          importInFlight: inFlight,
                                                                          recentRemoteActivity: activity,
                                                                          graceExpired: grace)
                        let available = LibrarySyncPolicy.emptyLibraryState(storeMode: mode,
                                                                            accountState: .available,
                                                                            importInFlight: inFlight,
                                                                            recentRemoteActivity: activity,
                                                                            graceExpired: grace)
                        #expect(unknown == available)
                    }
                }
            }
        }
    }

    @Test("Exhaustive sweep: the cascade matches its closed form on all 72 combinations")
    func exhaustiveSweepMatchesClosedForm() {
        for mode in Self.storeModes {
            for account in Self.accountStates {
                for inFlight in Self.bools {
                    for activity in Self.bools {
                        for grace in Self.bools {
                            let state = LibrarySyncPolicy.emptyLibraryState(storeMode: mode,
                                                                            accountState: account,
                                                                            importInFlight: inFlight,
                                                                            recentRemoteActivity: activity,
                                                                            graceExpired: grace)
                            let expected: EmptyLibraryState
                            if mode != .cloudKit {
                                expected = .unavailable
                            } else if account == .unavailable {
                                expected = .signedOut
                            } else if inFlight || activity || !grace {
                                expected = .syncing
                            } else {
                                expected = .empty
                            }
                            #expect(state == expected)
                        }
                    }
                }
            }
        }
    }

    @Test("Sync banner: visible only on a healthy store with live sync signals")
    func bannerVisibility() {
        // Visible: healthy store + either signal.
        #expect(LibrarySyncPolicy.isSyncBannerVisible(storeMode: .cloudKit,
                                                      accountState: .available,
                                                      importInFlight: true,
                                                      recentRemoteActivity: false))
        #expect(LibrarySyncPolicy.isSyncBannerVisible(storeMode: .cloudKit,
                                                      accountState: .unknown,
                                                      importInFlight: false,
                                                      recentRemoteActivity: true))
        // Each disqualifier hides it independently.
        #expect(!LibrarySyncPolicy.isSyncBannerVisible(storeMode: .localOnly,
                                                       accountState: .available,
                                                       importInFlight: true,
                                                       recentRemoteActivity: true))
        #expect(!LibrarySyncPolicy.isSyncBannerVisible(storeMode: .inMemory,
                                                       accountState: .available,
                                                       importInFlight: true,
                                                       recentRemoteActivity: true))
        #expect(!LibrarySyncPolicy.isSyncBannerVisible(storeMode: .cloudKit,
                                                       accountState: .unavailable,
                                                       importInFlight: true,
                                                       recentRemoteActivity: true))
        #expect(!LibrarySyncPolicy.isSyncBannerVisible(storeMode: .cloudKit,
                                                       accountState: .available,
                                                       importInFlight: false,
                                                       recentRemoteActivity: false))
    }
}
