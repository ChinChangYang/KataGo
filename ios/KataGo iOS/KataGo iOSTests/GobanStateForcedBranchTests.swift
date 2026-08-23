//
//  GobanStateForcedBranchTests.swift
//  KataGo iOSTests
//
//  Pins the `forcesBranchOnPlay` flag: with it set, a locked-game play that
//  matches the next recorded move still starts a branch (tvOS picks must never
//  write a synced record — the mainline shortcut would advance its persisted
//  `currentIndex`); with it clear, the mainline shortcut is byte-identical to
//  before the flag existed (the iOS/macOS regression pin).
//
//  The MessageList is standalone (no owning GameSession), so appendAndSend
//  only appends — the commands each path emits are inspectable and nothing
//  reaches an engine.
//

import Testing
@testable import KataGoUICore

@MainActor
struct GobanStateForcedBranchTests {

    /// One recorded move (B Q16); currentIndex 0 so that exact move is the
    /// "next recorded move" the mainline shortcut looks for.
    private static let sgf =
        "(;FF[4]GM[1]SZ[19]KM[7.5]RU[koSIMPLEscoreAREAtaxNONEsui0whbN];B[pd])"

    @MainActor
    private struct Fixture {
        let state = GobanState()
        let record: GameRecord
        let analysis = Analysis()
        let board = BoardSize()
        let stones = Stones()
        let messageList = MessageList.accepting()
        let player = Turn()
        let audioModel = AudioModel()

        init(forcesBranch: Bool) {
            record = GameRecord(sgf: GobanStateForcedBranchTests.sgf,
                                currentIndex: 0,
                                config: Config(),
                                name: "Synced game")
            board.width = 19
            board.height = 19
            state.isEditing = false
            state.forcesBranchOnPlay = forcesBranch
            state.pendingMoveTurn = "b"
            state.pendingMoveVertex = "Q16"
            player.nextColorForPlayCommand = .black
        }

        func playPending() {
            state.playPendingHumanMove(gameRecord: record, analysis: analysis,
                                       board: board, stones: stones,
                                       messageList: messageList, player: player,
                                       audioModel: audioModel)
        }

        /// Message texts carry a "> " display prefix — match on the suffix.
        func sent(_ command: String) -> Bool {
            messageList.messages.contains { $0.text.hasSuffix(command) }
        }
    }

    @Test("Forced: a mainline-matching pick branches and never touches the record")
    func forcedBranchKeepsRecordUntouched() {
        let f = Fixture(forcesBranch: true)
        let sgfBefore = f.record.sgf

        f.playPending()

        #expect(f.state.isBranchActive == true)
        #expect(f.state.branchSgf == sgfBefore)
        #expect(f.state.branchIndex == 0)
        // The two writes the mainline shortcut would have made:
        #expect(f.record.currentIndex == 0)
        #expect(f.record.sgf == sgfBefore)
        // The branch path plays and requests the branch SGF.
        #expect(f.sent("play b Q16"))
        #expect(f.sent("printsgf"))
        #expect(f.state.pendingMoveTurn == nil)
    }

    @Test("Default: a mainline-matching pick steps the mainline (iOS pin)")
    func defaultTakesMainlineShortcut() {
        let f = Fixture(forcesBranch: false)

        f.playPending()

        #expect(f.state.isBranchActive == false)
        #expect(f.record.currentIndex == 1)
        #expect(f.sent("play b Q16"))
        // The mainline step never rewrites the SGF, so it sends no printsgf.
        #expect(!f.sent("printsgf"))
    }

    @Test("Forced: playAIMove also branches instead of mainline-stepping")
    func forcedBranchAppliesToAIMoves() {
        let f = Fixture(forcesBranch: true)
        let sgfBefore = f.record.sgf

        f.state.playAIMove(aiMove: "Q16", gameRecord: f.record, turn: "b",
                           analysis: f.analysis, board: f.board, stones: f.stones,
                           messageList: f.messageList, player: f.player,
                           audioModel: f.audioModel)

        #expect(f.state.isBranchActive == true)
        #expect(f.record.currentIndex == 0)
        #expect(f.record.sgf == sgfBefore)
    }

    @Test("A fresh GobanState never forces a branch (iOS/macOS default)")
    func defaultsToFalse() {
        #expect(GobanState().forcesBranchOnPlay == false)
    }
}
