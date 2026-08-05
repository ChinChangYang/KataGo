//
//  WatchWidgetTileTextTests.swift
//  KataGo AnytimeTests
//
//  Which of the rectangular layouts the tile picks, and every string it puts
//  on a watch face. The widget view itself has no test target and cannot get
//  one, so all of its policy lives here.
//

import Testing
import Foundation
import KataGoAnalysisKit

struct WatchWidgetTileTextTests {
    private func snapshot(name: String = "Ladder Fight 3",
                          comment: String? = nil,
                          parkedIndex: Int = 42,
                          mainlineMoveCount: Int = 178,
                          score: Double? = 3.5,
                          isBranch: Bool = false) -> WatchWidgetSnapshot {
        WatchWidgetSnapshot(gameID: "GAME-A", name: name, comment: comment,
                            parkedIndex: parkedIndex,
                            mainlineMoveCount: mainlineMoveCount,
                            scoreLeadBlack: score, isBranch: isBranch,
                            capturedAt: Date(timeIntervalSince1970: 0), source: .live)
    }

    // MARK: layout choice

    @Test func noAppGroupIsItsOwnState() {
        // Distinct from "no data": the tile now claims to show a game name, so
        // silence about a storage failure would read as an empty library.
        let layout = WatchWidgetTileText.layout(for: nil, storageAvailable: false,
                                                luminanceReduced: false)
        #expect(layout == .unavailable(headline: "Storage unavailable", detail: nil))
    }

