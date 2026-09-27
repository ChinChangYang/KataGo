//
//  PortraitUITestCase.swift
//  KataGo iOSUITests
//
//  Created by Chin-Chang Yang on 2026/8/8.
//

import XCTest

/// Base class for every UI test class that assumes a portrait app.
///
/// **Why this exists.** The simulator remembers its orientation across
/// processes AND across `xcodebuild` invocations. A test that ends while
/// rotated therefore poisons the classes ordered after it — and the FIRST
/// class of the next run, which inherits whatever the previous run left
/// behind. On 2026-08-03 that produced 10 failures across 6 classes, none of
/// them app defects: rows pushed below the fold, controls reported "not
/// hittable", and a sheet measured at its 560 pt landscape cap and reported as
/// a `maxWidth` regression that did not exist. It reproduced under
/// `-only-testing`, which looks like proof of a real regression and is not —
/// the poison is device state, so any run carries it.
///
/// ⚠️ **Measured 2026-08-09 (Xcode 26.6 / iOS 26.5 simulator): that leak no
/// longer reproduces.** A control test rotated to landscape, returned
/// successfully with no restore and no teardown block, and the device read back
/// portrait within two seconds — the simulator resets orientation when the app
/// under test terminates, so a fresh launch always comes up portrait. Do not
/// treat the paragraph above as a live hazard on this toolchain, and do not
/// spend a triage cycle hunting an orientation leak before re-confirming it is
/// even reproducible. This class stays because the 2026-08-03 incident was
/// real, the behaviour is Apple's to change back, and the cost here is one
/// rotation per test.
///
/// **Why a base class rather than a restore in the rotating test.** The
/// rotators do restore inline, and they should. But `continueAfterFailure =
/// false` plus Swift exceptions disabled means any XCTest failure ends in
/// `abort()`, and neither `defer` nor `addTeardownBlock` runs on that path.
/// The only thing that reliably survives a runner `abort()` is *another
/// process* — which is exactly what the next class's `setUp` is. So the
/// durable fix is for each class to state its own precondition instead of
/// trusting upstream cleanup. `BackendConfigSheetUITests` sorts first and was
/// poisoned by a *previous run*, before any rotator in its own run had
/// executed; no inline restore anywhere could ever have protected it.
///
/// ⚠️ `KataGo_iOSUITestsLaunchTests` deliberately does NOT inherit from this
/// class. It sets `runsForEachTargetApplicationUIConfiguration`, so XCTest
/// itself sweeps all four orientations. Apple does not document whether XCTest
/// applies each configuration before or after `setUp`; if it is before, a pin
/// here would clobber it and all four `testLaunch` runs would screenshot
/// portrait — a green test that tests nothing. Do not "tidy up" that class by
/// reparenting it.
class PortraitUITestCase: XCTestCase {

