//
//  ThumbnailPreferenceTests.swift
//  KataGo AnytimeTests
//
//  The game-list row's two new rules: the note it shows is the one on the move
//  the game is PARKED on (the same move its thumbnail draws), and the thumbnail
//  is a three-state size where Off is the degenerate member rather than a
//  separate switch. The migration is pinned too — the retired
//  `isLargeThumbnail` bool has to survive the move to `GlobalSettings.*`, or an
//  update silently resizes somebody's library.
//

import Testing
import Foundation
@testable import KataGoUICore

@MainActor
struct LibraryRowCommentTests {
    private func record(comments: [Int: String]?, currentIndex: Int) -> GameRecord {
        let record = GameRecord.createGameRecord(name: "Row")
        record.comments = comments
        record.currentIndex = currentIndex
        return record
    }

    @Test func showsTheCommentOnTheParkedMove() {
        let game = record(comments: [0: "root note", 2: "parked note"], currentIndex: 2)
        #expect(game.libraryRowComment == "parked note")
    }

    /// The rows read `comments?[0]` before this change. A game annotated only
    /// mid-play must not fall back to a root note that describes another move.
    @Test func doesNotFallBackToTheRootComment() {
        let game = record(comments: [0: "root note"], currentIndex: 5)
        #expect(game.libraryRowComment == nil)
    }

    @Test func aMoveWithNoNoteHasNoLine() {
        let game = record(comments: [:], currentIndex: 0)
        #expect(game.libraryRowComment == nil)
    }

    @Test func aNilDictionaryHasNoLine() {
        let game = record(comments: nil, currentIndex: 0)
        #expect(game.libraryRowComment == nil)
    }

    /// `CommentPersistence` refuses to WRITE a blank, but an SGF import puts
    /// `C[]` text straight into the dictionary without passing through it.
    @Test func whitespaceOnlyCountsAsAbsent() {
        #expect(record(comments: [1: "   "], currentIndex: 1).libraryRowComment == nil)
        #expect(record(comments: [1: "\n\t "], currentIndex: 1).libraryRowComment == nil)
        #expect(record(comments: [1: ""], currentIndex: 1).libraryRowComment == nil)
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        #expect(record(comments: [1: "  a note\n"], currentIndex: 1).libraryRowComment == "a note")
    }

    /// A row note is one line by definition, and a real comment is often a
    /// paragraph — Deep Report's "Copy to Comment" writes several. AppKit lays
    /// hard line breaks out as separate lines whatever `maximumNumberOfLines`
    /// says (this shipped as an eight-line sidebar row), and SwiftUI's
    /// `lineLimit(1)` would show only the first line with no sign of the rest.
    @Test func lineBreaksCollapseToOneLine() {
        let paragraph = "Position: move 26.\nCurrent evaluation: Black leads.\nBest move: M17."
        #expect(record(comments: [1: paragraph], currentIndex: 1).libraryRowComment
                == "Position: move 26. Current evaluation: Black leads. Best move: M17.")
    }

    @Test func runsOfWhitespaceCollapseToASingleSpace() {
        #expect(record(comments: [1: "a\t\t b   c"], currentIndex: 1).libraryRowComment == "a b c")
    }

    /// A cursor left past the end of a game that has since shrunk finds no
    /// entry — `clearData(after:)` drops comments above the cursor — so the row
    /// loses the line instead of needing a clamp, which would cost a parse.
    @Test func anIndexPastAShrunkGameHasNoLine() {
        let game = record(comments: [0: "root", 1: "one"], currentIndex: 40)
        #expect(game.libraryRowComment == nil)
    }
}

struct ThumbnailMetricsTests {
    private var offIndex: Int { Config.thumbnailSizes.firstIndex(of: Config.offThumbnailSize)! }
    private var smallIndex: Int { Config.thumbnailSizes.firstIndex(of: Config.smallThumbnailSize)! }
    private var largeIndex: Int { Config.thumbnailSizes.firstIndex(of: Config.largeThumbnailSize)! }

    @Test func theDefaultIsSmall() {
        #expect(Config.defaultThumbnailSize == smallIndex)
        #expect(Config.defaultThumbnailSizeText == Config.smallThumbnailSize)
    }

    /// `nil` is the signal that the row must not resolve a board at all, so it
    /// has to mean Off and nothing else.
    @Test func onlyOffHasNoSize() {
        #expect(ThumbnailMetrics.side(for: offIndex) == nil)
        #expect(ThumbnailMetrics.side(for: smallIndex) == ThumbnailMetrics.smallSide)
        #expect(ThumbnailMetrics.side(for: largeIndex) == ThumbnailMetrics.largeSide)
    }

