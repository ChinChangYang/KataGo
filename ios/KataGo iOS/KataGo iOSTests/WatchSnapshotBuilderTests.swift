import Testing
import Foundation
@testable import KataGoUICore
import KataGoGameStore

@MainActor
struct WatchSnapshotBuilderTests {
    @Test func buildsSnapshotFromSessionState() {
        let session = GameSession()
        session.board.width = 19
        session.board.height = 19
        // BoardPoint(x:y:)'s raw y does not round-trip through BoardPoint.toString
        // the way a naive "0-based row from top" reading suggests (toString feeds
        // y+1 straight in as the yLabel, with no height flip) — use the GTP-string
        // initializer so the vertex is unambiguously "Q16" regardless of the
        // internal (x,y) convention. Public at KataGoModel.swift:124.
        session.stones.blackPoints = [BoardPoint(move: "Q16", width: 19, height: 19)!]
        session.stones.whitePoints = []
        session.player.nextColorForPlayCommand = .white
        session.gobanState.analysisStatus = .run
        session.rootWinrate.black = 0.61
        session.rootScore.black = 2.5
        session.analysis.nextColorForAnalysis = .white
        session.analysis.info = [
            BoardPoint(x: 2, y: 3): AnalysisInfo(visits: 500, winrate: 0.48,
                                                 scoreLead: -1.2, utilityLcb: 0.1,
                                                 pv: ["C16", "D4", "Q3", "R4", "C3", "D3", "E3", "F3"]),
            BoardPoint(x: 3, y: 15): AnalysisInfo(visits: 100, winrate: 0.44,
                                                  scoreLead: -2.0, utilityLcb: 0.0),
        ]

        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let snapshot = WatchSnapshotBuilder.makeSnapshot(session: session, now: now)

        #expect(snapshot.boardWidth == 19 && snapshot.boardHeight == 19)
        #expect(snapshot.blackStones == ["Q16"])
        #expect(snapshot.whiteStones.isEmpty)
        #expect(snapshot.toMove == "W")
        #expect(snapshot.moveNumber == 1)
        #expect(snapshot.analysisRunning)
        #expect(snapshot.analysisPaused == false)
        #expect(snapshot.rootWinrateBlack == 0.61)
        #expect(snapshot.rootScoreLeadBlack == 2.5)
        #expect(snapshot.candidates.count == 2)
        #expect(snapshot.candidates[0].visits == 500)      // strongest first
        #expect(snapshot.candidates[0].pv.count == 6)      // PV capped at 6
        #expect(snapshot.hostTimestamp == now)
    }

    @Test func staleAnalysisColorSuppressesCandidates() {
        // Analysis is running and has info, but its perspective (nextColorForAnalysis)
        // still reflects the position BEFORE the latest move relayed to
        // nextColorForPlayCommand — the one-tick lag window from Finding 5.
        // Candidates must be suppressed rather than paired with the new index.
        let session = GameSession()
        session.board.width = 19
        session.board.height = 19
        session.stones.blackPoints = [BoardPoint(move: "Q16", width: 19, height: 19)!]
        session.player.nextColorForPlayCommand = .white
        session.gobanState.analysisStatus = .run
        session.analysis.nextColorForAnalysis = .black   // opposite of nextColorForPlayCommand
        session.analysis.info = [
            BoardPoint(x: 2, y: 3): AnalysisInfo(visits: 500, winrate: 0.48,
                                                 scoreLead: -1.2, utilityLcb: 0.1,
                                                 pv: ["C16", "D4"]),
        ]

        let snapshot = WatchSnapshotBuilder.makeSnapshot(session: session, now: .now)

        #expect(snapshot.analysisRunning)
        #expect(snapshot.candidates.isEmpty)
    }

    @Test func pausedAnalysisAndPassesAreRepresented() {
        let session = GameSession()
        session.board.width = 9; session.board.height = 9
        session.gobanState.analysisStatus = .pause
        session.stones.blackStonesCaptured = 2
        let snapshot = WatchSnapshotBuilder.makeSnapshot(session: session, now: .now)
        #expect(!snapshot.analysisRunning)
        #expect(snapshot.analysisPaused == true)
        #expect(snapshot.candidates.isEmpty)               // no analysis data collected yet
        #expect(snapshot.moveNumber == 2)                  // captured stones still count as played
    }