    override func setUpWithError() throws {
        // In UI tests it is usually best to stop immediately on failure. Every
        // class in this target wants this, which is half the reason the base
        // class earns its keep.
        continueAfterFailure = false

        // XCTest runs setUp on the main thread for UI tests, but
        // `setUpWithError()` is declared nonisolated, so the compiler cannot see
        // that and flags every `XCUIDevice.shared` touch. State it once here
        // rather than scatter the warnings.
        MainActor.assumeIsolated {
            // Report the leak before correcting it. Pinning silently would fix
            // the symptom and hide the cause, so the next broken rotator would
            // never be noticed — the strongest objection to blanket pinning,
            // answered here. It stays a `print` and not a failure on purpose:
            // the orientation setter itself can fail, and a failure in
            // `setUpWithError` takes out the whole class rather than one test.
            let inherited = XCUIDevice.shared.orientation
            if inherited != .portrait {
                print("ORIENTATION LEAK — inherited \(inherited.debugName) at the start of " +
                      "\(Self.self); an upstream class or a previous run left the simulator " +
                      "rotated. Pinning portrait and continuing.")
            }

            // Unconditional, deliberately. Do not optimise this into
            // `if inherited != .portrait`: the getter reports the last value
            // *requested* rather than the device's real state, so on a fresh
            // process it can answer `.portrait` for a simulator that is not.
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// The app under test, carrying the launch arguments every UI test needs.
    ///
    /// Use this instead of `XCUIApplication()` directly. Extra arguments are
    /// appended, so a test with its own seam still reads naturally:
    /// `makeApp(stageModelArg)`. A test that genuinely needs a per-model setting
    /// to survive across launches — none does today — can construct
    /// `XCUIApplication()` itself, but then it owns the cleanup problem
    /// described below.
    ///
    /// **Why the baseline exists.** Same reasoning as the portrait pin above,
    /// one axis over. `BackendConfigSheetUITests` must persist a *smaller* Max
    /// Board Size to prove the picker works, and an `abort()` before it can put
    /// the value back leaves the engine launching with a 13x13 NN buffer — at
    /// which point every 19x19 board comes up *Held* ("Board larger than Max
    /// Board Size 13"), which shuts the command gate, so the board never reports
    /// in sync and `waitForBoardInSync` fails; new games are also created at
    /// 13x13, for every class that runs afterwards and every run after that. That state lives in
    /// `UserDefaults`, not on the device, so nothing clears it on its own. The
    /// durable answer is again the next process: each launch states its own
    /// precondition rather than trusting the previous one to have cleaned up.
    ///
    /// ⚠️ **Unlike the orientation hazard above, this one is measured and live**
    /// (2026-08-09, Xcode 26.6 / iOS 26.5). With `mlxBoardSize_default_model.bin.gz`
    /// persisted as 13 and this baseline emptied, `GifExportUITests` — a class
    /// that touches none of these settings — failed on
    /// "Board did not appear (engine never finished launching)", a message that
    /// names the wrong cause entirely. The value also outlives
    /// `simctl uninstall`: the app's defaults plist lives beside the data
    /// container, not inside it, so reinstalling does not clear it.
    @MainActor
    func makeApp(_ extraArguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += Self.baselineLaunchArguments + extraArguments
        return app
    }

    /// Blocks until the board is showing a position the ENGINE has caught up
    /// with, or fails the test.
    ///
    /// Replaces "wait for the `Forward to End` button to exist". That worked
    /// while the board was mounted only after the engine finished loading —
    /// the button's appearance WAS the engine's readiness. The board no longer
    /// waits for the engine, so the button now appears while the model is still
    /// compiling, and any test that then drives the board would be racing the
    /// engine.
    ///
    /// Two conditions, both required:
    ///   * `Board.sync` reads `"inSync"` — the hidden element `BoardView`
    ///     publishes from `Stones.isReady`, i.e. the engine acknowledged the
    ///     position on screen.
    ///   * no `EngineStatus.` element is on screen — the engine is not
    ///     launching, absent, failed, or held back by a too-large board.
    ///
    /// The default timeout matches the old sentinel's: a cold simulator launch
    /// includes an on-the-fly Core ML conversion.
    ///
    /// It proves nothing about what covers the board: `Board.sync` is read
    /// the same behind a sheet. Nor does it prove a new engine: behind the
    /// picker Change model raises it already reads "inSync" for the old
    /// engine (`switchModel` handles that).
    @MainActor
    @discardableResult
    func waitForBoardInSync(_ app: XCUIApplication,
                            timeout: TimeInterval = 360,
                            file: StaticString = #filePath,
                            line: UInt = #line) -> Bool {
        let sentinel = app.otherElements["Board.sync"]
        let inSync = XCTNSPredicateExpectation(
            predicate: NSPredicate { element, _ in
                (element as? XCUIElement)?.value as? String == "inSync"
            },
            object: sentinel)
        guard XCTWaiter().wait(for: [inSync], timeout: timeout) == .completed else {
            XCTFail("Board never reported in sync with the engine "
                    + "(Board.sync = \(String(describing: sentinel.value)))",
                    file: file, line: line)
            return false
        }

        let status = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "EngineStatus."))
        XCTAssertEqual(status.count, 0,
                       "An engine status is still on screen after the board reported in sync",
                       file: file, line: line)
        return true
    }

