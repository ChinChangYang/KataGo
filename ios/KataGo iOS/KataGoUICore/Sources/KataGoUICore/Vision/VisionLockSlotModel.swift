//
//  VisionLockSlotModel.swift
//  KataGoUICore
//
//  Pure state mapping behind the visionOS bottom-bar lock slot — exact
//  iOS TopToolbarView parity. Off-branch the slot is the Lock/Unlock
//  toggle (lock / lock.open); while a branch is active it becomes the
//  red "Deactivate Branch" u-turn button, disabled whenever the engine
//  owes a genmove. Editing must never toggle while a branch is active
//  (a branch only forms while isEditing == false), which is why the two
//  states share one slot instead of coexisting. Vision has no auto-play
//  UI, so iOS's isAutoPlaying disable on the lock toggle does not apply.
//

import Foundation

public struct VisionLockSlotModel: Equatable, Sendable {
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

    public static func make(isBranchActive: Bool,
                            isEditing: Bool,
                            shouldGenMove: Bool) -> VisionLockSlotModel {
        if isBranchActive {
            return VisionLockSlotModel(kind: .deactivateBranch,
                                       systemImage: "arrow.uturn.backward.circle",
                                       label: "Deactivate Branch",
                                       isRed: true,
                                       isDisabled: shouldGenMove)
        }
        return VisionLockSlotModel(kind: .toggleLock,
                                   systemImage: isEditing ? "lock.open" : "lock",
                                   label: isEditing ? "Unlock" : "Lock",
                                   isRed: false,
                                   isDisabled: false)
    }
}
