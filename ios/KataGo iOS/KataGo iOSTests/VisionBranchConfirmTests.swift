//
//  VisionBranchConfirmTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure content mapping behind the visionOS branch-confirm glass
//  card — the destructive second step of the Replace/Discard flow. The
//  strings are iOS GameSplitView's confirmation dialogs, verbatim: the
//  card exists because presenting a second .confirmationDialog while the
//  chooser dismisses blanks the volumetric window's render tree on
//  visionOS 26 (the chained-presentation fragility iOS only suffers as a
//  silently dropped sheet).
//

import Testing
@testable import KataGoUICore

struct VisionBranchConfirmTests {
    @Test func replaceMatchesTheiOSDialog() {
        let confirm = VisionBranchConfirm.make(kind: .replace)
        #expect(confirm.kind == .replace)
        #expect(confirm.title
                == "Replace the original game with this branch? The original game’s moves after this point will be permanently lost.")
        #expect(confirm.confirmLabel == "Replace")
    }

    @Test func discardMatchesTheiOSDialog() {
        let confirm = VisionBranchConfirm.make(kind: .discard)
        #expect(confirm.kind == .discard)
        #expect(confirm.title
                == "Discard this branch? Your newly played stones will be lost.")
        #expect(confirm.confirmLabel == "Discard Branch")
    }

    @Test func chooserMatchesTheiOSDialog() {
        #expect(VisionBranchConfirm.chooserTitle
                == "Branch moves are temporary. Replace the original game with this branch, or discard it?")
    }
}