    // MARK: - Scrolling and sheets

    /// True when `element` is on screen and has stopped moving: it exists, the
    /// midpoint of its frame lies inside the app, and the frame is the same
    /// on every one of `samples` looks 0.1 s apart (two by default).
    ///
    /// `exists` alone lies on iOS 27, where a below-the-fold Form or List cell
    /// is already in the accessibility tree. The second look catches a sheet
    /// that is still sliding up, or a scroll that is still settling.
    ///
    /// Deliberately NOT `isHittable`, which lies both ways: an accessibility
    /// container reported hittable while scrolled off (iOS 26), and a label
    /// inside a control is never hittable, because the hit test lands on the
    /// control around it — the "Thumbnails" picker label read not-hittable
    /// through eight swipes while plainly on screen (2026-09-26). So this says
    /// nothing about whether a sheet COVERS the element; prove a sheet gone
    /// with an element the sheet owns (see `dismissSheet`), and check
    /// `isHittable` yourself where tapping a covered element would do harm.
    ///
    /// Frames come from snapshots, which throw rather than failing the test
    /// when the element has just stopped matching (a row recycled while a
    /// scroll settles, a sheet being torn down); `frame` itself would fail it.
    @MainActor
    func isOnScreen(_ element: XCUIElement, in app: XCUIApplication, samples: Int = 2) -> Bool {
        guard element.exists, let first = try? element.snapshot().frame, !first.isEmpty,
              app.frame.contains(CGPoint(x: first.midX, y: first.midY)) else { return false }
        for _ in 1..<max(samples, 1) {
            usleep(100_000)
            guard let next = try? element.snapshot().frame, next == first else { return false }
        }
        return true
    }

    /// Polls `isOnScreen` until it holds or `timeout` passes.
    @MainActor
    @discardableResult
    func waitForOnScreen(_ element: XCUIElement,
                         in app: XCUIApplication,
                         timeout: TimeInterval,
                         samples: Int = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isOnScreen(element, in: app, samples: samples) && Date() < deadline { usleep(150_000) }
        return isOnScreen(element, in: app, samples: samples)
    }

    /// Scrolls with `swipe` until `element` is on screen, at most `maxSwipes`
    /// times, and returns whether it got there. The caller still asserts.
    ///
    /// The loop is gated on being ON SCREEN, never on `exists`. On iOS 26 an
    /// off-screen cell was missing from the tree, so `while !exists { swipe }`
    /// worked; on iOS 27 the cell is already there, so that loop never swiped
    /// and the next tap or `isHittable` met a row below the fold. The first
    /// wait is longer to cover a sheet that is still being presented; after
    /// each swipe it only has to let the scroll settle.
    @MainActor
    @discardableResult
    func reveal(_ element: XCUIElement,
                in app: XCUIApplication,
                by swipe: () -> Void,
                maxSwipes: Int = 8) -> Bool {
        var swipes = 0
        var settle: TimeInterval = 3
        while !waitForOnScreen(element, in: app, timeout: settle) && swipes < maxSwipes {
            swipe()
            swipes += 1
            settle = 1.5
        }
        return isOnScreen(element, in: app)
    }

