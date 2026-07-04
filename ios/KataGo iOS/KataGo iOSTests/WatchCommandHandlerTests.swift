import Testing
import Foundation
@testable import KataGoUICore
import KataGoGameStore

@MainActor
struct WatchCommandHandlerTests {
    private static let sgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])"

    private func makeHost(currentIndex: Int = 4)
        -> (session: GameSession, gameRecord: GameRecord) {
        let session = GameSession()
        session.board.width = 9; session.board.height = 9
        let gameRecord = GameRecord.createGameRecord(sgf: Self.sgf, currentIndex: currentIndex)
        gameRecord.concreteConfig.blackMaxTime = 0
        gameRecord.concreteConfig.whiteMaxTime = 0
        session.player.nextColorForPlayCommand = .black
        session.gobanState.analysisStatus = .run
        session.gobanState.isEditing = true
        return (session, gameRecord)
    }

    private func encoded(_ cmd: WatchCommand) -> Data { try! cmd.encodedData() }

    @Test func inactiveHostRejects() {
        let (session, gameRecord) = makeHost()
        let cmd = WatchCommand(kind: .goTo, gameID: gameRecord.uuid!.uuidString, targetIndex: 2)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: false)
        #expect(!reply.accepted)
    }

    @Test func wrongGameIDRejects() {
        let (session, gameRecord) = makeHost()
        let cmd = WatchCommand(kind: .goTo, gameID: "not-the-game", targetIndex: 2)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(!reply.accepted)
    }

    @Test func goToNavigatesTheMainline() {
        let (session, gameRecord) = makeHost()
        let cmd = WatchCommand(kind: .goTo, gameID: gameRecord.uuid!.uuidString, targetIndex: 2)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(reply.accepted)
        #expect(gameRecord.currentIndex == 2)
        // go(to:) backward path sends real GTP undos through the message list.
        #expect(session.messageList.messages.contains { $0.text == "> undo" })
    }

    @Test func goToOutOfRangeRejects() {
        let (session, gameRecord) = makeHost()
        let cmd = WatchCommand(kind: .goTo, gameID: gameRecord.uuid!.uuidString, targetIndex: 99)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(!reply.accepted)
        #expect(gameRecord.currentIndex == 4)
    }

    @Test func playDispatchesCheckMove() {
        let (session, gameRecord) = makeHost()
        let cmd = WatchCommand(kind: .play, gameID: gameRecord.uuid!.uuidString,
                               vertex: "E5", toMove: "B", boundIndex: 4)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(reply.accepted)
        // Same seam as a board tap: pending move set + kata-check-move sent;
        // GameSession.maybeCollectCheckMove finishes the play when the engine
        // confirms legality.
        #expect(session.gobanState.pendingMoveVertex == "E5")
        #expect(session.gobanState.pendingMoveTurn == "b")
        #expect(session.messageList.messages.contains { $0.text == "> kata-check-move b E5" })
    }

    @Test func playWithStaleBindingRejects() {
        let (session, gameRecord) = makeHost()
        // Computed against index 3, but the host is at 4 → position changed.
        let cmd = WatchCommand(kind: .play, gameID: gameRecord.uuid!.uuidString,
                               vertex: "E5", toMove: "B", boundIndex: 3)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(!reply.accepted)
        #expect(session.gobanState.pendingMoveTurn == nil)
    }

    @Test func playWithWrongSideRejects() {
        let (session, gameRecord) = makeHost()
        let cmd = WatchCommand(kind: .play, gameID: gameRecord.uuid!.uuidString,
                               vertex: "E5", toMove: "W", boundIndex: 4)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(!reply.accepted)
    }

    @Test func playOnLockedGameRejects() {
        let (session, gameRecord) = makeHost()
        session.gobanState.isEditing = false
        let cmd = WatchCommand(kind: .play, gameID: gameRecord.uuid!.uuidString,
                               vertex: "E5", toMove: "B", boundIndex: 4)
        let reply = WatchCommandHandler.handle(data: encoded(cmd), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(!reply.accepted)
    }

    @Test func garbageDataRejects() {
        let (session, gameRecord) = makeHost()
        let reply = WatchCommandHandler.handle(data: Data([0xFF]), session: session,
                                               gameRecord: gameRecord, moveCount: 4,
                                               audioModel: nil, hostIsActive: true)
        #expect(!reply.accepted)
    }
}
