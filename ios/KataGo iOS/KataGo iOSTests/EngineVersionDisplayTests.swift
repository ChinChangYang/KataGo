//
//  EngineVersionDisplayTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

/// `TopUIState.engineVersionDisplay` cleans the raw GTP `version` reply (which
/// the Configurations sheet now shows in place of the retired launch screen):
/// it strips the leading GTP success token ("= ") and surrounding whitespace,
/// and reports nil when there is nothing meaningful to show.
struct EngineVersionDisplayTests {

    @Test func stripsGtpSuccessTokenPrefix() {
        let state = TopUIState()
        state.engineVersion = "= 1.16.3+b18c384nbt-s1+b18c384nbt-humanv0-s2"
        #expect(state.engineVersionDisplay == "1.16.3+b18c384nbt-s1+b18c384nbt-humanv0-s2")
    }

    @Test func leavesAnUnprefixedVersionUntouched() {
        let state = TopUIState()
        state.engineVersion = "1.16.3"
        #expect(state.engineVersionDisplay == "1.16.3")
    }

    @Test func trimsSurroundingWhitespaceAndNewlines() {
        let state = TopUIState()
        state.engineVersion = "  = 1.16.3 \n"
        #expect(state.engineVersionDisplay == "1.16.3")
    }

    @Test func isNilWhenNoVersionCaptured() {
        let state = TopUIState()
        #expect(state.engineVersion == nil)
        #expect(state.engineVersionDisplay == nil)
    }

    @Test func isNilWhenOnlyTheSuccessTokenIsPresent() {
        let state = TopUIState()
        state.engineVersion = "= "
        #expect(state.engineVersionDisplay == nil)
    }

    @Test func isNilOnGtpFailureReply() {
        // A "? …" reply means the version handshake failed; don't leak the
        // raw error text into the Configurations sheet.
        let state = TopUIState()
        state.engineVersion = "? version not available"
        #expect(state.engineVersionDisplay == nil)
    }
}
