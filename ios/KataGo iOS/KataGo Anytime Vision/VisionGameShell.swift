//
//  VisionGameShell.swift
//  KataGo Anytime Vision
//

import Foundation
import KataGoUICore

/// Volume-level UI state that lives outside GobanState: the boot/gating
/// phase, controller-help visibility, and the persisted board-orientation
/// preference.
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

    /// Board orientation: false = lying flat on the volume floor (tabletop),
    /// true = standing upright facing the viewer (wall demonstration board).
    /// Persisted across launches.
    var isBoardStanding = UserDefaults.standard.bool(forKey: boardStandingKey) {
        didSet {
            UserDefaults.standard.set(isBoardStanding, forKey: boardStandingKey)
        }
    }
}

private let boardStandingKey = "VisionSettings.boardStanding"
