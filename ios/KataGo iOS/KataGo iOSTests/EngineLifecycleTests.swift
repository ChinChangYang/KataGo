//
//  EngineLifecycleTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2026/4/11.
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct EngineLifecycleTests {

    // MARK: - EngineLifecycle

    @Test func markFirstResponseSetsTitle() {
        let lifecycle = EngineLifecycle()
        #expect(lifecycle.lastLoadedModelTitle == nil)

        lifecycle.markFirstResponse(modelTitle: "Built-in KataGo Network")

        #expect(lifecycle.lastLoadedModelTitle == "Built-in KataGo Network")
    }

    @Test func resetClearsTitle() {
        let lifecycle = EngineLifecycle()
        lifecycle.markFirstResponse(modelTitle: "Official KataGo Network")
        lifecycle.reset()

        #expect(lifecycle.lastLoadedModelTitle == nil)
    }

    // The launch-time recovery contract moved to `RecoveryDecisionTests` when
    // it grew from two outcomes to four: this suite is about the SIGNAL (the
    // engine answered), that one is about what the app does with it.
}
