//
//  VisionGameShell.swift
//  KataGo Anytime Vision
//

import Foundation
import KataGoUICore

/// Volume-level UI state that lives outside GobanState: the boot/gating
/// phase and the ornament's pass-confirmation flow.
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

    /// Set by controller Y or the ornament Pass button; the ornament swaps to
    /// an inline Confirm/Cancel row while pending.
    var passConfirmationPending = false
}
