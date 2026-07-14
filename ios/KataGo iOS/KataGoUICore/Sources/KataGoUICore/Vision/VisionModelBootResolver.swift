//
//  VisionModelBootResolver.swift
//  KataGoUICore
//
//  Pure boot-time model resolution for visionOS: the shared
//  RecoveryDecision contract (iOS ModelRunnerView / Mac decideRecovery)
//  mapped onto a target with no picker screen. Every .showPicker outcome
//  — a surviving crash sentinel, a Debug build, or no recorded selection
//  — lands on the built-in net, and an auto-restore whose downloaded
//  file vanished from Documents falls back to the built-in instead of
//  crash-looping the headless engine boot.
//

import Foundation

public enum VisionModelBootResolver {
    public struct Resolution {
        public let model: NeuralNetworkModel
        /// True only when a surviving crash sentinel forced the fallback —
        /// the caller logs the incomplete prior load (no banner, iOS parity).
        public let fellBackFromIncompleteLoad: Bool
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
            return Resolution(
                model: builtIn,
                fellBackFromIncompleteLoad: !pendingLoadModelTitle.isEmpty)
        case .autoRestore(let title):
            guard let match = NeuralNetworkModel.allCases.first(where: { $0.title == title })
            else {
                return Resolution(model: builtIn, fellBackFromIncompleteLoad: false)
            }
            if match.builtIn || isFileDownloaded(match) {
                return Resolution(model: match, fellBackFromIncompleteLoad: false)
            }
            return Resolution(model: builtIn, fellBackFromIncompleteLoad: false)
        }
    }
}
