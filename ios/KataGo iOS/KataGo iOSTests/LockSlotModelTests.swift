//
//  LockSlotModelTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure state mapping behind the shared lock slot — used by the
//  visionOS bottom bar and the macOS toolbar: exact iOS TopToolbarView parity.
//  Off-branch it is the Lock/Unlock toggle (lock / lock.open, never red,
//  disabled only while auto-playing); while a branch is active it becomes the
//  red "Deactivate Branch" u-turn button, disabled whenever the engine owes a
//  genmove.
//
//  `isAutoPlaying` defaults to false so callers on platforms without an
//  auto-play UI (visionOS) keep the always-enabled toggle; macOS passes the
//  live flag, mirroring iOS's `.disabled(gobanState.isAutoPlaying)`.
//

import Testing
@testable import KataGoUICore

struct LockSlotModelTests {
    @Test func lockedGameOffersLock() {
        let slot = LockSlotModel.make(isBranchActive: false,
                                      isEditing: false,
                                      shouldGenMove: false)
        #expect(slot.kind == .toggleLock)
        #expect(slot.systemImage == "lock")
        #expect(slot.label == "Lock")
        #expect(!slot.isRed)
        #expect(!slot.isDisabled)
    }

    @Test func editingGameOffersUnlock() {
        let slot = LockSlotModel.make(isBranchActive: false,
                                      isEditing: true,
                                      shouldGenMove: false)
        #expect(slot.kind == .toggleLock)
        #expect(slot.systemImage == "lock.open")
        #expect(slot.label == "Unlock")
        #expect(!slot.isRed)
        #expect(!slot.isDisabled)
    }

    @Test func offBranchIgnoresShouldGenMove() {
        // iOS only disables the on-branch button while a genmove is owed; the
        // lock toggle's own disable is driven by auto-play, not by genmove.
        let slot = LockSlotModel.make(isBranchActive: false,
                                      isEditing: false,
                                      shouldGenMove: true)
        #expect(slot.kind == .toggleLock)
        #expect(!slot.isDisabled)
    }

    @Test func activeBranchOffersDeactivateBranch() {
        let slot = LockSlotModel.make(isBranchActive: true,
                                      isEditing: false,
                                      shouldGenMove: false)
        #expect(slot.kind == .deactivateBranch)
        #expect(slot.systemImage == "arrow.uturn.backward.circle")
        #expect(slot.label == "Deactivate Branch")
        #expect(slot.isRed)
        #expect(!slot.isDisabled)
    }

    @Test func activeBranchDisablesWhileGenMoveIsOwed() {
        let slot = LockSlotModel.make(isBranchActive: true,
                                      isEditing: false,
                                      shouldGenMove: true)
        #expect(slot.kind == .deactivateBranch)
        #expect(slot.isDisabled)
    }

    @Test func activeBranchIgnoresIsEditing() {
        // A branch only forms while isEditing == false, but the mapping must
        // not depend on it: the slot stays Deactivate Branch regardless.
        let editing = LockSlotModel.make(isBranchActive: true,
                                         isEditing: true,
                                         shouldGenMove: false)
        let locked = LockSlotModel.make(isBranchActive: true,
                                        isEditing: false,
                                        shouldGenMove: false)
        #expect(editing == locked)
    }

    // MARK: - isAutoPlaying (macOS parity with iOS's disabled lock toggle)

    @Test func autoPlayingDisablesTheLockToggle() {
        // iOS: `.disabled(gobanState.isAutoPlaying)` on the lock button.
        // Flipping isEditing mid-replay would let the auto-play observer's
        // isEditing branch cancel the run underneath it.
        for isEditing in [false, true] {
            let slot = LockSlotModel.make(isBranchActive: false,
                                          isEditing: isEditing,
                                          shouldGenMove: false,
                                          isAutoPlaying: true)
            #expect(slot.kind == .toggleLock)
            #expect(slot.isDisabled)
            // Only enablement changes — the icon/label still describe state.
            #expect(slot.systemImage == (isEditing ? "lock.open" : "lock"))
            #expect(slot.label == (isEditing ? "Unlock" : "Lock"))
        }
    }

    @Test func autoPlayingDefaultsToNotDisabled() {
        // Callers that omit the parameter (visionOS) keep the pre-existing
        // always-enabled toggle.
        let omitted = LockSlotModel.make(isBranchActive: false,
                                         isEditing: false,
                                         shouldGenMove: false)
        let explicitFalse = LockSlotModel.make(isBranchActive: false,
                                               isEditing: false,
                                               shouldGenMove: false,
                                               isAutoPlaying: false)
        #expect(omitted == explicitFalse)
        #expect(!omitted.isDisabled)
    }

    @Test func autoPlayingDoesNotDisableDeactivateBranch() {
        // Exiting a branch stays available regardless of auto-play; only a
        // genmove in flight blocks it.
        let slot = LockSlotModel.make(isBranchActive: true,
                                      isEditing: false,
                                      shouldGenMove: false,
                                      isAutoPlaying: true)
        #expect(slot.kind == .deactivateBranch)
        #expect(!slot.isDisabled)
    }
}
