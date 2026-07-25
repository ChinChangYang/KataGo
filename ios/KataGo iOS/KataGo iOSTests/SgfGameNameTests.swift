//
//  SgfGameNameTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct SgfGameNameTests {
    @Test func combinesGameNameAndPlayers() {
        let sgf = "(;FF[4]GM[1]SZ[19]GN[Lee Sedol vs AlphaGo game 4]PB[Lee Sedol]PW[AlphaGo];B[pd])"
        #expect(SgfGameName.derive(fromSgf: sgf)
                == "Lee Sedol vs AlphaGo game 4 — Lee Sedol vs AlphaGo")
    }

    @Test func playersOnlyWhenNoGameName() {
        let sgf = "(;FF[4]GM[1]SZ[19]PB[Shin Jinseo]PW[Ke Jie];B[pd])"
        #expect(SgfGameName.derive(fromSgf: sgf) == "Shin Jinseo vs Ke Jie")
    }

    @Test func gameNameOnlyWhenPlayersMissing() {
        let sgf = "(;FF[4]GM[1]SZ[19]GN[Rating game 2037735];B[pd])"
        #expect(SgfGameName.derive(fromSgf: sgf) == "Rating game 2037735")
    }

    /// katagotraining self-play puts the SAME model string in PB and PW;
    /// "X vs X" is noise.
    @Test func collapsesIdenticalSelfPlayPlayers() {
        let model = "kata1-b18c384nbt-s8526915840-d4485393469"
        let sgf = "(;FF[4]GM[1]SZ[19]PB[\(model)]PW[\(model)];B[pd])"
        #expect(SgfGameName.derive(fromSgf: sgf) == model)
    }

    /// Our own printsgf writes PB[]PW[] — empty values must not become a name.
    @Test func emptyPlayerValuesAreNotAName() {
        #expect(SgfGameName.derive(fromSgf: "(;FF[4]GM[1]SZ[19]PB[]PW[];B[pd])") == nil)
    }

    @Test func noIdentityPropertiesYieldsNil() {
        #expect(SgfGameName.derive(fromSgf: "(;FF[4]GM[1]SZ[19]KM[7.5];B[pd])") == nil)
    }

    /// The extension escapes "]" when injecting a page title; unescaping must
    /// restore it rather than truncating the value there.
    @Test func honorsEscapedBracketInValue() {
        let sgf = #"(;FF[4]GM[1]SZ[19]GN[Game \[final\] round];B[pd])"#
        #expect(SgfGameName.derive(fromSgf: sgf) == "Game [final] round")
    }

    @Test func collapsesWhitespaceAndStripsControlCharacters() {
        let sgf = "(;FF[4]GM[1]SZ[19]GN[Rating\u{0007}   game\n2037735];B[pd])"
        #expect(SgfGameName.derive(fromSgf: sgf) == "Rating game 2037735")
    }

    @Test func clampsOverlongNames() {
        let long = String(repeating: "A", count: 400)
        let derived = SgfGameName.derive(fromSgf: "(;FF[4]GM[1]SZ[19]GN[\(long)];B[pd])")
        #expect(derived?.count == SgfGameName.maxLength)
        #expect(derived?.hasSuffix("…") == true)
    }

    /// "PB" must not match inside a longer property identifier.
    @Test func ignoresPropertySuffixCollision() {
        let sgf = "(;FF[4]GM[1]SZ[19]XPB[not a player]PW[Ke Jie];B[pd])"
        #expect(SgfGameName.derive(fromSgf: sgf) == "Ke Jie")
    }

    /// GN presence is what tells the shared iOS spool drain that a file came
    /// from Safari rather than from the Messages extension.
    @Test func detectsGameNameMarker() {
        #expect(SgfGameName.hasGameName(inSgf: "(;FF[4]GN[Web game];B[pd])"))
        #expect(!SgfGameName.hasGameName(inSgf: "(;FF[4]PB[a]PW[b];B[pd])"))
    }
}
