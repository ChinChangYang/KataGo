//
//  GameRecordDraftCopyTests.swift
//  KataGo Anytime MacTests
//

import Testing
import Foundation
@testable import KataGoGameStore

@MainActor
struct GameRecordDraftCopyTests {

    private func makeOrigin() -> GameRecord {
        let record = GameRecord(config: Config())
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        record.currentIndex = 2
        record.name = "Origin"
        record.comments = [1: "note"]
        record.moves = [0: "D16", 1: "Q4"]
        record.winRates = [1: 0.5]
        record.concreteConfig.komi = 6.5
        return record
    }

    @Test func copyPreservesIdentityFields() {
        let origin = makeOrigin()
        let copy = origin.detachedDraftCopy()
        #expect(copy.uuid == origin.uuid)
        #expect(copy.name == "Origin")
        #expect(copy.lastModificationDate == origin.lastModificationDate)
    }

    @Test func copyCarriesTheGameContent() {
        let origin = makeOrigin()
        let copy = origin.detachedDraftCopy()
        #expect(copy.sgf == origin.sgf)
        #expect(copy.currentIndex == 2)
        #expect(copy.comments?[1] == "note")
        #expect(copy.moves?[1] == "Q4")
        #expect(copy.winRates?[1] == 0.5)
    }

    @Test func copyHasItsOwnConfigObject() {
        let origin = makeOrigin()
        let copy = origin.detachedDraftCopy()
        #expect(copy.concreteConfig !== origin.concreteConfig)
        #expect(copy.concreteConfig.komi == 6.5)
        copy.concreteConfig.komi = 0.5
        #expect(origin.concreteConfig.komi == 6.5)
    }

    @Test func mutatingTheCopyLeavesTheOriginAlone() {
        let origin = makeOrigin()
        let copy = origin.detachedDraftCopy()
        copy.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp];B[cc])"
        copy.name = "Changed"
        #expect(origin.sgf == "(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(origin.name == "Origin")
    }
}
