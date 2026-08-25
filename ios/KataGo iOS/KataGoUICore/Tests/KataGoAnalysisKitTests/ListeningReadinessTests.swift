//
//  ListeningReadinessTests.swift
//  KataGoAnalysisKitTests
//
//  Offline, engine-free. Runs via `swift test --filter KataGoAnalysisKitTests`.
//

import Testing
@testable import KataGoAnalysisKit

struct ListeningReadinessTests {
    @Test func fullCoverageIncludingOpeningPositionIsReady() {
        #expect(ListeningReadiness.isReady(moveCount: 3, analyzedIndices: [0, 1, 2, 3]))
    }

    @Test func missingOpeningPositionIsNotReady() {
        #expect(!ListeningReadiness.isReady(moveCount: 3, analyzedIndices: [1, 2, 3]))
    }

    @Test func oneInteriorHoleIsNotReady() {
        #expect(!ListeningReadiness.isReady(moveCount: 4, analyzedIndices: [0, 1, 3, 4]))
    }

    @Test func emptyGameIsNeverReady() {
        #expect(!ListeningReadiness.isReady(moveCount: 0, analyzedIndices: [0]))
    }

    @Test func extraIndicesBeyondTheGameDoNotMatter() {
        #expect(ListeningReadiness.isReady(moveCount: 2, analyzedIndices: [0, 1, 2, 9]))
    }

    @Test func absentCursorStartsAtMoveOne() {
        #expect(ListeningReadiness.clampedCursor(stored: nil, moveCount: 100) == 1)
    }

    @Test func cursorWithinTheGameIsKept() {
        #expect(ListeningReadiness.clampedCursor(stored: 42, moveCount: 100) == 42)
    }

    @Test func cursorPastAShrunkenGameSnapsToTheLastMove() {
        #expect(ListeningReadiness.clampedCursor(stored: 42, moveCount: 30) == 30)
    }

    @Test func cursorForAnEmptyGameStartsAtMoveOne() {
        #expect(ListeningReadiness.clampedCursor(stored: 42, moveCount: 0) == 1)
    }

    @Test func nonPositiveStoredCursorIsFlooredAtOne() {
        #expect(ListeningReadiness.clampedCursor(stored: 0, moveCount: 10) == 1)
        #expect(ListeningReadiness.clampedCursor(stored: -5, moveCount: 10) == 1)
    }
}
