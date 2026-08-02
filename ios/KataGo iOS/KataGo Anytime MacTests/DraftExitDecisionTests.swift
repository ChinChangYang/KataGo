//
//  DraftExitDecisionTests.swift
//  KataGo Anytime MacTests
//

import Testing

struct DraftExitDecisionTests {

    private let allTriggers: [DraftExitTrigger] =
        [.switchGame, .closeWindow, .quit, .lock, .deleteOrigin]

    @Test func noDraftAlwaysProceeds() {
        for trigger in allTriggers {
            #expect(DraftExitDecision.decide(hasDraft: false, isDirty: false,
                                             trigger: trigger) == .proceed)
        }
    }

    @Test func cleanDraftAlwaysProceeds() {
        for trigger in allTriggers {
            #expect(DraftExitDecision.decide(hasDraft: true, isDirty: false,
                                             trigger: trigger) == .proceed)
        }
    }

    @Test func dirtyDraftAlwaysPrompts() {
        for trigger in allTriggers {
            #expect(DraftExitDecision.decide(hasDraft: true, isDirty: true,
                                             trigger: trigger) == .prompt)
        }
    }
}
