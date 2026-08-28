//
//  GobanStateLoadGameFeedTests.swift
//  KataGo iOSTests
//
//  Opening a game FEEDS the engine: board size, rules, setup stones and one
//  `play` per recorded move up to the position the board is showing. No
//  `loadsgf` writes a temp file, no undo loop walks back from the tip, and no
//  `printsgf` echo reads the game back out (which is what used to reset the
//  cursor and re-sort the library on every launch).
//

import Testing
import Foundation
import SwiftData
@testable import KataGoUICore

@MainActor
struct GobanStateLoadGameFeedTests {

    private static let fourMoves =
        "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp];B[pp];W[dd])"

    private struct Fixture {
        let session: GameSession
        let engine: RecordingQueueEngine
        let container: ModelContainer
    }

    private func makeFixture() throws -> Fixture {
        let container = try ModelContainer(for: SharedModelContainer.schema,
                                           configurations: SharedModelContainer.inMemoryConfig())
        let engine = RecordingQueueEngine(live: [])
        let session = GameSession.accepting()
        session.useEngine(engine)
        return Fixture(session: session, engine: engine, container: container)
    }

    private func load(_ record: GameRecord, in fixture: Fixture) {
        fixture.container.mainContext.insert(record)
        fixture.session.gobanState.loadGame(gameRecord: record,
                                            player: fixture.session.player,
                                            bookLookup: fixture.session.bookLookup,
                                            messageList: fixture.session.messageList,
                                            board: fixture.session.board,
                                            stones: fixture.session.stones,
                                            analysis: fixture.session.analysis,
                                            projector: fixture.session.recordPosition)
    }

    private func plays(_ fixture: Fixture) -> [String] {
        fixture.engine.sentCommands.filter { $0.hasPrefix("play ") }
    }

    // MARK: - The feed itself

    @Test("The engine is fed up to the SAVED index, not to the tip")
    func feedsToTheSavedIndex() throws {
        let fixture = try makeFixture()
        load(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 2), in: fixture)

