//
//  VisionModelBootResolver.swift
//  KataGoUICore
//
//  Pure boot-time model resolution for visionOS: the shared
//  RecoveryDecision contract (iOS ModelRunnerView / Mac decideRecovery)
//  mapped onto ornament-based UI. A surviving load sentinel — the prior
//  run died between arming the launch and the engine's first GTP reply —
//  resolves to .chooseModel: NO engine boots and the Models card
//  presents as a neutral chooser, the iOS picker design (auto-restoring
//  a net whose load just crashed would loop the crash). Clean paths boot
//  headlessly: Debug and empty selections boot the built-in, and an
//  auto-restore whose downloaded file vanished from Documents falls back
//  to the built-in instead of crashing the headless engine boot.
//

import Foundation

public enum VisionModelBootResolver {
    public enum Resolution {
        /// Spawn the engine on this net immediately (normal headless boot).
        case boot(NeuralNetworkModel)
        /// Present the Models card and boot nothing until the user picks.
        case chooseModel
    }

    public static func resolve(pendingLoadModelTitle: String,
                               selectedModelTitle: String,
                               isDebug: Bool,
                               isFileDownloaded: (NeuralNetworkModel) -> Bool) -> Resolution {
        let builtIn = NeuralNetworkModel.builtInModel ?? NeuralNetworkModel.allCases[0]
        switch RecoveryDecision.decide(pendingLoadModelTitle: pendingLoadModelTitle,
                                       selectedModelTitle: selectedModelTitle,
                                       isDebug: isDebug) {
        case .showPicker:
            // RecoveryDecision checks the sentinel before the Debug clause,
            // so a surviving sentinel means the chooser even in Debug; a
            // clean Debug/empty-selection boot stays headless on the
            // built-in (Mac parity — and the sim QA tooling boots to the
            // board).
            if !pendingLoadModelTitle.isEmpty {
                return .chooseModel
            }
            return .boot(builtIn)
        case .autoRestore(let title):
            guard let match = NeuralNetworkModel.allCases.first(where: { $0.title == title })
            else {
                return .boot(builtIn)
            }
            if match.builtIn || isFileDownloaded(match) {
                return .boot(match)
            }
            return .boot(builtIn)
        }
    }
}
