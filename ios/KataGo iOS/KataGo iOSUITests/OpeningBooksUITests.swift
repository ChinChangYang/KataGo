//
//  OpeningBooksUITests.swift
//  KataGo iOSUITests
//
//  One navigation, one assertion: the Opening Books screen mounts.
//
//  **Why that is worth a test.** `reconcileActiveBook` — the reconcile that
//  runs after an import, a delete, or an active-book choice — shipped DEAD for
//  months. The screen hangs off `ModelPickerView`, presented as a sheet from
//  `ModelRunnerView`, which sits above every `.environment` injection
//  `ContentView` makes into the board tree; the values were never handed
//  across, `@Environment` answered nil, and every call returned at its first
//  guard. Nothing failed, nothing logged, and six unit tests over the
//  function's logic would have stayed green throughout — they pass their
//  arguments in directly, so they say nothing about the wiring.
//
//  Since `414f35dd8` the three values (`BookLookup`, `GobanState`,
//  `BoardSize`) are read NON-optionally, which turns a missing injection into
//  a trap at view-update time rather than a silent no-op. This test is what
//  collects on that: SwiftUI resolves every declared `@Environment` property
//  when it updates the view's dynamic-property buffer, so merely ARRIVING at
//  the screen is the assertion. No book, no import and no engine are needed —
//  which is why this stays offline and fast.
//
//  Mutation-proven 2026-08-25: with `.environment(session.bookLookup)` removed
//  from `ModelRunnerView`, the app dies on arrival here (`_assertionFailure`
//  → `EnvironmentValues.subscript.getter` ← `EnvironmentBox.update(property:phase:)`).
//
//  Scope note: `OpeningBookTrashButton` and `ImportedBookDetailView` read the
//  same three values and are children of this screen, so a broken chain fails
//  here first. Neither is mounted by this test — the trash button needs a
//  downloaded book and the detail view an imported one, and this target is
//  offline by contract.
//

import XCTest

final class OpeningBooksUITests: PortraitUITestCase {

    @MainActor
    func testOpeningBooksScreenMountsWithItsEnvironment() throws {
        let app = makeApp()
        app.launch()

        // Debug launches present "Select a Model" as a sheet over the board,
        // so the picker is already up. The Opening Books row sits below the
        // model catalog and the Custom Networks section, and SwiftUI's List is
        // lazy — an unrealized row is not in the accessibility tree at all, so
        // scroll for it rather than waiting for it.
        let link = app.buttons["ModelPickerView.openingBooksLink"].firstMatch
        var swipes = 0
        while !link.exists && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(link.waitForExistence(timeout: 10),
                      "The Opening Books row was never realized in the model picker")
        link.tap()

        // The assertion. If any of the three environment values did not reach
        // this screen, the app is already gone by the time this runs.
        XCTAssertTrue(app.navigationBars["Opening Books"].waitForExistence(timeout: 15),
                      "The Opening Books screen did not appear. If the app terminated, the "
                      + "model-picker sheet stopped injecting BookLookup / GobanState / "
                      + "BoardSize and the non-optional @Environment reads trapped.")
        XCTAssertTrue(app.buttons["OpeningBookPickerView.importButton"].waitForExistence(timeout: 10),
                      "The Opening Books screen mounted without its Import Book row")
        XCTAssertEqual(app.state, .runningForeground,
                       "The app is not in the foreground after opening Opening Books")
    }
}