        #expect(plays(fixture) == ["play b Q16", "play w D4"])
        #expect(!fixture.engine.sentCommands.contains("undo"))
    }

    @Test("A cursor saved past the record's moves is clamped to the tip")
    func clampsAnOutOfRangeCursor() throws {
        let fixture = try makeFixture()
        let record = GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 99)
        load(record, in: fixture)

        #expect(record.currentIndex == 4)
        #expect(plays(fixture).count == 4)
    }

    @Test("Opening a game writes nothing to the engine's SGF machinery")
    func noLoadsgfAndNoPrintsgfEcho() throws {
        let fixture = try makeFixture()
        load(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 4), in: fixture)

        #expect(!fixture.engine.sentCommands.contains { $0.hasPrefix("loadsgf") })
        #expect(!fixture.engine.sentCommands.contains("printsgf"))
        // …and it still ends with the acknowledgement the board waits on.
        #expect(fixture.engine.sentCommands.last == "showboard")
        #expect(fixture.session.gobanState.showBoardCount == 1)
        #expect(fixture.session.stones.isReady == false)
    }

    @Test("The opening bundle resets the engine before it states the rules")
    func openingBundleResetsFirst() throws {
        let fixture = try makeFixture()
        load(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 0), in: fixture)

        let sent = fixture.engine.sentCommands
        #expect(sent.first == "rectangular_boardsize 19 19")
        #expect(sent.dropFirst().first == "clear_board")
        #expect(sent.contains { $0.hasPrefix("komi ") })
        #expect(sent.contains("kata-set-rule friendlyPassOk false"))
    }

    // MARK: - Board size

    @Test("A size change is on the board before the engine hears about it")
    func sizeChangeProjectsBeforeTheFeed() throws {
        let fixture = try makeFixture()
        load(GameRecord.createGameRecord(sgf: "(;FF[4]GM[1]SZ[9]KM[7.5]RU[japanese];B[ee])",
                                         currentIndex: 1), in: fixture)

        #expect(fixture.session.board.width == 9)
        #expect(fixture.session.board.height == 9)
        #expect(fixture.engine.sentCommands.first == "rectangular_boardsize 9 9")
        #expect(plays(fixture) == ["play b E5"])
    }

    @Test("A board the engine cannot serve is drawn but never fed")
    func anOversizedBoardIsDrawnButNotFed() throws {
        let fixture = try makeFixture()
        fixture.session.gobanState.engineMaxBoardLength = 13
        load(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 2), in: fixture)

        // The board still shows the record position…
        #expect(fixture.session.board.width == 19)
        #expect(fixture.session.stones.blackPoints.count == 1)
        // …and the engine is told nothing at all.
        #expect(fixture.engine.sentCommands.isEmpty)
    }

    @Test("Nothing is sent while the engine is not accepting commands")
    func nothingIsFedWhileTheEngineIsUnavailable() throws {
        let fixture = try makeFixture()
        fixture.session.messageList.isAcceptingCommands = false
        load(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 2), in: fixture)

        #expect(fixture.engine.sentCommands.isEmpty)
        #expect(fixture.session.stones.whitePoints.count == 1)   // the board still drew
    }

    // MARK: - Pass accounting

    @Test("The pass counter is seeded from the position being opened")
    func passCountIsSeededFromTheRecord() throws {
        let fixture = try makeFixture()
        fixture.session.gobanState.passCount = 1   // left over from another game
        load(GameRecord.createGameRecord(
            sgf: "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[];B[])",
            currentIndex: 3), in: fixture)

        #expect(fixture.session.gobanState.passCount == 2)
        #expect(plays(fixture) == ["play b Q16", "play w pass", "play b pass"])
    }

    @Test("Opening mid-game seeds the count for THAT position, not the tip")
    func passCountFollowsTheCursor() throws {
        let fixture = try makeFixture()
        fixture.session.gobanState.passCount = 2
        load(GameRecord.createGameRecord(
            sgf: "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[];B[])",
            currentIndex: 1), in: fixture)

        #expect(fixture.session.gobanState.passCount == 0)
    }

    @Test("An unreadable record resets the count instead of keeping the old one")
    func passCountResetsForAnUnreadableRecord() throws {
        let fixture = try makeFixture()
        fixture.session.gobanState.passCount = 2
        load(GameRecord.createGameRecord(sgf: "this is not an SGF", currentIndex: 0), in: fixture)

        #expect(fixture.session.gobanState.passCount == 0)
        #expect(fixture.engine.sentCommands.isEmpty)
    }

    // MARK: - Branches and switching

    @Test("Reloading over an active branch feeds the mainline divergence")
    func branchReloadFeedsTheDivergence() throws {
        let fixture = try makeFixture()
        let record = GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 2)
        fixture.container.mainContext.insert(record)
        // A branch: the record's cursor stays frozen at the divergence while
        // the branch line runs ahead of it.
        fixture.session.gobanState.branchSgf =
            "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp];B[cc];W[qq])"
        fixture.session.gobanState.branchIndex = 4

        load(record, in: fixture)

        #expect(fixture.session.gobanState.isBranchActive == false)
        #expect(plays(fixture) == ["play b Q16", "play w D4"])
    }

    @Test("Switching between two games with identical SGF still publishes")
    func identicalSgfRecordsBothPublish() throws {
        let fixture = try makeFixture()
        let first = GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 2, name: "First")
        let second = GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 2, name: "Second")

        load(first, in: fixture)
        let afterFirst = fixture.session.recordPosition.currentKey
        let generationAfterFirst = fixture.session.stones.positionGeneration

        load(second, in: fixture)
        let afterSecond = fixture.session.recordPosition.currentKey

        #expect(afterFirst != afterSecond)   // the record id is part of the key
        #expect(fixture.session.stones.positionGeneration != generationAfterFirst)
    }

    // MARK: - Refusals

    @Test("A move the replay refused is never fed to the engine")
    func aRefusedMoveIsNeverFed() throws {
        let fixture = try makeFixture()
        // The third move repeats Q16, which the board refuses as occupied —
        // exactly as the engine's own `play` would.
        load(GameRecord.createGameRecord(
            sgf: "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp];B[pd];W[pp])",
            currentIndex: 4), in: fixture)

        #expect(plays(fixture) == ["play b Q16", "play w D4", "play w Q4"])
    }

    @Test("A handicap record is set up before its moves are played")
    func handicapSetupPrecedesTheMoves() throws {
        let fixture = try makeFixture()
        load(GameRecord.createGameRecord(
            sgf: "(;FF[4]GM[1]SZ[19]KM[0.5]RU[japanese]AB[dd][pp][dp];W[pd])",
            currentIndex: 1), in: fixture)

        let sent = fixture.engine.sentCommands
        let setup = try #require(sent.firstIndex { $0.hasPrefix("set_free_handicap ") })
        let firstPlay = try #require(sent.firstIndex { $0.hasPrefix("play ") })
        #expect(setup < firstPlay)
        #expect(plays(fixture) == ["play w Q16"])
    }

    // MARK: - Rule label reconciliation

    // `createGameRecord` now derives `Config.rule` from RU[] at creation, but
    // records created before that fix — including CloudKit records synced from
    // older builds — still carry a stale default label. The load-time
    // reconcile is what heals them, so it stays covered here with staleness
    // manufactured explicitly.

    @Test("A legacy record's stale Tromp-Taylor label heals on load")
    func importedJapaneseRecordHealsItsRuleLabel() throws {
        let fixture = try makeFixture()
        let record = GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 0)
        // Manufacture the pre-fix state: the factory derives japanese now, so
        // a legacy record is simulated by writing the default index back —
        // exactly what every record created before the factory fix carries.
        record.concreteConfig.rule = Config.defaultRule

        load(record, in: fixture)

        #expect(record.concreteConfig.rule == NewGameRuleset.japanese.configRuleIndex)
        // The exact read TVPlayScreen/TVReviewScreen `ruleText` makes:
        #expect(NewGameRuleset.preset(fromConfigRule: record.concreteConfig.rule)?
            .displayName == "Japanese")
    }

    @Test("A legitimate Korean label survives loading engine-identical components")
    func koreanLabelIsPreservedOverJapaneseComponents() throws {
        let fixture = try makeFixture()
        let record = GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 0)
        record.concreteConfig.rule = NewGameRuleset.korean.configRuleIndex

        load(record, in: fixture)

        #expect(record.concreteConfig.rule == NewGameRuleset.korean.configRuleIndex)
    }

    @Test("Components matching no preset persist the Custom sentinel")
    func customComponentsPersistTheCustomSentinel() throws {
        let fixture = try makeFixture()
        // Area scoring + seki tax + positional ko + legal suicide matches no
        // named preset (compact RU[] form, which the engine parses).
        let record = GameRecord.createGameRecord(
            sgf: "(;FF[4]GM[1]SZ[19]KM[6.5]RU[koPOSITIONALscoreAREAtaxSEKIsui1];B[pd])",
            currentIndex: 1)

        load(record, in: fixture)

        // The komi proves the RU[] actually parsed (a swallowed parse failure
        // falls back to an all-default rule set with komi 7).
        #expect(record.concreteConfig.komi == 6.5)
        #expect(record.concreteConfig.rule == Config.customRule)
    }

    @Test("A record whose label already fits is not rewritten")
    func matchingLabelIsLeftAlone() throws {
        let fixture = try makeFixture()
        let record = GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 0)
        record.concreteConfig.rule = NewGameRuleset.japanese.configRuleIndex

        load(record, in: fixture)

        #expect(record.concreteConfig.rule == NewGameRuleset.japanese.configRuleIndex)
    }
}
