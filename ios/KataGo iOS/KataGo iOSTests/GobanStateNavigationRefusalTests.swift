//
//  GobanStateNavigationRefusalTests.swift
//  KataGo iOSTests
//
//  The engine is fed move by move, and a move the replay refused was never
//  sent. Navigation has to honour that: the cursor still steps over the
//  refused index (the board counted it), but there is no `play` to repeat and
//  no `undo` to take it back. Get this wrong and every later position is one
//  move out of step between board and engine.
//

import Testing
import Foundation
import GoRulesKit
import SwiftData
@testable import KataGoUICore

@MainActor
struct GobanStateNavigationRefusalTests {

    /// Move 2 (index 2) repeats Q16 onto an occupied point. `SgfReplay` refuses
    /// it — the same refusal `boardhistory.cpp isLegalTolerant` makes — so the
    /// engine is never given it.
    private static let refusing =
        "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp];B[pd];W[pp])"

    private struct Fixture {
        let session: GameSession
        let engine: RecordingQueueEngine
        let record: GameRecord
        let container: ModelContainer
    }

    private func makeFixture(currentIndex: Int, sgf: String = refusing) throws -> Fixture {
        let container = try ModelContainer(for: SharedModelContainer.schema,
                                           configurations: SharedModelContainer.inMemoryConfig())
        let engine = RecordingQueueEngine(live: [])
        let session = GameSession.accepting()
        session.useEngine(engine)
        let record = GameRecord.createGameRecord(sgf: sgf, currentIndex: currentIndex)
        container.mainContext.insert(record)
        return Fixture(session: session, engine: engine, record: record, container: container)
    }

    private func moveCommands(_ fixture: Fixture) -> [String] {
        fixture.engine.sentCommands.filter { $0.hasPrefix("play ") || $0 == "undo" }
    }

    // MARK: - Forward

    @Test("Forward navigation steps over a refused move without playing it")
    func forwardSkipsTheRefusedMove() throws {
        let fixture = try makeFixture(currentIndex: 2)
        fixture.session.gobanState.forwardMoves(limit: nil,
                                                gameRecord: fixture.record,
                                                board: fixture.session.board,
                                                messageList: fixture.session.messageList,
                                                player: fixture.session.player,
                                                audioModel: nil,
                                                stones: fixture.session.stones)

        // Both indices are consumed — the cursor reaches the tip…
        #expect(fixture.record.currentIndex == 4)
        // …but only the accepted one is played.
        #expect(moveCommands(fixture) == ["play w Q4"])
    }

    @Test("A one-step forward onto a refused move still advances the cursor")
    func oneStepOntoARefusedMoveAdvances() throws {
        let fixture = try makeFixture(currentIndex: 2)
        fixture.session.gobanState.forwardMoves(limit: 1,
                                                gameRecord: fixture.record,
                                                board: fixture.session.board,
                                                messageList: fixture.session.messageList,
                                                player: fixture.session.player,
                                                audioModel: nil,
                                                stones: fixture.session.stones)

        #expect(fixture.record.currentIndex == 3)
        #expect(moveCommands(fixture).isEmpty)
    }

    @Test("A refused move does not flip the side to move")
    func aRefusedMoveLeavesTheTurnAlone() throws {
        let fixture = try makeFixture(currentIndex: 2)
        fixture.session.player.nextColorForPlayCommand = .black
        fixture.session.gobanState.forwardMoves(limit: 1,
                                                gameRecord: fixture.record,
                                                board: fixture.session.board,
                                                messageList: fixture.session.messageList,
                                                player: fixture.session.player,
                                                audioModel: nil,
                                                stones: fixture.session.stones)

        #expect(fixture.session.player.nextColorForPlayCommand == .black)
    }

    // MARK: - Backward

    @Test("Rewinding the whole game undoes only the moves the engine was fed")
    func backwardUndoesOnlyAcceptedMoves() throws {
        let fixture = try makeFixture(currentIndex: 4)
        fixture.session.gobanState.backwardMoves(limit: nil,
                                                 gameRecord: fixture.record,
                                                 messageList: fixture.session.messageList,
                                                 player: fixture.session.player,
                                                 stones: fixture.session.stones)

        #expect(fixture.record.currentIndex == 0)
        // Four recorded moves, three undos.
        #expect(moveCommands(fixture) == ["undo", "undo", "undo"])
    }

    @Test("Stepping back over the refused index sends no undo")
    func steppingBackOverARefusalSendsNoUndo() throws {
        let fixture = try makeFixture(currentIndex: 3)
        fixture.session.gobanState.backwardMoves(limit: 1,
                                                 gameRecord: fixture.record,
                                                 messageList: fixture.session.messageList,
                                                 player: fixture.session.player,
                                                 stones: fixture.session.stones)

        #expect(fixture.record.currentIndex == 2)
        #expect(moveCommands(fixture).isEmpty)
    }

    @Test("The backward-frame gate reports whether the engine holds that move")
    func stepBackwardFedReportsTheRefusal() throws {
        let fixture = try makeFixture(currentIndex: 3)
        // The move behind index 3 is the refused one.
        #expect(fixture.session.gobanState.isStepBackwardFedToEngine(gameRecord: fixture.record) == false)

        fixture.record.currentIndex = 2
        #expect(fixture.session.gobanState.isStepBackwardFedToEngine(gameRecord: fixture.record) == true)

        fixture.record.currentIndex = 0
        #expect(fixture.session.gobanState.isStepBackwardFedToEngine(gameRecord: fixture.record) == false)
    }

