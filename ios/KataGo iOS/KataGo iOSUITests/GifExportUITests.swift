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
        // On screen, not merely present: the tap below is a coordinate tap,
        // which never scrolls anything into view.
        let loop = app.switches["Loop"].firstMatch
        XCTAssertTrue(reveal(loop, in: app, by: { app.swipeUp() }, maxSwipes: 4),
                      "Loop toggle never came on screen")
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

        // Scroll back up until the whole preview is clear of the navigation
        // bar: the freeze glyph lives inside it, and the replay tap below is a
        // coordinate tap, which never scrolls. Swipe only while it is NOT
        // clear. On iOS 27 the preview stays in the tree while scrolled off, so
        // a swipe-until-present loop never swiped; and a swipe down on a Form
        // already at its top is a dismissal gesture for the sheet, so there is
        // no extra "settling" swipe either: the loop also stops as soon as a
        // swipe no longer moves the preview, because the Form is then at its
        // top. The check reads the frame, not `isHittable`, which an
        // accessibility container like this one has misreported.
        let bar = app.navigationBars["Export GIF"]
        func previewTop() -> CGFloat? {
            guard preview.exists, let frame = try? preview.snapshot().frame else { return nil }
            return frame.minY
        }
        func previewClear() -> Bool {
            guard bar.exists, preview.exists,
                  let frame = try? preview.snapshot().frame else { return false }
            return frame.minY >= bar.frame.maxY - 2 && frame.maxY <= app.frame.maxY
        }
        var swipes = 0
        var lastTop = previewTop()
        while !previewClear() && swipes < 6 && bar.exists {
            app.swipeDown()
            swipes += 1
            let settled = Date().addingTimeInterval(1.5)
            while !previewClear() && Date() < settled { usleep(150_000) }
            let top = previewTop()
            if let top, top == lastTop { break }
            lastTop = top
        }
        XCTAssertTrue(bar.exists, "The Export GIF sheet closed while scrolling back to the preview")
        XCTAssertTrue(previewClear(), "Preview not fully back on screen after the Loop toggle")

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
        // Engine-ready sentinel: the board itself draws before the engine is
        // up, so a toolbar button existing proves nothing any more.
        waitForBoardInSync(app)

        // Reveal the Games list (leading nav-bar button), then open the seed.
        // Prove the list appeared: a Back tap dropped while analysis re-renders
        // the board would otherwise surface later as "Seeded game not found".
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(waitForOnScreen(back, in: app, timeout: 10),
                      "The board's leading bar button is not on screen")
        back.tap()
        XCTAssertTrue(app.navigationBars["Games"].waitForExistence(timeout: 10),
                      "The Games list did not appear after Back")

        let cell = app.staticTexts[seedName].firstMatch  // GameLinkView Text(name)
        XCTAssertTrue(cell.waitForExistence(timeout: 15),
                      "Seeded game '\(seedName)' not found in the list")
        XCTAssertTrue(reveal(cell, in: app, by: { app.swipeUp() }),
                      "Seeded game '\(seedName)' never came on screen in the list")
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
