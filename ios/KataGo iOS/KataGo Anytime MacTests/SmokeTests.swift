//
//  SmokeTests.swift
//  KataGo Anytime MacTests
//

import Testing
import SwiftData
@testable import KataGoGameStore
@testable import KataGoAnalysisKit

struct SmokeTests {
    @Test func linksTheBridgeFreeGameStore() {
        let config = Config()
        let record = GameRecord(config: config)
        #expect(record.sgf == GameRecord.defaultSgf)
    }

    @Test func linksTheBridgeFreeSgfScanner() {
        let scan = SgfHeaderScan(sgf: "(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(scan?.moveCount == 2)
    }
}
