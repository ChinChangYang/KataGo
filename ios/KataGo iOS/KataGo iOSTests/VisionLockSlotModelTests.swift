//
//  VisionLockSlotModelTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure state mapping behind the visionOS bottom-bar lock slot:
//  exact iOS TopToolbarView parity — off-branch it is the Lock/Unlock
//  toggle (lock / lock.open, never red, never disabled; Vision has no
//  auto-play UI, so iOS's isAutoPlaying disable does not apply); while a
//  branch is active it becomes the red "Deactivate Branch" u-turn button,
//  disabled whenever the engine owes a genmove.
//

import Testing
@testable import KataGoUICore

struct VisionLockSlotModelTests {
    @Test func lockedGameOffersLock() {
        let slot = VisionLockSlotModel.make(isBranchActive: false,
                                            isEditing: false,
                                            shouldGenMove: false)
        #expect(slot.kind == .toggleLock)
        #expect(slot.systemImage == "lock")
        #expect(slot.label == "Lock")
        #expect(!slot.isRed)
        #expect(!slot.isDisabled)
    }

    @Test func editingGameOffersUnlock() {
        let slot = VisionLockSlotModel.make(isBranchActive: false,
                                            isEditing: true,
                                            shouldGenMove: false)
        #expect(slot.kind == .toggleLock)
        #expect(slot.systemImage == "lock.open")
        #expect(slot.label == "Unlock")
        #expect(!slot.isRed)
        #expect(!slot.isDisabled)
    }

    @Test func offBranchIgnoresShouldGenMove() {
        // iOS only disables the on-branch button while a genmove is owed;
        // the lock toggle itself never disables on Vision (no auto-play).
        let slot = VisionLockSlotModel.make(isBranchActive: false,
                                            isEditing: false,
                                            shouldGenMove: true)
        #expect(slot.kind == .toggleLock)
        #expect(!slot.isDisabled)
    }

    @Test func activeBranchOffersDeactivateBranch() {
        let slot = VisionLockSlotModel.make(isBranchActive: true,
                                            isEditing: false,
                                            shouldGenMove: false)
        #expect(slot.kind == .deactivateBranch)
        #expect(slot.systemImage == "arrow.uturn.backward.circle")
        #expect(slot.label == "Deactivate Branch")
        #expect(slot.isRed)
        #expect(!slot.isDisabled)
    }

    @Test func activeBranchDisablesWhileGenMoveIsOwed() {
        let slot = VisionLockSlotModel.make(isBranchActive: true,
                                            isEditing: false,
                                            shouldGenMove: true)
        #expect(slot.kind == .deactivateBranch)
        #expect(slot.isDisabled)
    }

    @Test func activeBranchIgnoresIsEditing() {
        // A branch only forms while isEditing == false, but the mapping must
        // not depend on it: the slot stays Deactivate Branch regardless.
        let editing = VisionLockSlotModel.make(isBranchActive: true,
                                               isEditing: true,
                                               shouldGenMove: false)
        let locked = VisionLockSlotModel.make(isBranchActive: true,
                                              isEditing: false,
                                              shouldGenMove: false)
        #expect(editing == locked)
    }
}
