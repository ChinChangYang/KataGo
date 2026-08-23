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
