//
//  TVPlayabilityTests.swift
//  KataGo iOSTests
//

import Testing
@testable import KataGoUICore

struct TVPlayabilityTests {
    @Test("asymmetric unfinished games are playable, both directions")
    func asymmetricUnfinishedIsPlayable() {
        #expect(TVPlayability.isPlayable(blackMaxTime: 0, whiteMaxTime: 0.5,
                                         sgf: "(;FF[4]GM[1]SZ[19];B[pd])"))
        #expect(TVPlayability.isPlayable(blackMaxTime: 0.5, whiteMaxTime: 0,
                                         sgf: "(;FF[4]GM[1]SZ[19])"))
    }

    @Test("symmetric configs review instead")
    func symmetricIsNotPlayable() {
        #expect(!TVPlayability.isPlayable(blackMaxTime: 0, whiteMaxTime: 0,
                                          sgf: "(;FF[4]GM[1]SZ[19])"))
        #expect(!TVPlayability.isPlayable(blackMaxTime: 0.5, whiteMaxTime: 0.5,
                                          sgf: "(;FF[4]GM[1]SZ[19])"))
    }

    @Test("finished games review instead")
    func finishedIsNotPlayable() {
        #expect(!TVPlayability.isPlayable(blackMaxTime: 0, whiteMaxTime: 0.5,
                                          sgf: "(;FF[4]GM[1]SZ[19]RE[B+3.5];B[pd])"))
        #expect(!TVPlayability.isPlayable(blackMaxTime: 0, whiteMaxTime: 0.5,
                                          sgf: "(;FF[4]GM[1]SZ[19];B[pd];W[];B[])"))
    }
}
