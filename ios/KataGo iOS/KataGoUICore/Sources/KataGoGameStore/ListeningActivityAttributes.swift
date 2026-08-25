//
//  ListeningActivityAttributes.swift
//  KataGoGameStore
//
//  The Listening Session's Live Activity wire type, shared by the iOS app
//  (which starts and updates the activity) and the widget appex (which
//  renders it — including on the iOS 26 CarPlay Dashboard, where a Live
//  Activity appears with no CarPlay entitlement at all). Lives in the
//  bridge-free store target because the appex must never link the engine;
//  deliberately three small fields — never narration text (activity updates
//  are budgeted, and the dash card is ambient, not a transcript).
//

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

public struct ListeningActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var moveNumber: Int
        public var scoreLeadBlack: Float?
        public var isPlaying: Bool

        public init(moveNumber: Int, scoreLeadBlack: Float?, isPlaying: Bool) {
            self.moveNumber = moveNumber
            self.scoreLeadBlack = scoreLeadBlack
            self.isPlaying = isPlaying
        }

        /// "B +3.5" / "W +0.5" / "Even" — glanceable, sign-free enough for
        /// a dash card; nil when the record holds no estimate at this move.
        public var scoreLeadText: String? {
            guard let scoreLeadBlack else { return nil }
            let rounded = (scoreLeadBlack * 10).rounded() / 10
            if rounded == 0 { return "Even" }
            let magnitude = String(format: "%g", abs(rounded))
            return rounded > 0 ? "B +\(magnitude)" : "W +\(magnitude)"
        }
    }

    public var gameID: String
    public var gameName: String
    public var totalMoves: Int

    public init(gameID: String, gameName: String, totalMoves: Int) {
        self.gameID = gameID
        self.gameName = gameName
        self.totalMoves = totalMoves
    }
}
#endif
