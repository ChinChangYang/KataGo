import Testing
import Foundation
import KataGoUICore

struct GameDeepLinkTests {
    @Test func roundTrip_buildsAndParsesGameID() {
        let id = UUID()
        let url = GameDeepLink.url(for: id)
        #expect(url.scheme == "katago-anytime")
        #expect(GameDeepLink.gameID(from: url) == id)
    }

    @Test func gameID_rejectsForeignURLs() {
        #expect(GameDeepLink.gameID(from: URL(string: "file:///tmp/x.sgf")!) == nil)
        #expect(GameDeepLink.gameID(from: URL(string: "katago-anytime://open-game?id=not-a-uuid")!) == nil)
    }
}
