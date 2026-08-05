//
//  CommentPersistenceTests.swift
//  KataGo AnytimeTests
//
//  The one place a comment pane's text becomes part of the record. Every
//  reader of GameRecord.comments — the watch widget included — depends on
//  this being called, so it is worth pinning on its own.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct CommentPersistenceTests {
    // `config:` has no default on GameRecord's initializer, and `comments:`
    // follows it in the declaration order — the same shape GameEntityQueryTests
    // uses.
    @Test func storesTheTextAtTheGivenIndex() {
        let record = GameRecord(config: Config(), comments: [:])
        CommentPersistence.store("A quiet opening.", at: 7, in: record)
        #expect(record.comments?[7] == "A quiet opening.")
    }

    @Test func createsTheDictionaryWhenItIsNil() {
        // An imported or CloudKit-arrived record can carry a nil dictionary;
        // storing into it must not silently drop the text.
        let record = GameRecord(config: Config(), comments: nil)
        CommentPersistence.store("First note", at: 0, in: record)
        #expect(record.comments?[0] == "First note")
    }

    @Test func overwritesAnExistingCommentAtThatIndex() {
        let record = GameRecord(config: Config(), comments: [3: "old"])
        CommentPersistence.store("new", at: 3, in: record)
        #expect(record.comments?[3] == "new")
        #expect(record.comments?.count == 1)
    }

    @Test func leavesOtherIndicesAlone() {
        let record = GameRecord(config: Config(), comments: [1: "one", 2: "two"])
        CommentPersistence.store("three", at: 3, in: record)
        #expect(record.comments?[1] == "one")
        #expect(record.comments?[2] == "two")
        #expect(record.comments?[3] == "three")
    }

    @Test func storesCjkTextUnchanged() {
        // Imported SGFs routinely carry non-Latin commentary; nothing here may
        // normalize, filter, or transcode it.
        let record = GameRecord(config: Config(), comments: [:])
        let text = "\u{5B9A}\u{77F3}\u{306E}\u{5909}\u{5316}"
        CommentPersistence.store(text, at: 0, in: record)
        #expect(record.comments?[0] == text)
    }

    @Test func blankTextNeverCreatesAnEntryThatDidNotExist() {
        // The new typing-debounce flush also fires on the pane's FIRST
        // appearance, when the text is "". Creating an entry there would put an
        // empty string at that index — and `GameEntity.firstComment` reads
        // `comments?[0]` directly, so a blank at move 0 would become the iOS
        // widget picker's subtitle instead of falling through to the earliest
        // real comment.
        let record = GameRecord(config: Config(), comments: [:])
        CommentPersistence.store("", at: 0, in: record)
        #expect(record.comments?[0] == nil)
        CommentPersistence.store("   \n", at: 5, in: record)
        #expect(record.comments?[5] == nil)
    }

    @Test func clearingAnExistingCommentStillPersists() {
        // The other half of the rule: emptying a comment the user had written
        // must be saved, or the pane would silently refuse to delete text.
        let record = GameRecord(config: Config(), comments: [3: "old"])
        CommentPersistence.store("", at: 3, in: record)
        #expect(record.comments?[3] == "")
    }
}