    /// Swipes the frontmost sheet down until `sentinel`, an element only that
    /// sheet owns (usually its navigation bar), is gone. Fails the test if it
    /// never goes, or if the sentinel is not there to begin with: a sentinel
    /// that is already missing would report a dismissal that never happened
    /// (the usual cause is a screen pushed inside the sheet, which hides the
    /// root's navigation bar — pop it first).
    ///
    /// It swipes the sheet's CONTENT, not its navigation bar: on iOS 27 a
    /// nav-bar swipe no longer dismisses a sheet whose list has been scrolled.
    /// A content swipe on a scrolled list first scrolls it back to the top,
    /// which is why this loops. Proof of dismissal has to be the sheet's own
    /// element leaving; anything behind the sheet ("More", "Forward to End")
    /// stays in the accessibility tree the whole time the sheet covers it.
    @MainActor
    func dismissSheet(_ app: XCUIApplication,
                      until sentinel: XCUIElement,
                      maxSwipes: Int = 4,
                      file: StaticString = #filePath,
                      line: UInt = #line) {
        XCTAssertTrue(sentinel.waitForExistence(timeout: 5),
                      "The sheet to dismiss is not showing its sentinel",
                      file: file, line: line)
        var swipes = 0
        while sentinel.exists && swipes < maxSwipes {
            app.swipeDown(velocity: .fast)
            swipes += 1
            _ = sentinel.waitForNonExistence(timeout: 3)
        }
        XCTAssertTrue(sentinel.waitForNonExistence(timeout: 5),
                      "The sheet did not dismiss after \(swipes) swipes",
                      file: file, line: line)
    }

    // MARK: - Menus and a quiet board

    /// Taps `element` once it is on screen and has held still for about
    /// 0.3 s, and returns whether it tapped. It never taps an element that
    /// did not settle within `timeout`: a tap on an element that leaves
    /// under it fails the test outright, and an open SwiftUI menu does
    /// exactly that when its host re-renders.
    @MainActor
    @discardableResult
    func tapWhenSteady(_ element: XCUIElement,
                       in app: XCUIApplication,
                       timeout: TimeInterval) -> Bool {
        guard waitForOnScreen(element, in: app, timeout: timeout, samples: 4) else { return false }
        element.tap()
        return true
    }

