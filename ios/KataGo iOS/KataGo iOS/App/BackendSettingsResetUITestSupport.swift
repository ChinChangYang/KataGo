//
//  BackendSettingsResetUITestSupport.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2026/8/9.
//
//  DEBUG-only test support: clears the per-model Backend Settings so a UI test
//  launch starts from factory defaults. Runs only when its launch argument is
//  present, is idempotent, and is compiled out of Release.
//

#if DEBUG
import Foundation
import KataGoUICore

/// Clears every persisted per-model Backend Setting so the app comes up on its
/// factory defaults.
///
/// **Why this exists: a UI test that changes a model setting can poison every
/// launch that follows it, permanently.** `BackendSettings` writes to
/// `UserDefaults.standard`, which outlives the app process, the test class and
/// the whole run. `BackendConfigSheetUITests` has to select a *smaller* Max
/// Board Size to prove the picker persists — and this target runs with
/// `continueAfterFailure = false` and Swift exceptions disabled, so a failed
/// assertion ends in `abort()`, where neither `defer` nor `addTeardownBlock`
/// runs. Restoring the value as the test's last statement therefore cannot
/// help: the abort is precisely what skips the restore.
///
/// What gets left behind is not cosmetic. A stored `mlxBoardSize` of 13 becomes
/// the engine's NN-buffer size (`ModelRunnerView` → `maxBoardSizeForNNBuffer`),
/// and from then on `GobanView` replaces every 19x19 board with the "Too large
/// board size" placeholder — no board, no analysis, no toolbar — while
/// `PlusMenuView` starts creating 13x13 games and the board-size steppers clamp
/// to 13. Every later class in that run sees it, every later run inherits it,
/// and nothing in the app ever heals it.
///
/// **The heal belongs at launch, because the only thing that reliably survives
/// an `abort()` is the next process.** Every UI test passes this argument (see
/// `PortraitUITestCase.makeApp()`), so each launch starts from a known state no
/// matter how the previous one died — including a launch that runs a single
/// downstream class under `-only-testing` after a poisoned run.
///
/// Removing the keys, rather than writing back 19 / "CoreML/NE" / 2, is the
/// correct reset: each getter's absent-value branch already returns the
/// intended default, so there is exactly one definition of "default" and this
/// seam cannot drift from it.
enum BackendSettingsResetUITestSupport {

    /// Pass in `XCUIApplication.launchArguments` to start from factory
    /// per-model settings.
    static let launchArg = "--uitest-reset-backend-settings"

    /// Removes every persisted Backend Settings key, for every model the user
    /// could select.
    ///
    /// Call from `init()`, before any view body runs: `BackendConfigSheet`
    /// seeds its picker state from these values inside its own initializer, and
    /// `ModelRunnerView` reads them as it starts the engine — so clearing them
    /// any later would race the state under test.
    static func resetIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains(launchArg) else { return }

        let defaults = UserDefaults.standard
        // `allAvailable`, not `allCases`: a user-imported network keys its
        // settings off a uuid file name, so the fixed catalog alone would leave
        // an imported net holding whatever an earlier run wrote.
        let models = NeuralNetworkModel.allAvailable
        var cleared = 0
        for model in models {
            for key in BackendSettings.persistedKeys(forFileName: model.fileName)
            where defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
                cleared += 1
            }
        }

        // Deliberately loud, in the style of the other seams. If this ever
        // stops clearing anything — a renamed key, a catalog the app can no
        // longer enumerate at init() — the "defaults to 19x19" assertion
        // quietly goes back to being a bet on what the previous run left, which
        // is the exact failure this seam exists to end.
        print("UITEST BACKEND RESET — cleared \(cleared) key(s) across \(models.count) model(s)")
    }
}
#endif