    @Test func pausedAnalysisKeepsCandidates() {
        // Pausing retains the last (position-fresh) analysis on the phone
        // board; the watch mirror must keep showing it too instead of
        // reading as "Analysis off".
        let session = GameSession()
        session.board.width = 19
        session.board.height = 19
        session.player.nextColorForPlayCommand = .white
        session.gobanState.analysisStatus = .pause
        session.analysis.nextColorForAnalysis = .white     // matches the turn
        session.analysis.info = [
            BoardPoint(x: 2, y: 3): AnalysisInfo(visits: 500, winrate: 0.48,
                                                 scoreLead: -1.2, utilityLcb: 0.1,
                                                 pv: ["C16", "D4"]),
        ]

        let snapshot = WatchSnapshotBuilder.makeSnapshot(session: session, now: .now)

        #expect(!snapshot.analysisRunning)
        #expect(snapshot.analysisPaused == true)
        #expect(snapshot.candidates.count == 1)
        #expect(snapshot.candidates[0].visits == 500)
    }

    @Test func autoPlaySuppressesPausedCandidates() {
        // Auto-play runs under `.pause` while streaming analysis for every
        // move; the phone hides that churn (AnalysisView's !isAutoPlaying
        // gate) and the snapshot must too.
        let session = GameSession()
        session.board.width = 19
        session.board.height = 19
        session.player.nextColorForPlayCommand = .white
        session.gobanState.analysisStatus = .pause
        session.gobanState.isAutoPlaying = true
        session.analysis.nextColorForAnalysis = .white
        session.analysis.info = [
            BoardPoint(x: 2, y: 3): AnalysisInfo(visits: 500, winrate: 0.48,
                                                 scoreLead: -1.2, utilityLcb: 0.1),
        ]

        let snapshot = WatchSnapshotBuilder.makeSnapshot(session: session, now: .now)

        #expect(!snapshot.analysisRunning)
        #expect(snapshot.analysisPaused == false)
        #expect(snapshot.candidates.isEmpty)
    }

    @Test func clearedAnalysisIsNeitherRunningNorPaused() {
        let session = GameSession()
        session.board.width = 9; session.board.height = 9
        session.gobanState.analysisStatus = .clear
        let snapshot = WatchSnapshotBuilder.makeSnapshot(session: session, now: .now)
        #expect(!snapshot.analysisRunning)
        #expect(snapshot.analysisPaused == false)
        #expect(snapshot.candidates.isEmpty)
    }

    @Test func gameRecordEnrichesWritePathFields() {
        let session = GameSession()
        session.board.width = 9; session.board.height = 9
        session.player.nextColorForPlayCommand = .black
        session.gobanState.analysisStatus = .run
        session.gobanState.isEditing = true
        let gameRecord = GameRecord.createGameRecord(
            sgf: "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])", currentIndex: 4)
        gameRecord.concreteConfig.blackMaxTime = 0
        gameRecord.concreteConfig.whiteMaxTime = 0

        let snapshot = WatchSnapshotBuilder.makeSnapshot(
            session: session, gameRecord: gameRecord, moveCount: 4, now: .now)

        #expect(snapshot.hostGameID == gameRecord.uuid?.uuidString)
        #expect(snapshot.hostMoveIndex == 4)
        #expect(snapshot.hostMoveCount == 4)
        #expect(snapshot.isHumanTurn == true)
        #expect(snapshot.canScrub == true && snapshot.canPlay == true)
    }

