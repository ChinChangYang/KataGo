//
//  BackendConfigSheetUITests.swift
//  KataGo iOSUITests
//
//  UI tests for the per-model Backend Settings sheet: the Backend picker
//  (MLX/GPU, CoreML/NE, GPU+ANE), the Max Board Size picker, and the Search
//  Threads stepper. This is pure UI and never launches the engine, so it is
//  safe on the simulator. (Whether the engine actually runs the chosen backend
//  / tunes at the chosen size can only be confirmed on a real device.)
//

import XCTest

// `PortraitUITestCase` matters more here than anywhere else, on both of its
// axes.
//
// Orientation: this class sorts FIRST, so it inherits whatever the PREVIOUS run
// left behind. On 2026-08-03 that is exactly how it failed — `stepper.isHittable`
// below came back false in an inherited landscape window, before any rotator in
// its own run had executed.
//
// Per-model settings: this class is the suite's only writer of them, and
// `makeApp()` clears them on every launch. That is what makes the "defaults to"
// assertions below legitimate — they read a state this launch established,
// rather than betting on the previous run having restored it. Because a failed
// assertion `abort()`s (`continueAfterFailure = false`, exceptions disabled),
// no end-of-test restore can be relied on, and a leaked Max Board Size of 13
// would make every 19x19 board in every later class render as "Too large board
// size". Anything new added here may therefore leave a non-default value
// behind, but must not depend on one.
final class BackendConfigSheetUITests: PortraitUITestCase {

    private let boardSizes = ["9x9", "13x13", "19x19", "37x37"]
    private let backends = ["MLX/GPU", "CoreML/NE", "GPU+ANE"]

    @MainActor
    func testMaxBoardSizePickerDefaultsChangesAndPersists() throws {
        let app = makeApp()
        app.launch()

        // Navigate from the model list into the built-in model's detail view,
        // without launching it. Done once: dismissing the config sheet returns
        // here, not to the list, so the reopen below must NOT open it again.
        openModelDetail(app)

        openBackendSheet(in: app)

        // All four "Max Board Size" segments must be present.
        for size in boardSizes {
            XCTAssertTrue(segment(in: app, size).waitForExistence(timeout: 10),
                          "Max Board Size option '\(size)' not found")
        }

        // Default selection is 19x19. `makeApp()` cleared the persisted value
        // at launch, so this reads a genuine default rather than whatever the
        // previous run happened to leave.
        XCTAssertTrue(segment(in: app, "19x19").isSelected,
                      "Max board size should default to 19x19, "
                      + "selected was: \(selectedBoardSize(in: app) ?? "none")")

        // Change to 13x13 and confirm the selection moves there. The section
        // is third in the form, so bring it on screen first.
        XCTAssertTrue(reveal(segment(in: app, "13x13"), in: app, by: { app.swipeUp() }, maxSwipes: 3),
                      "Max Board Size option '13x13' never came on screen")
        segment(in: app, "13x13").tap()
        XCTAssertTrue(segment(in: app, "13x13").isSelected,
                      "Tapping 13x13 did not select it")

        // Dismiss and reopen; the choice must persist (per-model UserDefaults).
        closeBackendSheet(in: app)
        openBackendSheet(in: app)
        let thirteen = segment(in: app, "13x13")
        XCTAssertTrue(thirteen.waitForExistence(timeout: 10) && thirteen.isSelected,
                      "Max board size did not persist as 13x13 across reopen, "
                      + "selected was: \(selectedBoardSize(in: app) ?? "none")")

        // Put 19x19 back. This is a courtesy — it keeps a manual launch on the
        // same simulator from meeting a 13x13 engine — and one more round-trip
        // through the picker. It is NOT what makes the suite safe: an abort at
        // any assertion above skips it, which is why the reset lives in
        // `makeApp()` instead.
        XCTAssertTrue(reveal(segment(in: app, "19x19"), in: app, by: { app.swipeUp() }, maxSwipes: 3),
                      "Max Board Size option '19x19' never came on screen")
        segment(in: app, "19x19").tap()
        XCTAssertTrue(segment(in: app, "19x19").isSelected,
                      "Selecting 19x19 again did not select it")
    }

