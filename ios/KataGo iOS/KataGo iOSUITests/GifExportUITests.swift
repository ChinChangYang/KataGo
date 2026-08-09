//
//  GifExportUITests.swift
//  KataGo iOSUITests
//
//  Drives the Export GIF sheet end-to-end and verifies the preview reflects the
//  Loop / Final-hold options — the behavior that the computer-use screenshot
//  harness could not exercise (its synthetic taps don't fire a SwiftUI gesture
//  on the custom preview view). XCUITest synthesizes a real touch, so it can.
//
//  The "Replay" glyph (accessibilityIdentifier "gifPreviewReplayHint") is
//  present in the accessibility tree exactly when the preview is FROZEN on its
//  final frame — i.e. only with Loop OFF once the play-through finishes. The
//  test uses that element's presence/absence as the observable state:
//    * Loop ON  -> never freezes (glyph never appears),
//    * Loop OFF -> plays once, freezes (glyph appears),
//    * tap the preview -> replays (glyph disappears), then re-freezes.
//
//  Requires a game WITH MOVES; the app seeds a short committed game via the
//  DEBUG "--uitest-seed-gif-game" launch argument (see UITestSeed).
//

import XCTest

final class GifExportUITests: PortraitUITestCase {

    private let builtInTitle = "Built-in KataGo Network"
    private let seedName = "UITest GIF Game"
    private let seedLaunchArg = "--uitest-seed-gif-game"

    @MainActor
    func testExportGifPreviewReflectsLoopAndTapToReplay() throws {
        let app = makeApp(seedLaunchArg)
        launchToSeededGameBoard(app)

        // More ▸ This Game ▸ Export GIF.
        app.buttons["More"].firstMatch.tapAfterExists(self, "More menu")
        app.buttons["This Game"].firstMatch.tapAfterExists(self, "This Game submenu")
        app.buttons["Export GIF"].firstMatch.tapAfterExists(self, "Export GIF item")
        XCTAssertTrue(app.navigationBars["Export GIF"].waitForExistence(timeout: 10),
                      "Export GIF sheet did not appear")

        let preview = descendant(app, "gifPreview")
        // The freeze glyph, matched by identifier OR label so it resolves whatever
        // element type the `.contain` container exposes it as.
        let hint = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                  "gifPreviewReplayHint", "Replay"))
            .firstMatch

        // --- Loop ON (default): the preview loops and NEVER freezes. ---
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "GIF preview not found")
        XCTAssertFalse(hint.waitForExistence(timeout: 9),
                       "Replay glyph appeared while Loop was ON (preview should never freeze)")

        // --- Turn Loop OFF (it's below the fold). ---
        let loop = app.switches["Loop"].firstMatch
        reveal(app, loop, by: { app.swipeUp() })
        XCTAssertTrue(loop.waitForExistence(timeout: 10), "Loop toggle not found")
        // Tap the trailing edge where the switch control lives — a center tap
        // lands on the row label and does NOT flip a SwiftUI Toggle (proven in
        // CoreMLCacheFooterUITests). Default loops == true, so this turns it off.
        let before = loop.value as? String
        loop.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let flipped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", before ?? "1"), object: loop)
        XCTAssertEqual(XCTWaiter().wait(for: [flipped], timeout: 3), .completed,
                       "Loop toggle did not flip")
        XCTAssertEqual(loop.value as? String, "0", "Loop toggle did not turn off")

        // Scroll back up until the preview re-enters the view. XCUITest only sees
        // on-screen cells and the freeze glyph lives inside the preview, so it must
        // be visible. A swipe-until-present loop is deterministic; a fixed number of
        // momentum swipes is flaky (it can overshoot/bounce). One extra swipe then
        // settles it fully at the top (a no-op once the Form is clamped there).
        reveal(app, preview, by: { app.swipeDown() }, maxSwipes: 10)
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "Preview not back on screen after Loop toggle")
        app.swipeDown()

        // --- Loop OFF: plays once, then FREEZES on the final frame (glyph on). ---
        XCTAssertTrue(hint.waitForExistence(timeout: 20),
                      "Preview never froze on its final frame with Loop OFF")

        // --- Tap the preview to REPLAY -> un-freezes (glyph off). ---
        // Tap the container's center coordinate so it fires the preview's
        // .simultaneousGesture regardless of the container's hittability quirks.
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitForGone(hint, timeout: 6),
                      "Tapping the preview did not restart it (still frozen)")

        // --- Plays through again and re-freezes (a full replay cycle ran). ---
        XCTAssertTrue(hint.waitForExistence(timeout: 20),
                      "Preview did not freeze again after the replay tap")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "GifPreviewReplay"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["Done"].firstMatch.tap()
    }

    // MARK: - Navigation

    @MainActor
    private func launchToSeededGameBoard(_ app: XCUIApplication) {
        app.launch()

        // DEBUG forces the model picker — launch the built-in network.
        let row = app.staticTexts[builtInTitle]
        if row.waitForExistence(timeout: 20) {
            row.tap()
            let play = app.buttons["ModelDetailView.downloadPlayButton"]
            if play.waitForExistence(timeout: 15) { play.tap() }
        }
        // Board-ready sentinel; engine + on-the-fly CoreML conversion is slow.
        XCTAssertTrue(app.buttons["Forward to End"].waitForExistence(timeout: 360),
                      "Board did not appear (engine never finished launching)")

        // Reveal the Games list (leading nav-bar button), then open the seed.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) { back.tap() }

        let cell = app.staticTexts[seedName].firstMatch  // GameLinkView Text(name)
        reveal(app, cell, by: { app.swipeUp() })
        XCTAssertTrue(cell.waitForExistence(timeout: 15),
                      "Seeded game '\(seedName)' not found in the list")
        cell.tap()

        // Committed main line, both sides Human -> More visible, no branch.
        XCTAssertTrue(app.buttons["More"].firstMatch.waitForExistence(timeout: 60),
                      "Seeded game board did not appear (More button missing)")
    }

    // MARK: - Helpers

    @MainActor
    private func descendant(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        // The preview is an accessibility container (.isButton trait) that may
        // surface under buttons or otherElements — match by identifier only.
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Swipe (using `swipe`) until `element` is present (or hittable), up to
    /// `maxSwipes`. Off-screen SwiftUI List/Form cells aren't in the a11y tree.
    @MainActor
    private func reveal(_ app: XCUIApplication,
                        _ element: XCUIElement,
                        by swipe: () -> Void,
                        hittable: Bool = false,
                        maxSwipes: Int = 8) {
        var n = 0
        while !(hittable ? element.isHittable : element.exists) && n < maxSwipes {
            swipe()
            n += 1
        }
    }

    /// Poll until `element` leaves the accessibility tree, or the timeout.
    @MainActor
    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline { usleep(150_000) }
        return !element.exists
    }
}

private extension XCUIElement {
    /// Wait for existence, assert, then tap — trims repetitive boilerplate.
    @MainActor
    func tapAfterExists(_ test: XCTestCase, _ name: String, timeout: TimeInterval = 15) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "\(name) not found")
        tap()
    }
}
