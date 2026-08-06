//
//  WatchWidgetLibrarySourceTests.swift
//  KataGo AnytimeTests
//
//  Turning the newest library row into the record the complication renders.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct WatchWidgetLibrarySourceTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func row(name: String = "Ladder Fight 3") -> WatchLibraryRow {
        WatchLibraryRow(id: "GAME-A", name: name, boardWidth: 19, boardHeight: 19,
                        sgf: "(;GM[1])", lastModified: Date(timeIntervalSince1970: 500))
    }

    // MARK: extras

    @Test func theCommentIsLookedUpAtTheParkedIndexExactly() {
        // NOT GameEntity.init's keys.max() fallback: that exists because the
        // iOS widget draws a board and faults those dictionaries anyway, and
        // it would label a comment with the wrong position.
        let extras = WatchWidgetLibrarySource.extras(
            currentIndex: 42,
            comments: [30: "Joseki here.", 42: "White cuts."],
            scoreLeads: [42: 3.5])
        #expect(extras.parkedIndex == 42)
        #expect(extras.comment == "White cuts.")
        #expect(extras.scoreLeadBlack == 3.5)
    }

    @Test func anIndexWithNoCommentYieldsNil() {
        let extras = WatchWidgetLibrarySource.extras(
            currentIndex: 41, comments: [42: "White cuts."], scoreLeads: nil)
        #expect(extras.comment == nil)
        #expect(extras.scoreLeadBlack == nil)
    }

    @Test func aBlankCommentIsTreatedAsAbsent() {
        // An absent readout must be HIDDEN, not rendered as an empty region —
        // the rule WatchStoredAnalysis already enforces.
        let extras = WatchWidgetLibrarySource.extras(
            currentIndex: 5, comments: [5: "   "], scoreLeads: nil)
        #expect(extras.comment == nil)
    }

    @Test func aLongCommentIsCappedHereTooNotOnlyOnTheWire() {
        let extras = WatchWidgetLibrarySource.extras(
            currentIndex: 0, comments: [0: String(repeating: "a", count: 400)],
            scoreLeads: nil)
        #expect(extras.comment?.count == WatchWidgetSnapshot.commentCharacterLimit + 1)
    }

    // MARK: snapshot

    @Test func theSnapshotTakesNameAndIdFromTheRow() {
        let snapshot = WatchWidgetLibrarySource.snapshot(
            row: row(), moveCount: 178,
            extras: .init(parkedIndex: 42, comment: "White cuts.", scoreLeadBlack: 3.5),
            capturedAt: t0)
        #expect(snapshot.gameID == "GAME-A")
        #expect(snapshot.name == "Ladder Fight 3")
        #expect(snapshot.mainlineMoveCount == 178)
        #expect(snapshot.parkedIndex == 42)
        #expect(snapshot.capturedAt == t0)
    }

    @Test func aLibraryRecordIsNeverABranch() {
        // A saved record's currentIndex is frozen at the divergence point; the
        // branch index only ever exists on the phone's live frame.
        let snapshot = WatchWidgetLibrarySource.snapshot(
            row: row(), moveCount: 178,
            extras: .init(parkedIndex: 42, comment: nil, scoreLeadBlack: nil),
            capturedAt: t0)
        #expect(!snapshot.isBranch)
    }

    @Test func aParkedIndexPastTheMainlineIsClampedNotRendered() {
        // A record can carry a currentIndex beyond its own sgf after an edit;
        // "Move 200 of 178" must never be constructible.
        let snapshot = WatchWidgetLibrarySource.snapshot(
            row: row(), moveCount: 178,
            extras: .init(parkedIndex: 200, comment: nil, scoreLeadBlack: nil),
            capturedAt: t0)
        #expect(snapshot.parkedIndex <= snapshot.mainlineMoveCount)
    }

    @Test func aNegativeParkedIndexIsClampedToZero() {
        let snapshot = WatchWidgetLibrarySource.snapshot(
            row: row(), moveCount: 178,
            extras: .init(parkedIndex: -3, comment: nil, scoreLeadBlack: nil),
            capturedAt: t0)
        #expect(snapshot.parkedIndex == 0)
    }
}