    @MainActor
    func testBackendPickerChangesAndPersists() throws {
        let app = makeApp()
        app.launch()

        openModelDetail(app)

        openBackendSheet(in: app)

        // All three backend segments must be present.
        for name in backends {
            XCTAssertTrue(segment(in: app, name).waitForExistence(timeout: 10),
                          "Backend option '\(name)' not found")
        }

        // Default selection is CoreML/NE. Assertable for the same reason as the
        // board-size default above: `makeApp()` cleared the persisted choice at
        // launch. (Before that reset existed this test could only say "each
        // choice is selectable", because a stale value from a prior run would
        // have poisoned an absolute claim.)
        XCTAssertTrue(segment(in: app, "CoreML/NE").isSelected,
                      "Backend should default to CoreML/NE, "
                      + "selected was: \(selectedBackend(in: app) ?? "none")")

        // Select GPU+ANE; it must persist across a reopen (per-model UserDefaults).
        segment(in: app, "GPU+ANE").tap()
        XCTAssertTrue(segment(in: app, "GPU+ANE").isSelected,
                      "Tapping GPU+ANE did not select it")
        closeBackendSheet(in: app)
        openBackendSheet(in: app)
        let mux = segment(in: app, "GPU+ANE")
        XCTAssertTrue(mux.waitForExistence(timeout: 10) && mux.isSelected,
                      "Backend did not persist as GPU+ANE across reopen, "
                      + "selected was: \(selectedBackend(in: app) ?? "none")")

        // Back to CoreML/NE; it must persist too. A second round-trip, and a
        // courtesy for a manual launch — not a safety net (see the board-size
        // test above).
        segment(in: app, "CoreML/NE").tap()
        XCTAssertTrue(segment(in: app, "CoreML/NE").isSelected,
                      "Tapping CoreML/NE did not select it")
        closeBackendSheet(in: app)
        openBackendSheet(in: app)
        let coreml = segment(in: app, "CoreML/NE")
        XCTAssertTrue(coreml.waitForExistence(timeout: 10) && coreml.isSelected,
                      "Backend did not persist as CoreML/NE across reopen, "
                      + "selected was: \(selectedBackend(in: app) ?? "none")")
    }

    @MainActor
    func testSearchThreadsStepperIsPresent() throws {
        let app = makeApp()
        app.launch()

        openModelDetail(app)

        openBackendSheet(in: app)

        // The Search Threads control lives lower in the form. Wait for it to be
        // on screen, not merely present: on iOS 27 a below-the-fold Form cell is
        // already in the accessibility tree, and right after the tap the sheet
        // can still be sliding up — on 2026-09-26 `exists` held at once while
        // `isHittable` read false. `reveal` scrolls only while it stays out of
        // reach. Value/clamping/persistence behaviour is covered by the
        // BackendSettings unit tests; here we just verify the stepper is wired
        // into the sheet and reachable.
        let stepper = app.steppers["SearchThreadsStepper"]
        XCTAssertTrue(reveal(stepper, in: app, by: { app.swipeUp() }, maxSwipes: 4),
                      "Search Threads stepper never came on screen (exists: \(stepper.exists))")
    }

