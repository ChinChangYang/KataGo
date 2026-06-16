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
    /// The 14 `GlobalSettings.*` UserDefaults keys, named exactly as iOS.
    private enum Key {
        static let soundEffect = "GlobalSettings.soundEffect"
        static let hapticFeedback = "GlobalSettings.hapticFeedback"
        static let showVisitsPerSecond = "GlobalSettings.showVisitsPerSecond"
        static let showCoordinate = "GlobalSettings.showCoordinate"
        static let showPass = "GlobalSettings.showPass"
        static let verticalFlip = "GlobalSettings.verticalFlip"
        static let showOwnership = "GlobalSettings.showOwnership"
        static let showWinrateBar = "GlobalSettings.showWinrateBar"
        static let showCharts = "GlobalSettings.showCharts"
        static let showComments = "GlobalSettings.showComments"
        static let stoneStyle = "GlobalSettings.stoneStyle"
        static let moveNumberStyle = "GlobalSettings.moveNumberStyle"
        static let analysisStyle = "GlobalSettings.analysisStyle"
        static let analysisInformation = "GlobalSettings.analysisInformation"
    }

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

        gobanState.soundEffect = (defaults.object(forKey: Key.soundEffect) as? Bool) ?? false
        gobanState.hapticFeedback = (defaults.object(forKey: Key.hapticFeedback) as? Bool) ?? false
        gobanState.showVisitsPerSecond = (defaults.object(forKey: Key.showVisitsPerSecond) as? Bool) ?? false
        gobanState.showCoordinate = (defaults.object(forKey: Key.showCoordinate) as? Bool) ?? Config.defaultShowCoordinate
        gobanState.showPass = (defaults.object(forKey: Key.showPass) as? Bool) ?? Config.defaultShowPass
        gobanState.verticalFlip = (defaults.object(forKey: Key.verticalFlip) as? Bool) ?? Config.compatibleVerticalFlip
        gobanState.showOwnership = (defaults.object(forKey: Key.showOwnership) as? Bool) ?? Config.defaultShowOwnership
        gobanState.showWinrateBar = (defaults.object(forKey: Key.showWinrateBar) as? Bool) ?? Config.defaultShowWinrateBar
        gobanState.showCharts = (defaults.object(forKey: Key.showCharts) as? Bool) ?? Config.defaultShowCharts
        gobanState.showComments = (defaults.object(forKey: Key.showComments) as? Bool) ?? Config.defaultShowComments
        gobanState.stoneStyle = (defaults.object(forKey: Key.stoneStyle) as? Int) ?? Config.defaultStoneStyle
        gobanState.moveNumberStyle = (defaults.object(forKey: Key.moveNumberStyle) as? Int) ?? Config.defaultMoveNumberStyle
        gobanState.analysisStyle = (defaults.object(forKey: Key.analysisStyle) as? Int) ?? Config.defaultAnalysisStyle
        gobanState.analysisInformation = (defaults.object(forKey: Key.analysisInformation) as? Int) ?? Config.defaultAnalysisInformation
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

        defaults.set(gobanState.soundEffect, forKey: Key.soundEffect)
        defaults.set(gobanState.hapticFeedback, forKey: Key.hapticFeedback)
        defaults.set(gobanState.showVisitsPerSecond, forKey: Key.showVisitsPerSecond)
        defaults.set(gobanState.showCoordinate, forKey: Key.showCoordinate)
        defaults.set(gobanState.showPass, forKey: Key.showPass)
        defaults.set(gobanState.verticalFlip, forKey: Key.verticalFlip)
        defaults.set(gobanState.showOwnership, forKey: Key.showOwnership)
        defaults.set(gobanState.showWinrateBar, forKey: Key.showWinrateBar)
        defaults.set(gobanState.showCharts, forKey: Key.showCharts)
        defaults.set(gobanState.showComments, forKey: Key.showComments)
        defaults.set(gobanState.stoneStyle, forKey: Key.stoneStyle)
        defaults.set(gobanState.moveNumberStyle, forKey: Key.moveNumberStyle)
        defaults.set(gobanState.analysisStyle, forKey: Key.analysisStyle)
        defaults.set(gobanState.analysisInformation, forKey: Key.analysisInformation)
    }
}
