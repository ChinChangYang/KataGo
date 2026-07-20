//
//  DeepReportCommentTests.swift
//  KataGo AnytimeTests
//
//  Copy-to-Comment replaces the current move's comment; the confirmation
//  dialog appears only when a non-empty comment would be overwritten.
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

// @MainActor: the DeepReportView statics under test are MainActor-isolated
// (View conformance), so nonisolated test funcs would warn on every call.
@MainActor
struct DeepReportCommentTests {
    @Test func noExistingCommentNeedsNoConfirmation() {
        #expect(DeepReportView.replaceNeedsConfirmation(existingComment: nil) == false)
    }

    @Test func emptyExistingCommentNeedsNoConfirmation() {
        #expect(DeepReportView.replaceNeedsConfirmation(existingComment: "") == false)
    }

    @Test func nonEmptyExistingCommentNeedsConfirmation() {
        #expect(DeepReportView.replaceNeedsConfirmation(existingComment: "old note") == true)
    }

    @Test func copyReplacesExistingCommentInsteadOfAppending() {
        // The headline behavior of the fix: an existing comment is REPLACED,
        // not appended to. A regression restoring the old
        // `existing + "\n\n" + text` append fails this.
        let result = DeepReportView.applyingCopiedComment(
            [3: "old note"], text: "report summary", index: 3)
        #expect(result[3] == "report summary")
    }

    @Test func copyWritesIntoEmptyDictionary() {
        let result = DeepReportView.applyingCopiedComment(
            nil, text: "report summary", index: 5)
        #expect(result == [5: "report summary"])
    }

    @Test func copyLeavesOtherMovesUntouched() {
        let result = DeepReportView.applyingCopiedComment(
            [1: "keep me", 3: "old"], text: "new", index: 3)
        #expect(result[1] == "keep me")
        #expect(result[3] == "new")
    }
}
