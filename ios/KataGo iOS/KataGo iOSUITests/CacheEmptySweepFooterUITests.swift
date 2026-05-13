//
//  CacheEmptySweepFooterUITests.swift
//  KataGo iOSUITests
//
//  Verifies the launch-time cache-empty sweep precompiles both the
//  built-in network and the bundled human SL aux. After clearing the
//  cache from inside the app, terminating, and relaunching, the
//  footer's `.task` reads fresh stats and should eventually show:
//
//      Main:     1 of 4 · …
//      Human SL: 1 of 4 · …
//
//  Footer staleness: `CoreMLCacheFooterView.refresh()` only runs from
//  `.task` at view-appearance — it does NOT observe live cache events.
//  The test therefore terminates + relaunches the app between checks
//  so the footer's first read on each launch reflects the latest
//  on-disk cache state. Each terminate that lands during a compile
//  also kills that in-flight worker; the cache write protocol is
//  atomic, so killed compiles leave no committed entry and are
//  retried on the next launch's sweep.
//

import XCTest

final class CacheEmptySweepFooterUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchSweepPopulatesBuiltInAndAux() throws {
        let app = XCUIApplication()
        app.launch()

        // ----- Step 1: clear the cache from inside the running app ------
        // The footer's "Clear Cache" button is only present when
        // totalCount > 0. If the cache is already empty, skip.
        let clearButton = app.buttons["Clear Cache"]
        let mainFooter  = app.staticTexts["CoreMLCache.footerMainStats"]
        let auxFooter   = app.staticTexts["CoreMLCache.footerAuxStats"]
        XCTAssertTrue(mainFooter.waitForExistence(timeout: 30),
                      "Main-pool footer line never appeared")
        if clearButton.waitForExistence(timeout: 10) {
            clearButton.tap()
            let confirmClear = app.buttons["Clear"]
            XCTAssertTrue(confirmClear.waitForExistence(timeout: 10),
                          "Clear-Cache confirmation dialog did not appear")
            confirmClear.tap()
            let clearGone = NSPredicate(format: "exists == false")
            expectation(for: clearGone, evaluatedWith: clearButton)
            waitForExpectations(timeout: 30)
        }

        // Terminate to kill any in-flight compile triggered by clear()'s
        // own scheduleBuiltIn(). The atomic cache-commit protocol
        // guarantees no partial entry survives the kill.
        app.terminate()

        // ----- Step 2: poll terminate+launch cycles until the cache
        // has both entries and the footer reflects them. Per-cycle
        // sleep gives the launch-time sweep time to commit one compile
        // before the next terminate. Empirically a single isolated
        // compile in this simulator is ~80–120s, but two compiles
        // running concurrently under CPU contention can take 5+ min,
        // so cycle the launches: the first cycle typically finishes
        // the aux, the second finishes the built-in. ----------------
        let perCycleSleep: TimeInterval = 180   // generous per-compile window
        let maxCycles = 6                       // total budget ≈ 18 minutes
        var lastMainLabel = ""
        var lastAuxLabel  = ""
        var bothReady = false
        for cycle in 1...maxCycles {
            app.launch()
            XCTAssertTrue(mainFooter.waitForExistence(timeout: 30),
                          "Picker did not appear on cycle \(cycle) relaunch")
            // Sleep with the app foregrounded so background compiles
            // run; .utility priority on the cooperative pool is what
            // executes Core ML conversions here.
            Thread.sleep(forTimeInterval: perCycleSleep)

            // Probe the footer by terminating + relaunching: the next
            // launch's .task will re-read CoreMLModelCache.statsByCategory()
            // and reflect whatever was committed during the sleep.
            app.terminate()
            app.launch()
            XCTAssertTrue(mainFooter.waitForExistence(timeout: 30),
                          "Picker did not appear on cycle \(cycle) probe relaunch")
            XCTAssertTrue(auxFooter.waitForExistence(timeout: 30),
                          "Aux-pool footer not present on cycle \(cycle)")
            // Give the footer's .task one tick to refresh() before reading.
            Thread.sleep(forTimeInterval: 3)
            lastMainLabel = mainFooter.label
            lastAuxLabel  = auxFooter.label
            let mainCount = parseCount(lastMainLabel)
            let auxCount  = parseCount(lastAuxLabel)
            if mainCount >= 1 && auxCount >= 1 {
                bothReady = true
                break
            }
            // Not done yet: terminate before the next cycle's launch
            // so we get a fresh sweep firing.
            app.terminate()
        }

        XCTAssertTrue(bothReady,
                      "Sweep did not populate both pools within \(maxCycles) cycles. "
                      + "Last seen — Main: '\(lastMainLabel)'; Aux: '\(lastAuxLabel)'")
        // Tight assertion: count must be exactly 1 — the sweep should
        // warm only the built-in + aux, nothing else.
        XCTAssertEqual(parseCount(lastMainLabel), 1,
                       "Expected Main: 1 of 4; footer was '\(lastMainLabel)'")
        XCTAssertEqual(parseCount(lastAuxLabel), 1,
                       "Expected Human SL: 1 of 4; footer was '\(lastAuxLabel)'")
    }

    /// Parses the "<Label>: N of M" fragment from a footer line.
    /// Mirrors the helper in CoreMLCacheFooterUITests.
    private func parseCount(_ label: String) -> Int {
        guard let range = label.range(of: #":\s*(\d+)\s+of\s+\d+"#,
                                       options: .regularExpression) else {
            return -1
        }
        let match = String(label[range])
        let digits = match.drop { !$0.isNumber }
                          .prefix { $0.isNumber }
        return Int(digits) ?? -1
    }
}