    @Test func noRecordPointsAtTheWatchApp() {
        let layout = WatchWidgetTileText.layout(for: nil, storageAvailable: true,
                                                luminanceReduced: false)
        #expect(layout == .unavailable(headline: "No game yet",
                                       detail: "Open KataGo Anytime on your Watch"))
    }

    @Test func aCommentGetsTheCommentLayout() {
        #expect(WatchWidgetTileText.layout(for: snapshot(comment: "White cuts."),
                                           storageAvailable: true,
                                           luminanceReduced: false) == .withComment)
    }

    @Test func noCommentIsTheDefaultLayoutNotAnEmptyRegion() {
        // Comments are sparse at most indices — WatchStoredGameView already
        // prints "No analysis saved for this move" for exactly this case — so
        // the comment-less layout is the common one, and it must fill the rect
        // rather than leave a hole where a paragraph would go.
        #expect(WatchWidgetTileText.layout(for: snapshot(comment: nil),
                                           storageAvailable: true,
                                           luminanceReduced: false) == .withoutComment)
    }

    @Test func alwaysOnDropsTheCommentBody() {
        // A multi-line paragraph at reduced contrast is unreadable, and the
        // guidance for the dimmed state is to reduce content.
        #expect(WatchWidgetTileText.layout(for: snapshot(comment: "White cuts."),
                                           storageAvailable: true,
                                           luminanceReduced: true) == .reduced)
    }

    @Test func alwaysOnStillReportsAMissingAppGroup() {
        let layout = WatchWidgetTileText.layout(for: nil, storageAvailable: false,
                                                luminanceReduced: true)
        #expect(layout == .unavailable(headline: "Storage unavailable", detail: nil))
    }

    // MARK: legacy score cutover

    @Test func noRecordWithALegacyScoreShowsTheLegacyLayout() {
        // The one-release cutover window: nothing has written the new record
        // yet, but the retired complication's score is still in the App
        // Group and is worth more than a "no game" card.
        let layout = WatchWidgetTileText.layout(for: nil, legacyScoreLeadBlack: 3.5,
                                                storageAvailable: true,
                                                luminanceReduced: false)
        #expect(layout == .legacyScore("B+3.5"))
    }

    @Test func aRealRecordIgnoresALingeringLegacyScore() {
        // Once the new record exists it is always the truth; a leftover
        // legacy scalar from before the cutover must never override it.
        let layout = WatchWidgetTileText.layout(for: snapshot(comment: nil),
                                                legacyScoreLeadBlack: 3.5,
                                                storageAvailable: true,
                                                luminanceReduced: false)
        #expect(layout == .withoutComment)
    }

    @Test func storageUnavailableOutranksALingeringLegacyScore() {
        // A tile that cannot read its record has nothing to fall back to —
        // the legacy scalar lives in the same App Group, so it is exactly as
        // unreachable as the record would be.
        let layout = WatchWidgetTileText.layout(for: nil, legacyScoreLeadBlack: 3.5,
                                                storageAvailable: false,
                                                luminanceReduced: false)
        #expect(layout == .unavailable(headline: "Storage unavailable", detail: nil))
    }

    @Test func legacyScoreWinsOverAlwaysOnDimming() {
        // .reduced dims an EXISTING record's content; with no record at all
        // there is nothing to dim, so the legacy score still wins even under
        // Always-On.
        let layout = WatchWidgetTileText.layout(for: nil, legacyScoreLeadBlack: 3.5,
                                                storageAvailable: true,
                                                luminanceReduced: true)
        #expect(layout == .legacyScore("B+3.5"))
    }

    // MARK: score

    @Test func theScoreNamesItsLeader() {
        #expect(WatchWidgetTileText.scoreText(3.5) == "B+3.5")
        #expect(WatchWidgetTileText.scoreText(-3.5) == "W+3.5")
        #expect(WatchWidgetTileText.scoreText(nil) == nil)
    }

    @Test func theCircularScoreDropsTheDecimal() {
        // A signed one-decimal score does not fit above the legibility floor
        // in circular's usable inner square.
        #expect(WatchWidgetTileText.compactScoreText(21.8) == "B+22")
        #expect(WatchWidgetTileText.compactScoreText(-21.8) == "W+22")
    }

    // MARK: move line

    @Test func theMoveLineNamesTheMainlineLength() {
        #expect(WatchWidgetTileText.moveText(parkedIndex: 42, mainlineMoveCount: 178,
                                             isBranch: false) == "Move 42 of 178")
    }

    @Test func aBranchIndexNeverClaimsAMainlineLength() {
        // On a branch the index and the count describe different lines, so
        // "Move 42 of 30" is renderable unless this is suppressed.
        #expect(WatchWidgetTileText.moveText(parkedIndex: 42, mainlineMoveCount: 30,
                                             isBranch: true) == "Move 42")
    }

    @Test func anIndexPastTheCountNeverRendersAnImpossibleRatio() {
        #expect(WatchWidgetTileText.moveText(parkedIndex: 42, mainlineMoveCount: 30,
                                             isBranch: false) == "Move 42")
    }

    // MARK: inline

    @Test func inlineLeadsWithTheDurableToken() {
        // The slot is system-styled and shares space with the date on several
        // faces, so the score must survive truncation even when the name does
        // not.
        let text = WatchWidgetTileText.inlineText(for: snapshot(name: "Ladder Fight 3"))
        #expect(text.hasPrefix("B+4"))
        #expect(text.count <= WatchWidgetTileText.inlineBudget)
    }

    @Test func inlineTruncatesTheNameNotTheScore() {
        let text = WatchWidgetTileText.inlineText(
            for: snapshot(name: "A Very Long Game Name Indeed"))
        #expect(text.hasPrefix("B+4"))
        #expect(text.count <= WatchWidgetTileText.inlineBudget)
        #expect(text.hasSuffix("\u{2026}"))
    }

    @Test func inlineFallsBackToTheMoveNumberWithoutAScore() {
        let text = WatchWidgetTileText.inlineText(for: snapshot(score: nil))
        #expect(text.hasPrefix("Move 42"))
    }

    @Test func inlineSaysSomethingWithNoRecord() {
        #expect(WatchWidgetTileText.inlineText(for: nil) == "No game")
    }

    @Test func inlineUsesAnAsciiSeparator() {
        // House rule from WatchLibraryRow.sizeText: ASCII only in these small
        // strings, not a typographic middot.
        let text = WatchWidgetTileText.inlineText(for: snapshot(name: "Go"))
        #expect(text.contains(" - "))
    }

    @Test func inlineFallsBackToTheLegacyScoreWithNoRecord() {
        let text = WatchWidgetTileText.inlineText(for: nil, legacyScoreLeadBlack: 21.8)
        #expect(text == "B+22")
    }

    // MARK: circular

    @Test func circularShowsTheScoreThenTheMoveNumber() {
        #expect(WatchWidgetTileText.circularText(for: snapshot(score: 21.8)) == "B+22")
        #expect(WatchWidgetTileText.circularText(for: snapshot(score: nil)) == "42")
        #expect(WatchWidgetTileText.circularText(for: nil) == "--")
    }

    @Test func circularFallsBackToTheLegacyScoreWithNoRecord() {
        let text = WatchWidgetTileText.circularText(for: nil, legacyScoreLeadBlack: -21.8)
        #expect(text == "W+22")
    }
}
