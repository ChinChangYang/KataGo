//
//  VisionBoardSizeSetting.swift
//  KataGoUICore
//
//  Pure row model for the visionOS model-detail gear view's Max Board Size
//  picker (the iOS BackendConfigSheet analog; Vision's only per-model
//  setting). Choices above the displayed net's nnLen are omitted, never
//  clamp-displayed: effectiveMaxBoardLength = min(choice, nnLen), so an
//  over-cap segment would select something that changes nothing. Apply
//  timing is HYBRID: the ACTIVE model restarts the engine on change (its
//  buffer can't be reloaded any other way — Activate is disabled for it);
//  any other model, and the pre-boot chooser, persist only and apply at
//  activation (iOS semantics).
//

import Foundation

public struct VisionBoardSizeSetting: Equatable, Sendable {
    public let choices: [BoardSizeChoice]
    public let selection: BoardSizeChoice
    public let footerText: String
    /// Only the ACTIVE model's picker gates on the engine: a restart in
    /// flight serves the OLD buffer. Other models never touch the live
    /// engine, so their pickers stay usable while it is down.
    public let pickerDisabled: Bool
    public let restartsEngineOnChange: Bool
    public let showsEngineStatusFooter: Bool

    public static func make(persisted: BoardSizeChoice,
                            nnLen: Int,
                            isActiveModel: Bool,
                            isBootChooser: Bool,
                            engineIsRunning: Bool) -> VisionBoardSizeSetting {
        let choices = BoardSizeChoice.allCases.filter { $0.rawValue <= nnLen }
        let selection = choices.contains(persisted) ? persisted
            : (choices.last ?? persisted)
        // The pre-boot chooser has no live engine to govern, whichever net
        // is displayed.
        let governsLiveEngine = isActiveModel && !isBootChooser
        let base = "Sets the largest board the engine can play and the size "
            + "the performance tuner optimizes for."
        let footerText = governsLiveEngine
            ? base + " Changing it restarts the engine."
            : base + " Takes effect when this net is activated."
        return VisionBoardSizeSetting(choices: choices,
                                      selection: selection,
                                      footerText: footerText,
                                      pickerDisabled: governsLiveEngine && !engineIsRunning,
                                      restartsEngineOnChange: governsLiveEngine,
                                      showsEngineStatusFooter: governsLiveEngine)
    }
}
