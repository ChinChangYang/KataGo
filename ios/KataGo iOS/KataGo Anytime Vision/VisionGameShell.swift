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
        /// A surviving load sentinel: no engine runs; the Models card
        /// presents front-center as a neutral chooser (iOS picker design)
        /// and the pick boots the engine.
        case choosingModel
        case ready
        /// The selected game's board is outside the renderable 2...37 range.
        /// The game is never loaded into the engine — the ornament's New
        /// Game menu is the exit.
        case unsupportedBoard(width: Int, height: Int)
        /// The board renders fine but exceeds the launched NN buffer — the
        /// engine would fatally abort on its first analysis. The exit is
        /// raising Max Board Size behind the model detail's gear (Settings ▸
        /// Neural Net), which restarts the engine and re-mounts this game.
        case boardTooLarge(width: Int, height: Int)
    }

    var phase: Phase = .booting

    /// Controller-mapping legend card visibility. Auto-shown once when a
    /// controller first connects; toggled from the ornament afterward.
    var showingControllerHelp = false
    var hasAutoShownControllerHelp = false

    /// Left-side game-list ornament visibility, toggled from the control
    /// bar's Games button.
    var showingGameList = false

    /// Settings, the controller legend, the custom New Game panel, the
    /// Models card, and the Licenses card share the right-side anchor, so
    /// opening any one closes the others — use the toggle helpers, never
    /// the flags directly, from the bar buttons.
    var showingSettings = false
    var showingNewGamePanel = false
    var showingModels = false
    var showingLicenses = false

    func toggleSettings() {
        showingSettings.toggle()
        if showingSettings {
            showingControllerHelp = false
            showingNewGamePanel = false
            showingModels = false
            showingLicenses = false
        }
    }

    func toggleControllerHelp() {
        showingControllerHelp.toggle()
        if showingControllerHelp {
            showingSettings = false
            showingNewGamePanel = false
            showingModels = false
            showingLicenses = false
        }
    }

    func toggleNewGamePanel() {
        showingNewGamePanel.toggle()
        if showingNewGamePanel {
            showingSettings = false
            showingControllerHelp = false
            showingModels = false
            showingLicenses = false
        }
    }

    /// The first-controller auto-show path (not a toggle).
    func presentControllerHelp() {
        showingControllerHelp = true
        showingSettings = false
        showingNewGamePanel = false
        showingModels = false
        showingLicenses = false
    }

    /// Settings' "Neural Net" row opens the Models card in the same slot.
    func presentModels() {
        showingModels = true
        showingSettings = false
        showingControllerHelp = false
        showingNewGamePanel = false
        showingLicenses = false
    }

    /// Settings' "Open-Source Licenses" row opens the Licenses card in the
    /// same slot (EULA parity: every platform lists its third-party
    /// licenses under Settings).
    func presentLicenses() {
        showingLicenses = true
        showingSettings = false
        showingControllerHelp = false
        showingNewGamePanel = false
        showingModels = false
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

/// The fixed-scale volume dimensions (~1360 pt/m), shared by the window
/// frame and the scene model's standing-orientation math. Sized so a 37x37
/// board at native pitch fits both orientations: the tabletop slab spans
/// 0.82 x 0.88 m within the 0.9 m floor, and the standing board's 0.88 m
/// height sits centered inside the 0.95 m volume.
enum VisionVolumeMetrics {
    static let widthMeters: Float = 0.9
    static let heightMeters: Float = 0.95
    static let depthMeters: Float = 0.9
    static let pointsPerMeter: CGFloat = 1360
    static var widthPoints: CGFloat { CGFloat(widthMeters) * pointsPerMeter }    // 1224
    static var heightPoints: CGFloat { CGFloat(heightMeters) * pointsPerMeter }  // 1292
    static var depthPoints: CGFloat { CGFloat(depthMeters) * pointsPerMeter }    // 1224
}
