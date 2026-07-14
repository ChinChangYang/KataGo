//
//  VisionBranchConfirm.swift
//  KataGoUICore
//
//  Pure content mapping for the visionOS branch glass cards — the chooser
//  and the destructive confirm step of the Replace/Discard-branch flow,
//  with iOS GameSplitView's confirmation-dialog strings verbatim. The
//  whole flow renders as front-anchored ornament cards, NEVER as
//  .confirmationDialog: a button-tap dismissal of an ornament-hosted
//  dialog that re-renders another ornament blanks the volumetric window's
//  render tree on visionOS 26 (verified live twice — with a chained
//  second dialog AND with a plain state flip; the app keeps running under
//  a permanently empty volume). Cards driven by the shared confirm flags
//  have no presentation machinery to race.
//

import Foundation

public struct VisionBranchConfirm: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case replace
        case discard
    }

    /// The chooser card's title — iOS GameSplitView's first dialog, verbatim.
    public static let chooserTitle =
        "Branch moves are temporary. Replace the original game with this branch, or discard it?"

    public let kind: Kind
    public let title: String
    public let confirmLabel: String

    public static func make(kind: Kind) -> VisionBranchConfirm {
        switch kind {
        case .replace:
            return VisionBranchConfirm(
                kind: .replace,
                title: "Replace the original game with this branch? The original game’s moves after this point will be permanently lost.",
                confirmLabel: "Replace")
        case .discard:
            return VisionBranchConfirm(
                kind: .discard,
                title: "Discard this branch? Your newly played stones will be lost.",
                confirmLabel: "Discard Branch")
        }
    }
}