    @Test func nilGameRecordLeavesWritePathFieldsNil() {
        let session = GameSession()
        session.board.width = 9; session.board.height = 9
        let snapshot = WatchSnapshotBuilder.makeSnapshot(session: session)
        #expect(snapshot.hostGameID == nil && snapshot.hostMoveIndex == nil
                && snapshot.canScrub == nil && snapshot.canPlay == nil)
    }

    @Test func builderPopulatesGameNameIsBranchAndPositionComment() {
        // No branch active: the displayed index is the record's own
        // currentIndex, so the comment stored there should ride along
        // unsuppressed.
        let session = GameSession()
        session.board.width = 9; session.board.height = 9
        session.player.nextColorForPlayCommand = .black
        let gameRecord = GameRecord.createGameRecord(
            sgf: "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])",
            currentIndex: 4,
            name: "Ladder Fight 3",
            comments: [4: "White cuts cleanly."])

        let snapshot = WatchSnapshotBuilder.makeSnapshot(
            session: session, gameRecord: gameRecord, moveCount: 4, now: .now)

        #expect(snapshot.gameName == "Ladder Fight 3")
        #expect(snapshot.isBranch == false)
        #expect(snapshot.positionComment == "White cuts cleanly.")
    }

    @Test func branchActiveSuppressesCommentButKeepsGameNameAndIsBranch() {
        // gameRecord.comments is keyed by MAINLINE index, but getCurrentIndex
        // reports the branch index while a branch is active. Put a comment
        // at that very branch index so an unsuppressed lookup would find it
        // (proving the nil below is deliberate suppression, not a missing
        // key) — and confirm gameName/isBranch still populate normally, so
        // the suppression is scoped to positionComment alone.
        let session = GameSession()
        session.board.width = 9; session.board.height = 9
        session.player.nextColorForPlayCommand = .black
        let gameRecord = GameRecord.createGameRecord(
            sgf: "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])",
            currentIndex: 2,
            name: "Ladder Fight 3",
            comments: [2: "at divergence", 5: "would leak if unsuppressed"])
        session.gobanState.branchSgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[ee];W[ff];B[gg])"
        session.gobanState.branchIndex = 5

        let snapshot = WatchSnapshotBuilder.makeSnapshot(
            session: session, gameRecord: gameRecord, moveCount: 4, now: .now)

        #expect(snapshot.isBranch == true)
        #expect(snapshot.positionComment == nil)
        #expect(snapshot.gameName == "Ladder Fight 3")
    }

    @Test func positionCommentIsLookedUpAtTheDisplayedIndexNotIndexZero() {
        // Guards against reading the lookup index before the builder
        // assigns it (snapshot.hostMoveIndex), which would silently pull
        // every comment from move 0 regardless of where the game is parked.
        let session = GameSession()
        session.board.width = 9; session.board.height = 9
        session.player.nextColorForPlayCommand = .black
        let gameRecord = GameRecord.createGameRecord(
            sgf: "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])",
            currentIndex: 3,
            comments: [0: "opening comment", 3: "displayed comment"])

        let snapshot = WatchSnapshotBuilder.makeSnapshot(
            session: session, gameRecord: gameRecord, moveCount: 4, now: .now)

        #expect(snapshot.positionComment == "displayed comment")
    }

    @Test func longCommentAtTheDisplayedIndexIsCappedForTheWire() {
        // Pins the cap to the actual wire boundary: WatchSnapshotV13Tests'
        // worst-case-size test bakes an already-capped string into a
        // hand-built snapshot, so it would still pass even if the builder's
        // cappedComment() call were deleted. This exercises the builder
        // itself.
        let session = GameSession()
        session.board.width = 9; session.board.height = 9
        session.player.nextColorForPlayCommand = .black
        let longComment = String(repeating: "a",
                                 count: WatchWidgetSnapshot.commentCharacterLimit + 500)
        let gameRecord = GameRecord.createGameRecord(
            sgf: "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])",
            currentIndex: 4,
            comments: [4: longComment])

        let snapshot = WatchSnapshotBuilder.makeSnapshot(
            session: session, gameRecord: gameRecord, moveCount: 4, now: .now)

        // limit characters plus one for the appended ellipsis.
        #expect(snapshot.positionComment?.count == WatchWidgetSnapshot.commentCharacterLimit + 1)
    }
}
