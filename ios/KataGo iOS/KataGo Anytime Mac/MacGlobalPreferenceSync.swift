import Foundation
import KataGoUICore

/// AppKit equivalent of the iOS `GlobalPreferenceSync` SwiftUI ViewModifier
/// (`GameSplitView.swift`). It two-way binds the 14 app-wide
/// `GlobalSettings.*` `UserDefaults` keys with the shared `GobanState`:
///
///   1. On `init`, the persisted values SEED `GobanState` (so the board renders
///      with the user's saved display preferences instead of compiled defaults).
///   2. Thereafter, every change to one of the 14 observed `GobanState`
///      properties is written BACK to `UserDefaults` (so future menu toggles —
///      T3/T7 — mutate `GobanState` and persist automatically).
///
/// Not a SwiftUI view, so it uses `UserDefaults.standard` directly rather than
/// `@AppStorage`, and bridges observation via the same self-rescheduling
/// `withObservationTracking` pattern `MainWindowController` (T1) uses.
///
/// `MainWindowController` owns this object, which holds a reference to the
/// session-owned `GobanState`. The observation closure captures `self` weakly to
/// avoid a controller→sync→(closure→self) retain cycle.
@MainActor
final class MacGlobalPreferenceSync {
    private let gobanState: GobanState

    init(gobanState: GobanState) {
        self.gobanState = gobanState

        // 1. SEED first, then start observing for write-back.
        seedFromDefaults()
        trackPreferences()
    }

    // MARK: - Seed (UserDefaults -> GobanState)

    /// Reads each persisted value via `object(forKey:)` so a genuinely-persisted
    /// `false` is distinguished from an absent key (a plain `bool(forKey:)`
    /// returns `false` for both, which would let a `true` default clobber a real
    /// `false`). Absent keys fall back to the matching `Config.default*`
    /// constant — these are the exact defaults the iOS `@AppStorage` declarations
    /// use, NOT naive literals (e.g. `showComments` defaults to `false`).
    private func seedFromDefaults() {
        let defaults = UserDefaults.standard

        gobanState.soundEffect = (defaults.object(forKey: GlobalSettingsKeys.soundEffect) as? Bool) ?? false
        gobanState.hapticFeedback = (defaults.object(forKey: GlobalSettingsKeys.hapticFeedback) as? Bool) ?? false
        gobanState.showVisitsPerSecond = (defaults.object(forKey: GlobalSettingsKeys.showVisitsPerSecond) as? Bool) ?? false
        gobanState.showCoordinate = (defaults.object(forKey: GlobalSettingsKeys.showCoordinate) as? Bool) ?? Config.defaultShowCoordinate
        gobanState.showPass = (defaults.object(forKey: GlobalSettingsKeys.showPass) as? Bool) ?? Config.defaultShowPass
        gobanState.verticalFlip = (defaults.object(forKey: GlobalSettingsKeys.verticalFlip) as? Bool) ?? Config.compatibleVerticalFlip
        gobanState.showOwnership = (defaults.object(forKey: GlobalSettingsKeys.showOwnership) as? Bool) ?? Config.defaultShowOwnership
        gobanState.showWinrateBar = (defaults.object(forKey: GlobalSettingsKeys.showWinrateBar) as? Bool) ?? Config.defaultShowWinrateBar
        gobanState.showCharts = (defaults.object(forKey: GlobalSettingsKeys.showCharts) as? Bool) ?? Config.defaultShowCharts
        gobanState.showComments = (defaults.object(forKey: GlobalSettingsKeys.showComments) as? Bool) ?? Config.defaultShowComments
        gobanState.stoneStyle = (defaults.object(forKey: GlobalSettingsKeys.stoneStyle) as? Int) ?? Config.defaultStoneStyle
        gobanState.moveNumberStyle = (defaults.object(forKey: GlobalSettingsKeys.moveNumberStyle) as? Int) ?? Config.defaultMoveNumberStyle
        gobanState.analysisStyle = (defaults.object(forKey: GlobalSettingsKeys.analysisStyle) as? Int) ?? Config.defaultAnalysisStyle
        gobanState.analysisInformation = (defaults.object(forKey: GlobalSettingsKeys.analysisInformation) as? Int) ?? Config.defaultAnalysisInformation
    }

