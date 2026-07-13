//
//  VisionGameShell.swift
//  KataGo Anytime Vision
//

import Foundation
import KataGoUICore

/// Volume-level UI state that lives outside GobanState: the boot/gating
/// phase, card visibility (controller help, settings, game list), and the
/// persisted Vision-local preferences (board orientation, analysis label
/// mode, ownership overlay).
@Observable
@MainActor
final class VisionGameShell {
    enum Phase: Equatable {
        case booting
        case ready
        /// The selected game's board has no bundled 3D asset (rectangular or
        /// non-9/13/19). The game is never loaded into the engine — the
        /// ornament's New Game menu is the exit.
        case unsupportedBoard(width: Int, height: Int)
    }

    var phase: Phase = .booting

    /// Controller-mapping legend card visibility. Auto-shown once when a
    /// controller first connects; toggled from the ornament afterward.
    var showingControllerHelp = false
    var hasAutoShownControllerHelp = false

    /// Left-side game-list ornament visibility, toggled from the control
    /// bar's Games button.
    var showingGameList = false

    /// Settings card visibility. Settings and the controller legend share
    /// the right-side anchor, so opening either one closes the other — use
    /// the toggle helpers, never the flags directly, from the bar buttons.
    var showingSettings = false

    func toggleSettings() {
        showingSettings.toggle()
        if showingSettings {
            showingControllerHelp = false
        }
    }

    func toggleControllerHelp() {
        showingControllerHelp.toggle()
        if showingControllerHelp {
            showingSettings = false
        }
    }

    /// Board orientation: false = lying flat on the volume floor (tabletop),
    /// true = standing upright facing the viewer (wall demonstration board).
    /// Persisted across launches.
    var isBoardStanding = UserDefaults.standard.bool(forKey: boardStandingKey) {
        didSet {
            UserDefaults.standard.set(isBoardStanding, forKey: boardStandingKey)
        }
    }

    /// "Analysis information" label mode — an index into
    /// Config.analysisInformations. Vision deliberately defaults to
    /// Winrate (0), not the iOS default All, preserving the shipped
    /// minimal marker look. Persisted across launches.
    var analysisInformation =
        UserDefaults.standard.object(forKey: analysisInformationKey) as? Int ?? 0 {
        didSet {
            UserDefaults.standard.set(analysisInformation, forKey: analysisInformationKey)
        }
    }

    /// Ownership overlay visibility, default on (iOS parity). Read via
    /// object(forKey:) — bool(forKey:) would turn "never set" into false.
    var showOwnership =
        UserDefaults.standard.object(forKey: showOwnershipKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showOwnership, forKey: showOwnershipKey)
        }
    }
}

private let boardStandingKey = "VisionSettings.boardStanding"
private let analysisInformationKey = "VisionSettings.analysisInformation"
private let showOwnershipKey = "VisionSettings.showOwnership"