    /// The Core ML Routing control must be offered, enabled, for the built-in
    /// network, which always has a source file on disk.
    ///
    /// Offered once the probe has RESOLVED, not merely drawn: the button is
    /// on screen from the sheet's first frame, while the probe is still
    /// looking up the network, and only a resolved "source missing" swaps it
    /// for the "Download this network first." line. So the test waits for
    /// the button's value to name a resolved state. Compiled or not depends
    /// on what earlier launches left in the Core ML cache, which no launch
    /// argument resets, so either passes.
    ///
    /// Presence only, on purpose: tapping it reads a compute plan and, on a
    /// cache miss, converts the network first — tens of seconds of real work
    /// that would make this suite slow and flaky. The state machine behind
    /// the button is covered by CoreMLRoutingProbeTests, and the routing
    /// numbers themselves are meaningless on the Simulator anyway (no Neural
    /// Engine), which is why the section renders a caveat there.
    @MainActor
    func testCoreMLRoutingControlIsPresentForTheBuiltInNetwork() throws {
        let app = makeApp()
        app.launch()

        openModelDetail(app)

        openBackendSheet(in: app)

        // Read through a snapshot: once the source is found missing the
        // button is gone, and `value` on a query that matches nothing would
        // fail the test here instead of letting the wait time out below.
        let check = app.buttons["CoreMLRouting.checkButton"]
        let available = ["Compiled", "Not compiled"]
        let resolved = XCTNSPredicateExpectation(
            predicate: NSPredicate { element, _ in
                guard let value = (try? (element as? XCUIElement)?.snapshot())?.value as? String
                else { return false }
                return available.contains(value)
            },
            object: check)
        XCTAssertEqual(XCTWaiter().wait(for: [resolved], timeout: 30), .completed,
                       "Core ML routing never resolved to an available state for the built-in network "
                       + "(button: \(check.exists ? String(describing: (try? check.snapshot())?.value) : "none"), "
                       + "missing-source line shown: \(app.staticTexts["CoreMLRouting.unavailable"].exists))")
        XCTAssertTrue(check.isEnabled, "Core ML routing check button should be enabled")
    }

    // MARK: - Helpers

    /// From the model detail view, tap the gear button that presents
    /// BackendConfigSheet, and return once the sheet is on screen.
    /// (Navigation into the detail view happens once in the test body; the
    /// detail view persists across sheet dismissals.)
    ///
    /// The gear must be on screen, not merely present: it exists behind the
    /// sheet the whole time the sheet is up. A tap that lands while a sheet is
    /// still leaving can be swallowed, so tap again — but only while the gear
    /// is uncovered (hittable), since a tap on a covered gear would hit the
    /// sheet's own Done button in the same corner.
    @MainActor
    private func openBackendSheet(in app: XCUIApplication) {
        let gear = app.buttons["Backend Settings"]
        XCTAssertTrue(waitForOnScreen(gear, in: app, timeout: 10),
                      "Backend Settings gear button not on screen")
        let backend = segment(in: app, "CoreML/NE")
        for _ in 0..<3 where !backend.exists && isOnScreen(gear, in: app) && gear.isHittable {
            gear.tap()
            _ = backend.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(waitForOnScreen(backend, in: app, timeout: 10),
                      "Backend Settings sheet did not open")
    }

    /// Taps Done and waits for the sheet to go. The sheet's own Done leaving
    /// is the proof: it sits in the sheet's navigation bar, so no scroll can
    /// take it out of the tree. A Backend segment is no proof once `reveal`
    /// has scrolled the form, because iOS 27 drops rows scrolled off the top
    /// from the tree, and the gear the next reopen taps is in the tree the
    /// whole time.
    @MainActor
    private func closeBackendSheet(in app: XCUIApplication) {
        let done = app.buttons["BackendConfigSheet.done"]
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10),
                      "Backend Settings sheet did not close after Done")
    }

    @MainActor
    private func segment(in app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons[label]
    }

    /// For diagnostics on failure: which board-size segment currently reads selected.
    @MainActor
    private func selectedBoardSize(in app: XCUIApplication) -> String? {
        boardSizes.first { app.buttons[$0].exists && app.buttons[$0].isSelected }
    }

    /// For diagnostics on failure: which backend segment currently reads selected.
    @MainActor
    private func selectedBackend(in app: XCUIApplication) -> String? {
        backends.first { app.buttons[$0].exists && app.buttons[$0].isSelected }
    }
}