    // MARK: - Write-back (GobanState -> UserDefaults)
    //
    // Mirrors the iOS modifier's 14 `.onChange` handlers via the same
    // self-rescheduling `withObservationTracking` bridge T1 uses: the apply
    // closure touches all 14 properties (so a change to ANY of them fires
    // `onChange`), and `onChange` — which runs before the mutation commits and is
    // one-shot — hops to `Task { @MainActor }` to read the committed values,
    // writes them all back, then re-arms tracking. Writing all 14 each time is
    // idempotent and cheap, so there's no need to diff which one changed.
    //
    // Writing to `UserDefaults` does NOT mutate `GobanState`, so there is no
    // feedback loop (the write-back can't re-trigger its own observation).

    /// One observation pass: track all 14 properties, and on change persist the
    /// current values then re-register (tracking is one-shot).
    private func trackPreferences() {
        withObservationTracking {
            // Touch all 14 tracked properties so a change to any fires `onChange`.
            _ = gobanState.soundEffect
            _ = gobanState.hapticFeedback
            _ = gobanState.showVisitsPerSecond
            _ = gobanState.showCoordinate
            _ = gobanState.showPass
            _ = gobanState.verticalFlip
            _ = gobanState.showOwnership
            _ = gobanState.showWinrateBar
            _ = gobanState.showCharts
            _ = gobanState.showComments
            _ = gobanState.stoneStyle
            _ = gobanState.moveNumberStyle
            _ = gobanState.analysisStyle
            _ = gobanState.analysisInformation
        } onChange: { [weak self] in
            // `onChange` runs before the mutation commits; defer to read the new
            // values, persist them, then re-register (one-shot tracking).
            Task { @MainActor in
                guard let self else { return }
                self.persistToDefaults()
                self.trackPreferences()
            }
        }
    }

    /// Writes all 14 live `GobanState` values back to `UserDefaults.standard`.
    private func persistToDefaults() {
        let defaults = UserDefaults.standard

        defaults.set(gobanState.soundEffect, forKey: GlobalSettingsKeys.soundEffect)
        defaults.set(gobanState.hapticFeedback, forKey: GlobalSettingsKeys.hapticFeedback)
        defaults.set(gobanState.showVisitsPerSecond, forKey: GlobalSettingsKeys.showVisitsPerSecond)
        defaults.set(gobanState.showCoordinate, forKey: GlobalSettingsKeys.showCoordinate)
        defaults.set(gobanState.showPass, forKey: GlobalSettingsKeys.showPass)
        defaults.set(gobanState.verticalFlip, forKey: GlobalSettingsKeys.verticalFlip)
        defaults.set(gobanState.showOwnership, forKey: GlobalSettingsKeys.showOwnership)
        defaults.set(gobanState.showWinrateBar, forKey: GlobalSettingsKeys.showWinrateBar)
        defaults.set(gobanState.showCharts, forKey: GlobalSettingsKeys.showCharts)
        defaults.set(gobanState.showComments, forKey: GlobalSettingsKeys.showComments)
        defaults.set(gobanState.stoneStyle, forKey: GlobalSettingsKeys.stoneStyle)
        defaults.set(gobanState.moveNumberStyle, forKey: GlobalSettingsKeys.moveNumberStyle)
        defaults.set(gobanState.analysisStyle, forKey: GlobalSettingsKeys.analysisStyle)
        defaults.set(gobanState.analysisInformation, forKey: GlobalSettingsKeys.analysisInformation)
    }
}
