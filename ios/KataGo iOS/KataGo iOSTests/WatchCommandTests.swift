import Testing
import Foundation
@testable import KataGoGameStore

struct WatchCommandTests {
    @Test func goToRoundTrip() throws {
        let cmd = WatchCommand(kind: .goTo, gameID: "G1", targetIndex: 17)
        let decoded = try WatchCommand.decode(cmd.encodedData())
        #expect(decoded == cmd)
        #expect(decoded.vertex == nil && decoded.boundIndex == nil)
    }

    @Test func playRoundTripCarriesFullBinding() throws {
        // Spec: the gate carries the bound position — a play command must be
        // rejectable when the board moved after it was computed.
        let cmd = WatchCommand(kind: .play, gameID: "G1", vertex: "Q16",
                               toMove: "B", boundIndex: 42)
        let decoded = try WatchCommand.decode(cmd.encodedData())
        #expect(decoded == cmd)
    }

    @Test func replyRoundTrip() throws {
        let ok = try WatchCommandReply.decode(WatchCommandReply(accepted: true).encodedData())
        #expect(ok.accepted && ok.reason == nil)
        let no = try WatchCommandReply.decode(
            WatchCommandReply(accepted: false, reason: "Position changed").encodedData())
        #expect(!no.accepted && no.reason == "Position changed")
    }
}
