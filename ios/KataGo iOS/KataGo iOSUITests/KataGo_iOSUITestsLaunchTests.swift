//
//  KataGo_iOSUITestsLaunchTests.swift
//  KataGo iOSUITests
//
//  Created by Chin-Chang Yang on 2023/7/2.
//

import XCTest

final class KataGo_iOSUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        // `runsForEachTargetApplicationUIConfiguration` makes XCTest run this
        // test once per orientation — and XCTest, not this file, applies the
        // rotation, so there is no `XCUIDevice` call here to notice. It leaves
        // the device in whichever orientation ran last, and the simulator
        // remembers that across processes, so the next class to measure a frame
        // silently measures landscape. That is what failed
        // `PhotoImportGridUITests` in the 2026-08-03 full-suite run: in
        // landscape the import sheet hits its 560 pt cap and the photo becomes
        // height-bound. XCTest re-applies each configuration before its run, so
        // restoring afterwards costs the sweep nothing.
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
    }

    @MainActor func testLaunch() throws {
        // This class cannot inherit `PortraitUITestCase.makeApp()` (see the
        // ⚠️ note in that file — the portrait pin would clobber XCTest's own
        // orientation sweep), so it repeats the baseline arguments here. Keep
        // it in step with `PortraitUITestCase.baselineLaunchArguments`.
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-reset-backend-settings"]
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
