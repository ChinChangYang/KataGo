//
//  KataGo_iOSUITests.swift
//  KataGo iOSUITests
//
//  Created by Chin-Chang Yang on 2023/7/2.
//

import XCTest

// The README screenshots this class used to capture come from
// `Screenshots/capture_screenshots.sh` now — a scripted pipeline that seeds
// one position on six platforms and composites each capture into Apple's
// product bezel, neither of which a UI test can do. What is left here is this
// target's launch smoke test.
//
// The portrait pin stays, and is no longer about screenshots:
// `PortraitUITestCase` exists because the simulator remembers its orientation
// across processes, and every class in this target states its own
// precondition rather than trusting upstream cleanup (see that class).
final class KataGo_iOSUITests: PortraitUITestCase {

    @MainActor func testExample() throws {
        // UI tests must launch the application that they test.
        let app = makeApp()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }
}
