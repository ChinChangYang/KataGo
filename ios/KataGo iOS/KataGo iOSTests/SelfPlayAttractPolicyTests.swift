//
//  SelfPlayAttractPolicyTests.swift
//  KataGo iOSTests
//
//  Truth table for the pure attract-mode policy: each precondition vetoes
//  auto-start independently, and thermal pressure stops a running demo.
//

import Testing
import Foundation
@testable import KataGoUICore

struct SelfPlayAttractPolicyTests {

    @Test("All preconditions met: the demo starts")
    func startsWhenAllClear() {
        #expect(SelfPlayAttract.shouldStart(pathIsEmpty: true,
                                            sceneIsActive: true,
                                            thermalState: .nominal,
                                            storeAvailable: true))
    }

    @Test("Each veto blocks the start independently")
    func eachVetoBlocks() {
        #expect(!SelfPlayAttract.shouldStart(pathIsEmpty: false,
                                             sceneIsActive: true,
                                             thermalState: .nominal,
                                             storeAvailable: true))
        #expect(!SelfPlayAttract.shouldStart(pathIsEmpty: true,
                                             sceneIsActive: false,
                                             thermalState: .nominal,
                                             storeAvailable: true))
        #expect(!SelfPlayAttract.shouldStart(pathIsEmpty: true,
                                             sceneIsActive: true,
                                             thermalState: .serious,
                                             storeAvailable: true))
        #expect(!SelfPlayAttract.shouldStart(pathIsEmpty: true,
                                             sceneIsActive: true,
                                             thermalState: .nominal,
                                             storeAvailable: false))
    }

    @Test("A warm (fair) device may still start; hot may not")
    func fairStartsHotDoesNot() {
        #expect(SelfPlayAttract.shouldStart(pathIsEmpty: true,
                                            sceneIsActive: true,
                                            thermalState: .fair,
                                            storeAvailable: true))
        #expect(!SelfPlayAttract.shouldStart(pathIsEmpty: true,
                                             sceneIsActive: true,
                                             thermalState: .critical,
                                             storeAvailable: true))
    }

    @Test("shouldStop across all thermal states")
    func stopTable() {
        #expect(!SelfPlayAttract.shouldStop(thermalState: .nominal))
        #expect(!SelfPlayAttract.shouldStop(thermalState: .fair))
        #expect(SelfPlayAttract.shouldStop(thermalState: .serious))
        #expect(SelfPlayAttract.shouldStop(thermalState: .critical))
    }
}
