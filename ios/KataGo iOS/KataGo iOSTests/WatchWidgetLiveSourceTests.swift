//
//  WatchWidgetLiveSourceTests.swift
//  KataGo AnytimeTests
//
//  Which live frames are allowed to become the complication's record, and
//  what the watch fills in when the phone did not send it.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct WatchWidgetLiveSourceTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func frame(gameID: String? = "GAME-A",
                       name: String? = "Ladder Fight 3",
                       comment: String? = "White cuts.",
                       index: Int? = 42,
                       count: Int? = 178,
                       branch: Bool? = false) -> WatchSnapshot {
        var snapshot = WatchSnapshot(boardWidth: 19, boardHeight: 19,
                                     blackStones: [], whiteStones: [],
                                     toMove: "B", moveNumber: 0, analysisRunning: true,
                                     rootWinrateBlack: 0.55, rootScoreLeadBlack: 3.5,
                                     candidates: [], hostTimestamp: t0)
        snapshot.hostGameID = gameID
        snapshot.hostMoveIndex = index
        snapshot.hostMoveCount = count
        snapshot.gameName = name
        snapshot.positionComment = comment
        snapshot.isBranch = branch
        return snapshot
    }

    @Test func aNormalFrameBecomesALiveRecord() {
        let record = WatchWidgetLiveSource.snapshot(from: frame(), fallbackName: nil,
                                                    capturedAt: t0)
        #expect(record?.gameID == "GAME-A")
        #expect(record?.name == "Ladder Fight 3")
        #expect(record?.comment == "White cuts.")
        #expect(record?.parkedIndex == 42)
        #expect(record?.mainlineMoveCount == 178)
        #expect(record?.scoreLeadBlack == 3.5)
        #expect(record?.source == .live)
    }

    @Test func aFrameWithNoGameIsRefused() {
        // This is a NORMAL frame, not a malformed one: the builder fills the
        // host fields only `if let gameRecord`, and the relay passes an
        // Optional selectedGameRecord, so a phone cold launch before selection
        // lands pushes exactly this. Accepting it would put a nameless record
        // with a fresh clock ahead of the library.
        #expect(WatchWidgetLiveSource.snapshot(from: frame(gameID: nil),
                                               fallbackName: "Ladder Fight 3",
                                               capturedAt: t0) == nil)
    }

    @Test func anOlderPhoneIsRescuedByTheLibraryName() {
        // A v1.2 phone sends no gameName. Backfilling watch-side is what keeps
        // the tile correct against any phone build — WCSession replays the
        // persisted context on every cold launch, so one stale frame would
        // otherwise regenerate a blank record indefinitely.
        let record = WatchWidgetLiveSource.snapshot(from: frame(name: nil, comment: nil),
                                                    fallbackName: "From Library",
                                                    capturedAt: t0)
        #expect(record?.name == "From Library")
    }

    @Test func aFrameWithNoNameAnywhereIsRefused() {
        #expect(WatchWidgetLiveSource.snapshot(from: frame(name: nil),
                                               fallbackName: nil,
                                               capturedAt: t0) == nil)
        #expect(WatchWidgetLiveSource.snapshot(from: frame(name: "  "),
                                               fallbackName: "   ",
                                               capturedAt: t0) == nil)
    }

    @Test func aBranchFrameCarriesNoComment() {
        // hostMoveIndex is a branch index there; the record's comments are
        // mainline-indexed, so any comment would belong to another line.
        let record = WatchWidgetLiveSource.snapshot(from: frame(comment: "Mainline note.",
                                                                branch: true),
                                                    fallbackName: nil, capturedAt: t0)
        #expect(record?.comment == nil)
        #expect(record?.isBranch == true)
    }

    @Test func aPreV11FrameWithNoCursorStillReportsAPosition() {
        let record = WatchWidgetLiveSource.snapshot(from: frame(index: nil, count: nil),
                                                    fallbackName: nil, capturedAt: t0)
        #expect(record?.parkedIndex == 0)
        #expect(record?.mainlineMoveCount == 0)
    }

    @Test func theCapIsAppliedToTheCommentHereToo() {
        let record = WatchWidgetLiveSource.snapshot(
            from: frame(comment: String(repeating: "a", count: 400)),
            fallbackName: nil, capturedAt: t0)
        #expect(record?.comment?.count == WatchWidgetSnapshot.commentCharacterLimit + 1)
    }

    @Test func capturedAtIsTheWatchClockNotTheHostTimestamp() {
        // hostTimestamp is a 2 Hz heartbeat; using it would let a phone idling
        // on an old game outrank every library edit forever.
        let watchNow = t0.addingTimeInterval(9_999)
        let record = WatchWidgetLiveSource.snapshot(from: frame(), fallbackName: nil,
                                                    capturedAt: watchNow)
        #expect(record?.capturedAt == watchNow)
    }
}
