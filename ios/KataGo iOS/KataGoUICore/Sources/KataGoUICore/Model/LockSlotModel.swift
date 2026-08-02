//
//  LockSlotModel.swift
//  KataGoUICore
//
//  Pure state mapping behind the shared lock slot — exact iOS
//  `TopToolbarView` parity, reused by the visionOS bottom bar and the macOS
//  toolbar. Off-branch the slot is the Lock/Unlock toggle (lock / lock.open);
//  while a branch is active it becomes the red "Deactivate Branch" u-turn
//  button, disabled whenever the engine owes a genmove. Editing must never
//  toggle while a branch is active (a branch only forms while
//  isEditing == false), which is why the two states share one slot instead of
//  coexisting.
//
//  `isEditing == true` means UNLOCKED (edits land directly in the saved
//  record); locked routes off-mainline moves into a branch instead. The icon
//  and label both describe that CURRENT state, matching iOS — an open padlock
//  reads "this game is unlocked". Callers that also surface a next-action
//  string (the macOS toolTip) compute it themselves.
//

import Foundation

public struct LockSlotModel: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Toggle `GobanState.isEditing`.
        case toggleLock
        /// Raise `GobanState.confirmingBranchDeactivation`.
        case deactivateBranch
    }

    public let kind: Kind
    public let systemImage: String
    public let label: String
    public let isRed: Bool
    public let isDisabled: Bool

    /// - Parameter isAutoPlaying: mirrors iOS's `.disabled(gobanState.isAutoPlaying)`
    ///   on the lock toggle — flipping `isEditing` mid-replay would let the
    ///   auto-play observer's `isEditing` branch cancel the run underneath it.
    ///   Defaults to `false` for platforms with no auto-play UI (visionOS), so
    ///   they keep the always-enabled toggle they had before this parameter
    ///   existed. The branch state ignores it: exiting a branch stays available
    ///   regardless, gated only on `shouldGenMove`.
    public static func make(isBranchActive: Bool,
                            isEditing: Bool,
                            shouldGenMove: Bool,
                            isAutoPlaying: Bool = false) -> LockSlotModel {
        if isBranchActive {
            return LockSlotModel(kind: .deactivateBranch,
                                 systemImage: "arrow.uturn.backward.circle",
                                 label: "Deactivate Branch",
                                 isRed: true,
                                 isDisabled: shouldGenMove)
        }
        return LockSlotModel(kind: .toggleLock,
                             systemImage: isEditing ? "lock.open" : "lock",
                             label: isEditing ? "Unlock" : "Lock",
                             isRed: false,
                             isDisabled: isAutoPlaying)
    }
}