    @Test func largeIsBiggerThanSmall() {
        #expect(ThumbnailMetrics.largeSide > ThumbnailMetrics.smallSide)
    }

    /// A corrupt index falls back to the default SIZE, never to `nil`: a bad
    /// stored value should not silently empty the library.
    @Test func anOutOfRangeIndexFallsBackToTheDefaultSize() {
        #expect(ThumbnailMetrics.side(for: -1) == ThumbnailMetrics.smallSide)
        #expect(ThumbnailMetrics.side(for: 99) == ThumbnailMetrics.smallSide)
    }

    @Test func gobanStateReportsHiddenOnlyForOff() {
        let state = GobanState()
        state.thumbnailSize = offIndex
        #expect(state.isThumbnailHidden)
        #expect(state.thumbnailSizeText == Config.offThumbnailSize)

        state.thumbnailSize = largeIndex
        #expect(!state.isThumbnailHidden)
        #expect(state.thumbnailSizeText == Config.largeThumbnailSize)

        // Out of range reports "not hidden" and the default text, matching the
        // sibling helpers' bounds-checking idiom.
        state.thumbnailSize = 99
        #expect(!state.isThumbnailHidden)
        #expect(state.thumbnailSizeText == Config.defaultThumbnailSizeText)
    }
}

struct ThumbnailSizeMigrationTests {
    /// An isolated suite so the tests never touch the simulator's real
    /// preferences (and so they cannot depend on each other's writes).
    private func withScratchDefaults(_ body: (UserDefaults) -> Void) {
        let name = "ThumbnailSizeMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        body(defaults)
        defaults.removePersistentDomain(forName: name)
    }

    @Test func aLargeLegacyValueBecomesLarge() {
        withScratchDefaults { defaults in
            defaults.set(true, forKey: ThumbnailSizePreference.legacyIsLargeKey)
            ThumbnailSizePreference.migrateLegacyValueIfNeeded(in: defaults)
            #expect(defaults.object(forKey: GlobalSettingsKeys.thumbnailSize) as? Int
                    == Config.thumbnailSizes.firstIndex(of: Config.largeThumbnailSize))
        }
    }

    @Test func aSmallLegacyValueBecomesSmall() {
        withScratchDefaults { defaults in
            defaults.set(false, forKey: ThumbnailSizePreference.legacyIsLargeKey)
            ThumbnailSizePreference.migrateLegacyValueIfNeeded(in: defaults)
            #expect(defaults.object(forKey: GlobalSettingsKeys.thumbnailSize) as? Int
                    == Config.thumbnailSizes.firstIndex(of: Config.smallThumbnailSize))
        }
    }

    /// An install that never had the old preference is left alone, so the new
    /// key's own `@AppStorage` default (Small) decides.
    @Test func noLegacyValueWritesNothing() {
        withScratchDefaults { defaults in
            ThumbnailSizePreference.migrateLegacyValueIfNeeded(in: defaults)
            #expect(defaults.object(forKey: GlobalSettingsKeys.thumbnailSize) == nil)
        }
    }

    /// The whole point of the guard: a user who has since chosen Off must not
    /// have the retired bool put a picture back on every row.
    @Test func anExistingChoiceIsNeverOverwritten() {
        withScratchDefaults { defaults in
            let off = Config.thumbnailSizes.firstIndex(of: Config.offThumbnailSize)!
            defaults.set(off, forKey: GlobalSettingsKeys.thumbnailSize)
            defaults.set(true, forKey: ThumbnailSizePreference.legacyIsLargeKey)

            ThumbnailSizePreference.migrateLegacyValueIfNeeded(in: defaults)
            #expect(defaults.object(forKey: GlobalSettingsKeys.thumbnailSize) as? Int == off)
        }
    }

    @Test func runningTwiceChangesNothing() {
        withScratchDefaults { defaults in
            defaults.set(true, forKey: ThumbnailSizePreference.legacyIsLargeKey)
            ThumbnailSizePreference.migrateLegacyValueIfNeeded(in: defaults)
            let first = defaults.object(forKey: GlobalSettingsKeys.thumbnailSize) as? Int

            ThumbnailSizePreference.migrateLegacyValueIfNeeded(in: defaults)
            #expect(defaults.object(forKey: GlobalSettingsKeys.thumbnailSize) as? Int == first)
        }
    }
}
