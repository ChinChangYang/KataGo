//
//  DraftExitDecision.swift
//  KataGo Anytime Mac
//

import Foundation

/// Every way a user can leave the game they are editing.
enum DraftExitTrigger: Equatable {
    case switchGame
    case closeWindow
    case quit
    case lock
    case deleteOrigin
}

/// What the user chose in the Save · Discard · Cancel sheet.
enum DraftExitAnswer: Equatable {
    case save
    case discard
    case cancel
}

/// Whether leaving needs to ask first.
///
/// Uniform on purpose: the trigger does not change the answer. Its only job is
/// to be reported to the user in the sheet's wording, so the rule stays one
/// line and no exit path can quietly acquire different semantics from the
/// others.
enum DraftExitDecision: Equatable {
    case proceed
    case prompt

    static func decide(hasDraft: Bool,
                       isDirty: Bool,
                       trigger: DraftExitTrigger) -> DraftExitDecision {
        (hasDraft && isDirty) ? .prompt : .proceed
    }
}