    /// Turns analysis off with the board's sparkle, then waits for the board
    /// to report in sync, so that nothing the engine does next re-renders
    /// the toolbar under a menu the test is about to open.
    ///
    /// Off, not paused: a paused board still asks for one analysis whenever
    /// the position or the turn changes, and a running sparkle animates.
    /// Off asks for no new analysis. It does not promise a silent engine: an
    /// analysis reply still in flight when Off lands can re-arm continuous
    /// analysis (the waiting-edge handler in `GameSplitView` stops only a
    /// paused board, 2026-09-27 review). That does not reach the menu,
    /// because `PlusMenuView` reads no analysis. The state lives in memory
    /// only; the next launch starts with analysis running again.
    ///
    /// It reads the sparkle's label instead of counting taps, because the
    /// starting state varies: a fresh board runs, and leaving a board for
    /// the Games list pauses it. It taps only from running or paused. With
    /// the engine down a tap opens the model picker instead, and while the
    /// engine loads the sparkle is disabled. A tap dropped while the board
    /// re-renders is tried again.
    @MainActor
    func quietBoard(_ app: XCUIApplication,
                    file: StaticString = #filePath,
                    line: UInt = #line) {
        let sparkle = app.buttons["Toggle Analysis"].firstMatch
        XCTAssertTrue(waitForOnScreen(sparkle, in: app, timeout: 30),
                      "The analysis sparkle is not on screen", file: file, line: line)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let state = sparkle.label
            if state == "Analysis off" || state.hasPrefix("Analysis stopped") { break }
            if state == "Analysis running" || state == "Analysis paused" {
                sparkle.tap()
                let moved = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label != %@", state), object: sparkle)
                _ = XCTWaiter().wait(for: [moved], timeout: 5)
            } else {
                usleep(500_000)
            }
        }
        XCTAssertEqual(sparkle.label, "Analysis off", "Analysis did not turn off",
                       file: file, line: line)
        waitForBoardInSync(app, file: file, line: line)
    }

    /// Opens the toolbar's More menu and walks `path` down to its last item,
    /// until `opened` exists: an element the item's destination owns, such
    /// as its sheet's navigation bar. Fails the test if it never does.
    ///
    /// **Why it loops.** `PlusMenuView` reads the engine's sync and turn
    /// state, so an engine reply that changes them rebuilds the menu, and an
    /// open submenu falls back to its parent or the whole menu closes. A
    /// drill of single taps then taps an item that has just gone (Export GIF
    /// on a fresh install, 2026-07-08). So each pass looks at what is
    /// showing now: it taps the deepest level of `path` that is on screen
    /// and steady, or opens More when no level shows, and so carries on from
    /// wherever a collapse left the menu. Call `quietBoard` first; this
    /// absorbs the collapses that remain, it does not make a busy board safe.
    ///
    /// Items are looked up in collection views only. The open menu is one of
    /// its own, and the board's title is in none (both measured 2026-09-27).
    /// That keeps out the title, a button labelled with the game's name,
    /// usually "New Game": an unscoped "New Game" level would "exist" before
    /// More is ever tapped, and a tap on it renames the game. The scope is
    /// not the menu alone, though: on the Games list the list is a collection
    /// view too, searched before More is open. Its rows read "<name>, <time>",
    /// so no path used today matches one; a new path level must not equal the
    /// label of a row on screen.
    ///
    /// More is tapped only while hittable, so a sheet still sliding away
    /// cannot take the tap: a More tap 1.7 s after a sheet was swiped away
    /// hit nothing ("Computed hit point {-1, -1}") on 2026-09-25.
    ///
    /// A drill that needed more than the minimum number of passes prints a
    /// MENU RETRY line, so a run's log shows how often the loop mattered.
    @MainActor
    func openMoreMenuItem(_ app: XCUIApplication,
                          path: [String],
                          until opened: XCUIElement,
                          attempts: Int = 25,
                          file: StaticString = #filePath,
                          line: UInt = #line) {
        openMoreMenuItem(app, path: path, attempts: attempts, file: file, line: line,
                         until: { opened.exists }, waitingFor: opened)
    }

    /// The same drill, for a destination no single element marks: it stops
    /// once `opened` returns true. `opened` must be false before the drill
    /// starts, or nothing is tapped at all.
    @MainActor
    func openMoreMenuItem(_ app: XCUIApplication,
                          path: [String],
                          attempts: Int = 25,
                          file: StaticString = #filePath,
                          line: UInt = #line,
                          until opened: () -> Bool) {
        openMoreMenuItem(app, path: path, attempts: attempts, file: file, line: line,
                         until: opened, waitingFor: nil)
    }

    @MainActor
    private func openMoreMenuItem(_ app: XCUIApplication,
                                  path: [String],
                                  attempts: Int,
                                  file: StaticString,
                                  line: UInt,
                                  until opened: () -> Bool,
                                  waitingFor sentinel: XCUIElement?) {
        let more = app.buttons["More"].firstMatch
        let items = path.map { app.collectionViews.buttons[$0].firstMatch }
        // The step after the last item: its destination appearing.
        func waitForOpened(_ timeout: TimeInterval) -> Bool {
            if let sentinel { return sentinel.waitForExistence(timeout: timeout) }
            let deadline = Date().addingTimeInterval(timeout)
            while !opened() && Date() < deadline { usleep(200_000) }
            return opened()
        }
        var passes = 0
        var opens = 0
        while !opened() && passes < attempts {
            passes += 1
            if let level = items.indices.last(where: { items[$0].exists }) {
                // A level that is still moving or flickering waits for the
                // next pass.
                guard tapWhenSteady(items[level], in: app, timeout: 2) else { continue }
                if level + 1 < items.count {
                    _ = items[level + 1].waitForExistence(timeout: 3)
                } else {
                    _ = waitForOpened(10)
                }
            } else if waitForOnScreen(more, in: app, timeout: 5), more.isHittable {
                more.tap()
                opens += 1
                if let first = items.first { _ = first.waitForExistence(timeout: 5) }
            } else {
                usleep(500_000)
            }
        }
        let route = (["More"] + path).joined(separator: " ▸ ")
        if passes > path.count + 1 {
            print("MENU RETRY — \(route) took \(passes) passes and opened More \(opens) times")
        }
        XCTAssertTrue(waitForOpened(5),
                      "\(route) did not open after \(passes) passes (More opened \(opens) times)",
                      file: file, line: line)
    }

    // MARK: - The model picker

    /// The catalog title of the network the app bundles.
    static let builtInModelTitle = "Built-in KataGo Network"

    /// Opens `title`'s detail page in the model picker that is showing, or
    /// does nothing when that page is already open. Fails the test if the
    /// picker is not showing: every DEBUG launch presents it
    /// (`RecoveryDecision` checks `isDebug` first), so a missing picker means
    /// a Release build or `--screenshot-seed`.
    ///
    /// It taps the row only once the picker's Done button, which only the
    /// picker's root has, has stopped moving: the sheet slides up at launch,
    /// and a tap during the slide is lost. A lost tap is tried again while
    /// the root still shows. The row is looked up in the picker's list: the
    /// detail page shows the title twice more, and a tap on a query that
    /// matches more than once fails the test. That list leaves the tree once
    /// the detail is pushed (measured 2026-09-27).
    ///
    /// It scrolls only while the row is off screen: up when the row sits
    /// below the middle of the screen (large Dynamic Type pushes it below
    /// the fold), down otherwise (a test that scrolled to the Core ML footer
    /// leaves the list at its bottom, where iOS 27 drops the top rows from
    /// the tree). A swipe down on a list already at its top dismisses the
    /// sheet, which is why it never swipes at a row on screen.
    @MainActor
    func openModelDetail(_ app: XCUIApplication,
                         title: String = builtInModelTitle,
                         file: StaticString = #filePath,
                         line: UInt = #line) {
        let root = app.navigationBars["Select a Model"]
        let detail = app.navigationBars[title]
        if detail.exists { return }
        XCTAssertTrue(root.waitForExistence(timeout: 30),
                      "The model picker is not showing (a DEBUG launch always presents it)",
                      file: file, line: line)
        XCTAssertTrue(waitForOnScreen(app.buttons["ModelPickerView.done"], in: app, timeout: 10),
                      "The model picker never settled on screen", file: file, line: line)
        let row = app.collectionViews.staticTexts[title].firstMatch
        _ = row.waitForExistence(timeout: 5)
        XCTAssertTrue(reveal(row, in: app, by: {
                          if let frame = try? row.snapshot().frame, frame.midY > app.frame.midY {
                              app.swipeUp()
                          } else {
                              app.swipeDown()
                          }
                      }),
                      "Model row '\(title)' never came on screen in the picker",
                      file: file, line: line)
        var taps = 0
        while !detail.exists && root.exists && taps < 3 {
            guard tapWhenSteady(row, in: app, timeout: 5) else { break }
            taps += 1
            _ = detail.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(detail.waitForExistence(timeout: 5),
                      "Tapping '\(title)' did not open its detail page (\(taps) taps)",
                      file: file, line: line)
    }

    /// Picks `title` in the model picker that is showing, taps Play, and
    /// returns once the picker has closed. Works on any picker: the one a
    /// DEBUG launch presents, the one the sparkle opens with the engine
    /// down, and the one Change model raises.
    ///
    /// The picker's close is proved by the picker's own elements leaving:
    /// Play, and every element that shows the model's title (the root's row,
    /// the detail's heading and bar); nothing behind the sheet shows it
    /// (measured 2026-09-27). The board, its sparkle, "More" and `Board.sync`
    /// all sit in the tree behind the sheet from the first frame, so none of
    /// them can prove it closed.
    ///
    /// It does not wait for the engine. Some tests watch the board while the
    /// engine loads, and the photo-import hooks raise a sheet of their own
    /// 600 ms after the picker closes. Call `waitForBoardInSync` next when
    /// the test needs the engine. `whileClosing` runs on every poll from the
    /// Play tap until the picker has gone, for a test that must watch the
    /// board from the moment the engine starts (`switchModel`).
    ///
    /// Play is tapped only in its Play role. The button reads "Download"
    /// until the detail has checked the disk, and for a model that is not on
    /// disk it would download, which UI tests never do. It is tapped again
    /// while the picker stays up, since a tap during the push is lost.
    @MainActor
    func launchModel(_ app: XCUIApplication,
                     title: String = builtInModelTitle,
                     whileClosing: (() -> Void)? = nil,
                     file: StaticString = #filePath,
                     line: UInt = #line) {
        openModelDetail(app, title: title, file: file, line: line)
        let id = "ModelDetailView.downloadPlayButton"
        let play = app.buttons[id]
        let playRole = app.buttons
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", id, "Play")).firstMatch
        guard playRole.waitForExistence(timeout: 15) else {
            let role = (try? play.snapshot().label) ?? "no button"
            XCTFail("'\(title)' offers \(role), not Play: it is not on disk, and UI tests stay offline",
                    file: file, line: line)
            return
        }
        var taps = 0
        while play.exists && taps < 3 {
            guard tapWhenSteady(play, in: app, timeout: 10) else { break }
            taps += 1
            let deadline = Date().addingTimeInterval(10)
            repeat {
                whileClosing?()
                usleep(100_000)
            } while play.exists && Date() < deadline
        }
        if taps > 1 { print("PICKER RETRY — Play on '\(title)' took \(taps) taps") }
        XCTAssertFalse(play.exists, "The model picker did not close after \(taps) Play taps",
                       file: file, line: line)
        XCTAssertTrue(app.staticTexts[title].waitForNonExistence(timeout: 5),
                      "The model picker still shows '\(title)' after Play", file: file, line: line)
    }

    /// Picks `title` in the picker Change model raised over a RUNNING engine
    /// and waits for the replacement engine to report in sync. Fails if the
    /// engine never restarts, or if the board leaves the tree on the way:
    /// the board stays up through a model change.
    ///
    /// `waitForBoardInSync` alone proves nothing here. `Board.sync` already
    /// read "inSync" for the old engine behind the picker, so it passes
    /// before the restart has even begun. A restart shows on the board as
    /// `Board.sync` reading "syncing": stopping the old engine clears the
    /// board's sync within a run-loop turn of the Play tap, and it stays
    /// clear for at least the engine's one-second drain. That window can
    /// close while the sheet is still sliding away on a warm cache, so it is
    /// watched from the tap, with one snapshot per look.
    @MainActor
    func switchModel(_ app: XCUIApplication,
                     to title: String = builtInModelTitle,
                     timeout: TimeInterval = 360,
                     file: StaticString = #filePath,
                     line: UInt = #line) {
        let board = app.otherElements["Board.sync"]
        var restarted = false
        var inSync = false
        var boardLeft = false
        func look() {
            guard let value = (try? board.snapshot())?.value as? String else {
                if !board.exists { boardLeft = true }
                return
            }
            if value == "syncing" { restarted = true }
            inSync = value == "inSync"
        }
        launchModel(app, title: title, whileClosing: look, file: file, line: line)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            look()
            if boardLeft || (restarted && inSync) { break }
            usleep(200_000)
        } while Date() < deadline
        XCTAssertFalse(boardLeft, "The board left the screen during the change to '\(title)'",
                       file: file, line: line)
        XCTAssertTrue(restarted, "The engine never restarted after Play on '\(title)'",
                      file: file, line: line)
        waitForBoardInSync(app, timeout: 5, file: file, line: line)
    }

    // MARK: - The Games list and a fresh game

    /// Pops the board back to the Games list and proves it: the list's own
    /// bar is showing and the board has left the tree (within 0.3 s,
    /// measured 2026-09-27). "More" proves neither, since the board and the
    /// list each have one. On an iPhone the pop also clears the selection,
    /// and leaving a board pauses its analysis (`BoardView.onDisappear`).
    ///
    /// Back is tapped again while the list has not appeared: a tap that
    /// lands while the board re-renders under engine replies is lost.
    @MainActor
    func showGamesList(_ app: XCUIApplication,
                       file: StaticString = #filePath,
                       line: UInt = #line) {
        let games = app.navigationBars["Games"]
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        var taps = 0
        while !games.exists && taps < 3 {
            guard tapWhenSteady(back, in: app, timeout: 10) else { break }
            taps += 1
            _ = games.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(games.waitForExistence(timeout: 5),
                      "The Games list did not appear after Back (\(taps) taps)",
                      file: file, line: line)
        XCTAssertTrue(app.otherElements["Board.sync"].waitForNonExistence(timeout: 10),
                      "The board did not leave after Back", file: file, line: line)
    }

    /// More ▸ New Game ▸ Empty Board, from the Games list, then proves the
    /// new game's board is showing: the list's bar has gone, and the board's
    /// title reads "New Game". Starts only from the list, which
    /// `showGamesList` proves: from a board the new game swaps in place, and
    /// the old board is usually a "New Game" too, so nothing would tell the
    /// two apart. Waiting for the new board's `Board.sync` to appear proves
    /// it is mounted; call `waitForBoardInSync` (or `quietBoard`) when the
    /// test needs the engine to have caught up with the new game.
    @MainActor
    func openEmptyBoard(_ app: XCUIApplication,
                        file: StaticString = #filePath,
                        line: UInt = #line) {
        let games = app.navigationBars["Games"]
        let board = app.otherElements["Board.sync"]
        XCTAssertTrue(games.exists && !board.exists,
                      "An empty board is opened from the Games list; call showGamesList first",
                      file: file, line: line)
        openMoreMenuItem(app, path: ["New Game", "Empty Board"], until: board,
                         file: file, line: line)
        XCTAssertTrue(games.waitForNonExistence(timeout: 10),
                      "The Games list stayed up after Empty Board", file: file, line: line)
        XCTAssertTrue(waitForOnScreen(app.navigationBars.buttons["New Game"], in: app, timeout: 30),
                      "The new game's board did not appear (no 'New Game' title)",
                      file: file, line: line)
    }

    /// Arguments `makeApp()` adds to every launch.
    ///
    /// Spelled as a literal rather than imported from the app target, which is
    /// what every other seam in this target does — a UI test bundle cannot
    /// import the app module it drives.
    ///
    /// `--uitest-disable-downloads` (kept in step with
    /// `DownloadCenter.disableLaunchArgument`) makes the download center
    /// inert. The download center resumes interrupted transfers at launch;
    /// the UI suite is offline by contract — `ModelStagingUITestSupport`
    /// exists precisely so no test has to reach the network — so the center
    /// must never auto-resume here, rather than relying on there happening to
    /// be no partial left on the simulator from an earlier manual run.
    static let baselineLaunchArguments = [
        "--uitest-reset-backend-settings",
        "--uitest-disable-downloads",
    ]
}

private extension UIDeviceOrientation {
    /// `UIDeviceOrientation` is an `Int` enum with no useful description, so a
    /// raw interpolation would log "UIDeviceOrientation(rawValue: 4)" — which
    /// is exactly the kind of thing nobody decodes at triage time.
    var debugName: String {
        switch self {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        case .unknown: return "unknown"
        @unknown default: return "unrecognised(\(rawValue))"
        }
    }
}