    // MARK: - Mainline play

    @Test("A mainline step over a refused index moves the cursor without playing")
    func mainlineStepSkipsARefusedIndex() throws {
        let fixture = try makeFixture(currentIndex: 2)
        fixture.session.gobanState.playMainlineStep(turn: "b",
                                                    move: "Q16",
                                                    gameRecord: fixture.record,
                                                    stones: fixture.session.stones,
                                                    messageList: fixture.session.messageList,
                                                    player: fixture.session.player,
                                                    audioModel: AudioModel())

        #expect(fixture.record.currentIndex == 3)
        #expect(!fixture.engine.sentCommands.contains { $0.hasPrefix("play ") })
        #expect(fixture.engine.sentCommands.contains("showboard"))
    }

    @Test("A mainline step over an accepted index plays it as before")
    func mainlineStepPlaysAnAcceptedIndex() throws {
        let fixture = try makeFixture(currentIndex: 1)
        fixture.session.gobanState.playMainlineStep(turn: "w",
                                                    move: "D4",
                                                    gameRecord: fixture.record,
                                                    stones: fixture.session.stones,
                                                    messageList: fixture.session.messageList,
                                                    player: fixture.session.player,
                                                    audioModel: AudioModel())

        #expect(fixture.record.currentIndex == 2)
        #expect(fixture.engine.sentCommands.contains("play w D4"))
    }

    // MARK: - The latent forward loop

    // MARK: - One predicate governs the send and the bookkeeping

    /// `BoardSize` used to decide the played vertex while the refusal
    /// bookkeeping came from the replay — two predicates for one question. A
    /// `BoardSize` lagging the record (mid-switch, or a stale projection) then
    /// silenced the `play` for an index the replay had accepted, and the
    /// backward walk still counted that index as fed: one `undo` too many, and
    /// permanent board/engine skew. The vertex now comes from the replay, so
    /// the board's size cannot silence anything.
    ///
    /// The same test also pins loop TERMINATION: the cursor advances before any
    /// decision about sending, so no index can be re-read forever (the original
    /// `if let move = …` shape hung the app on a vertex it could not name).
    @Test("A lagging board size can neither silence the feed nor hang the walk")
    func aLaggingBoardSizeDoesNotSilenceTheFeed() throws {
        let fixture = try makeFixture(
            currentIndex: 0,
            sgf: "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp];B[pp])")
        // Column Q does not exist on a 9-wide board — the old code read the
        // vertex from here and dropped every play.
        fixture.session.board.width = 9
        fixture.session.board.height = 9

        fixture.session.gobanState.forwardMoves(limit: nil,
                                                gameRecord: fixture.record,
                                                board: fixture.session.board,
                                                messageList: fixture.session.messageList,
                                                player: fixture.session.player,
                                                audioModel: nil,
                                                stones: fixture.session.stones)

        #expect(fixture.record.currentIndex == 3)
        #expect(moveCommands(fixture) == ["play b Q16", "play w D4", "play b Q4"])
    }

    /// The invariant the whole feed rests on: however many `play`s went out
    /// walking forward, exactly that many `undo`s come back walking back. A
    /// record with a refusal in the middle is the case that breaks a naive
    /// index-difference count.
    @Test("Forward and backward agree on which indices the engine was given")
    func forwardAndBackwardAgreeOnWhichIndicesAreFed() throws {
        let fixture = try makeFixture(currentIndex: 0)
        let state = fixture.session.gobanState

        state.forwardMoves(limit: nil,
                           gameRecord: fixture.record,
                           board: fixture.session.board,
                           messageList: fixture.session.messageList,
                           player: fixture.session.player,
                           audioModel: nil,
                           stones: fixture.session.stones)
        let plays = fixture.engine.sentCommands.filter { $0.hasPrefix("play ") }.count
        #expect(fixture.record.currentIndex == 4)
        #expect(plays == 3)          // four recorded moves, one refused

        state.backwardMoves(limit: nil,
                            gameRecord: fixture.record,
                            messageList: fixture.session.messageList,
                            player: fixture.session.player,
                            stones: fixture.session.stones)
        let undos = fixture.engine.sentCommands.filter { $0 == "undo" }.count

        #expect(fixture.record.currentIndex == 0)
        #expect(undos == plays)
        // …and the turn is back where it started, because each side toggled the
        // same number of times.
        #expect(fixture.session.player.nextColorForPlayCommand == .black)
    }

    /// The opening feed and a forward step must spell the same move the same
    /// way — same colour case, same vertex. They share
    /// `EngineFeed.playArguments`, so this is structural rather than a
    /// convention, and this test is what keeps it that way.
    @Test("The opening feed and forward navigation emit identical play commands")
    func theFeedAndForwardNavigationSpellTheSameMove() throws {
        let sgf = Self.refusing
        let fixture = try makeFixture(currentIndex: 0, sgf: sgf)
        var replay = try #require(RecordReplayBuilder.replay(from: SgfOperations(sgf: sgf)))

        for index in 0..<4 {
            fixture.session.gobanState.forwardMoves(limit: 1,
                                                    gameRecord: fixture.record,
                                                    board: fixture.session.board,
                                                    messageList: fixture.session.messageList,
                                                    player: fixture.session.player,
                                                    audioModel: nil,
                                                    stones: fixture.session.stones)
            let navigation = fixture.engine.sentCommands.filter { $0.hasPrefix("play ") }
            let feed = EngineFeed.forwardCommands(replay: &replay, from: 0, to: index + 1)
            #expect(navigation == feed)
        }
    }
}
