//
//  GobanStateReviewLockTests.swift
//  KataGo iOSTests
//
//  Pins the fix for the build-291 data-corruption bug: a never-played synced
//  game has sgf == GameRecord.defaultSgf, which loadGame's editingAfterLoad
//  unlocks (isEditing = true) — and the EDITING path of the play functions
//  truncates the record (clearData) and lets printsgf replies overwrite the
//  synced SGF. With forcesBranchOnPlay set (the tvOS review screen), the
//  editing path must NEVER run: picks always capture a branch and the record
//  stays byte-identical. With the flag clear, the iOS editing behavior is
//  unchanged (regression pin).
//

import Testing
@testable import KataGoUICore

@MainActor
struct GobanStateReviewLockTests {

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
            // The corruption trigger: a synced record whose SGF is byte-equal
            // to the default new-game SGF, with per-move data to protect.
            record = GameRecord(sgf: GameRecord.defaultSgf,
                                currentIndex: 0,
                                config: Config(),
                                name: "Empty synced game",
                                scoreLeads: [0: 1.5],
                                blackStones: [0: ""],
                                whiteStones: [0: ""])
            board.width = 19
            board.height = 19
            // What loadGame does to such a game: unlocks it.
            state.isEditing = GobanState.editingAfterLoad(sgf: record.sgf,
                                                          unlockRequested: false)
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
    }

    @Test("defaultSgf still unlocks on load (iOS new-game pin)")
    func editingAfterLoadUnchanged() {
        #expect(GobanState.editingAfterLoad(sgf: GameRecord.defaultSgf,
                                            unlockRequested: false) == true)
        #expect(GobanState.editingAfterLoad(sgf: "(;FF[4]GM[1]SZ[19];B[pd])",
                                            unlockRequested: false) == false)
    }

    @Test("Review (forcesBranchOnPlay): an unlocked defaultSgf game still branches, record untouched")
    func reviewPickBranchesInsteadOfEditing() {
        let f = Fixture(forcesBranch: true)
        #expect(f.state.isEditing == true)  // the trigger condition holds
        let sgfBefore = f.record.sgf
        let leadsBefore = f.record.scoreLeads

        f.playPending()

        // Branch captured; the editing path (clearData + record writes) never ran.
        #expect(f.state.isBranchActive == true)
        #expect(f.state.branchSgf == sgfBefore)
        #expect(f.record.sgf == sgfBefore)
        #expect(f.record.currentIndex == 0)
        #expect(f.record.scoreLeads == leadsBefore)
    }

    @Test("Review: playAIMove on an unlocked game also branches, record untouched")
    func reviewAIMoveBranchesInsteadOfEditing() {
        let f = Fixture(forcesBranch: true)
        let sgfBefore = f.record.sgf

        f.state.playAIMove(aiMove: "Q16", gameRecord: f.record, turn: "b",
                           analysis: f.analysis, board: f.board, stones: f.stones,
                           messageList: f.messageList, player: f.player,
                           audioModel: f.audioModel)

        #expect(f.state.isBranchActive == true)
        #expect(f.record.sgf == sgfBefore)
        #expect(f.record.currentIndex == 0)
        // One AI stone landed, whichever path it took.
        #expect(f.state.aiMoveLandingGeneration == 1)
    }

    @Test("iOS (flag clear): the editing path is unchanged")
    func editingPathUnchangedWithoutFlag() {
        let f = Fixture(forcesBranch: false)
        #expect(f.state.isEditing == true)

        f.playPending()

        // Editing path ran: no branch, per-move data truncated to <= 0
        // (clearData keeps index 0), and the play command went out.
        #expect(f.state.isBranchActive == false)
        #expect(f.messageList.messages.contains { $0.text.hasSuffix("play b Q16") })
        #expect(f.messageList.messages.contains { $0.text.hasSuffix("printsgf") })
    }
}
