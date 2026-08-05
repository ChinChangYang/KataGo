//
//  WatchSnapshotV13Tests.swift
//  KataGo AnytimeTests
//
//  The fields the complication needs, added the way v1.1 and v1.2 were: all
//  optional, because WCSession persists the last application context across
//  app updates and a watch will decode frames written by an older phone for
//  as long as the two are out of step.
//

import Testing
import Foundation
@testable import KataGoGameStore

struct WatchSnapshotV13Tests {
    private func frame() -> WatchSnapshot {
        WatchSnapshot(boardWidth: 19, boardHeight: 19,
                      blackStones: ["Q16"], whiteStones: ["D4"],
                      toMove: "B", moveNumber: 2, analysisRunning: true,
                      rootWinrateBlack: 0.55, rootScoreLeadBlack: 3.5,
                      candidates: [], hostTimestamp: Date(timeIntervalSince1970: 1_000))
    }

    @Test func theNewFieldsRoundTrip() {
        var snapshot = frame()
        snapshot.gameName = "Ladder Fight 3"
        snapshot.positionComment = "White cuts."
        snapshot.isBranch = true
        let decoded = try! WatchSnapshot.decode(snapshot.encodedData())
        #expect(decoded.gameName == "Ladder Fight 3")
        #expect(decoded.positionComment == "White cuts.")
        #expect(decoded.isBranch == true)
    }

    @Test func aV12PayloadStillDecodes() {
        // The exact compatibility this optionality exists for: a payload
        // written before these fields existed must decode, with nil meaning
        // "older phone" rather than "no name".
        //
        // `v12` never sets gameName/positionComment/isBranch, so they stay
        // nil. WatchSnapshot relies on Swift's synthesized Codable, whose
        // encodeIfPresent omits a nil optional entirely rather than writing
        // an explicit JSON null — so those three keys are already absent
        // from `v12.encodedData()`, exactly the shape a genuine older-phone
        // payload has. The removeValue calls below are therefore defensive
        // no-ops, not stripping anything actually present; they are kept as
        // belt-and-braces documentation of intent.
        var v12 = frame()
        v12.hostGameID = "GAME-A"
        v12.hostMoveIndex = 42
        v12.lastMoveVertex = "Q16"
        var object = try! JSONSerialization.jsonObject(
            with: v12.encodedData()) as! [String: Any]
        object.removeValue(forKey: "gameName")
        object.removeValue(forKey: "positionComment")
        object.removeValue(forKey: "isBranch")
        let data = try! JSONSerialization.data(withJSONObject: object)

        let decoded = try! WatchSnapshot.decode(data)
        #expect(decoded.gameName == nil)
        #expect(decoded.positionComment == nil)
        #expect(decoded.isBranch == nil)
        #expect(decoded.hostGameID == "GAME-A")
    }

    @Test func aWorstCaseCommentStaysInsideTheWireBound() {
        // The frame rides updateApplicationContext at 2 Hz and is pinned at
        // "~2 KB typical, hard bound 16 KB". Commentator output is a full
        // paragraph, so the cap has to hold at the point the string enters
        // the wire — not only in the App-Group record.
        var snapshot = frame()
        snapshot.gameName = String(repeating: "N", count: 200)
        snapshot.positionComment = WatchWidgetSnapshot.cappedComment(
            String(repeating: "\u{56F4}\u{68CB}", count: 500))
        snapshot.candidates = (0..<10).map { index in
            WatchSnapshot.Candidate(vertex: "Q\(index)", winrate: 0.5, scoreLead: 1,
                                    visits: 1_000,
                                    pv: ["A1", "B2", "C3", "D4", "E5", "F6"])
        }
        #expect(try! snapshot.encodedData().count < 16 * 1024)
    }
}
