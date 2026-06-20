//
//  SgfOperationsTests.swift
//  KataGo iOSTests
//

import Testing
@testable import KataGoUICore

struct SgfOperationsTests {
    private let sgf = "(;FF[4]GM[1]SZ[19]KM[6.5];B[pd];W[dp])"

    @Test func mirrorsSgfHelperForBasics() {
        let ops = SgfOperations(sgf: sgf)
        let ref = SgfHelper(sgf: sgf)
        #expect(ops.moveSize == ref.moveSize)
        #expect(ops.xSize == ref.xSize)
        #expect(ops.ySize == ref.ySize)
        #expect(ops.getMove(at: 0)?.location.x == ref.getMove(at: 0)?.location.x)
        #expect(ops.rules.komi == ref.rules.komi)
    }
}
