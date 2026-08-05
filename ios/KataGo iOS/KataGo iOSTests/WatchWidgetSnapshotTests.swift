//
//  WatchWidgetSnapshotTests.swift
//  KataGo AnytimeTests
//
//  The record the watch complication renders, and the content key that
//  decides when it is worth writing at all.
//

import Testing
import Foundation
import KataGoAnalysisKit

struct WatchWidgetSnapshotTests {
    private func sample(name: String = "Ladder Fight 3",
                        comment: String? = "White cuts.",
                        parkedIndex: Int = 42,
                        mainlineMoveCount: Int = 178,
                        score: Double? = 3.5,
                        isBranch: Bool = false,
                        capturedAt: Date = Date(timeIntervalSince1970: 1_000)) -> WatchWidgetSnapshot {
        WatchWidgetSnapshot(gameID: "GAME-A", name: name,
                            comment: comment, parkedIndex: parkedIndex,
                            mainlineMoveCount: mainlineMoveCount, scoreLeadBlack: score,
                            isBranch: isBranch, capturedAt: capturedAt, source: .live)
    }

    // MARK: content key

    @Test func theKeyIgnoresCapturedAtAndSource() {
        // Otherwise every 2 Hz frame would look like a change and the writer
        // would encode + write to cfprefsd twice a second on watch hardware.
        var other = sample(capturedAt: Date(timeIntervalSince1970: 9_999))
        other.source = .library
        #expect(sample().contentKey == other.contentKey)
    }

    @Test func theKeyChangesWithTheComment() {
        #expect(sample().contentKey != sample(comment: "Black lives.").contentKey)
    }

    @Test func theKeyChangesWithTheParkedIndex() {
        #expect(sample().contentKey != sample(parkedIndex: 43).contentKey)
    }

    @Test func theKeyRoundsTheScoreToATenthOfAPoint() {
        // Analysis jitter must not churn the key, but a real half-point swing
        // must be visible.
        #expect(sample(score: 3.52).contentKey == sample(score: 3.54).contentKey)
        #expect(sample(score: 3.5).contentKey != sample(score: 4.0).contentKey)
    }

    @Test func theKeyTreatsPlusAndMinusZeroAsTheSameScore() {
        // A signed-zero formatter would emit "0.0" and "-0.0" and flap the key
        // every time the lead crossed even.
        #expect(sample(score: 0.02).contentKey == sample(score: -0.02).contentKey)
    }

    @Test func aMissingScoreIsNotTheSameAsZero() {
        #expect(sample(score: nil).contentKey != sample(score: 0).contentKey)
    }

    @Test func contentCannotForgeAFieldBoundary() {
        // "X|Y" name + "c" comment must not collapse onto "X" name +
        // "Y|c" comment: naive pipe-joining makes both render as
        // "...|X|Y|c|..." and the second, genuinely different snapshot's
        // display change would be silently dropped by the write gate.
        let a = sample(name: "X|Y", comment: "c")
        let b = sample(name: "X", comment: "Y|c")
        #expect(a.contentKey != b.contentKey)
    }

    @Test func theKeyChangesWithIsBranch() {
        // The tile suppresses "of 178" when isBranch is true, so a branch
        // flip with everything else equal must still change what is drawn.
        #expect(sample().contentKey != sample(isBranch: true).contentKey)
    }

    @Test func theKeyChangesWithMainlineMoveCount() {
        // The tile renders "Move 42 of 178"; a change to the mainline
        // length alone must be visible to the write gate.
        #expect(sample().contentKey != sample(mainlineMoveCount: 179).contentKey)
    }

    // MARK: comment cap

    @Test func aShortCommentPassesThroughUntouched() {
        #expect(WatchWidgetSnapshot.cappedComment("Short.") == "Short.")
    }

    @Test func aBlankCommentBecomesNil() {
        // An absent comment must be HIDDEN, not rendered as an empty region.
        #expect(WatchWidgetSnapshot.cappedComment("   \n ") == nil)
        #expect(WatchWidgetSnapshot.cappedComment(nil) == nil)
    }

    @Test func aLongCommentIsCappedAndEllipsized() {
        let long = String(repeating: "a", count: 400)
        let capped = WatchWidgetSnapshot.cappedComment(long)
        #expect(capped?.count == WatchWidgetSnapshot.commentCharacterLimit + 1)
        #expect(capped?.hasSuffix("\u{2026}") == true)
    }

    @Test func theCapCountsGraphemesNotBytes() {
        // Imported SGFs routinely carry CJK commentary; a byte or scalar cap
        // would truncate mid-character and could split a grapheme cluster.
        let cjk = String(repeating: "\u{56F4}\u{68CB}", count: 300)   // 600 characters
        let capped = WatchWidgetSnapshot.cappedComment(cjk)
        #expect(capped?.count == WatchWidgetSnapshot.commentCharacterLimit + 1)
    }

    @Test func aMultiScalarGraphemeIsNeverSplit() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"   // one grapheme, 5 scalars
        let text = String(repeating: family, count: 300)
        let capped = WatchWidgetSnapshot.cappedComment(text)
        #expect(capped?.count == WatchWidgetSnapshot.commentCharacterLimit + 1)
        // Dropping the trailing ellipsis must leave whole family clusters.
        let body = String(capped!.dropLast())
        #expect(body.unicodeScalars.count == WatchWidgetSnapshot.commentCharacterLimit * 5)
    }

    // MARK: codable

    @Test func itRoundTripsThroughJson() {
        let encoded = try! JSONEncoder().encode(sample())
        let decoded = try! JSONDecoder().decode(WatchWidgetSnapshot.self, from: encoded)
        #expect(decoded == sample())
    }
}
