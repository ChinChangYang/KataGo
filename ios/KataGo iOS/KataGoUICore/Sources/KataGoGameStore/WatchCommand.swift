import Foundation

/// Watch→iPhone command envelope (v1.1 write path), sent via
/// WCSession.sendMessage (reachable-only, reply expected) under `messageKey`.
/// Every command binds to the game it was computed against; play additionally
/// binds the exact position and side, so a command that raced a host change is
/// rejected visibly, never played silently (spec: hard-block gate).
public struct WatchCommand: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case goTo   // navigate the host mainline to `targetIndex`
        case play   // play `vertex` for `toMove`, valid only at `boundIndex`
    }

    /// sendMessage dictionary key holding the encoded command.
    public static let messageKey = "watchCommand"

    public var kind: Kind
    public var gameID: String
    public var targetIndex: Int?
    public var vertex: String?
    /// "B"/"W" — same convention as WatchSnapshot.toMove.
    public var toMove: String?
    public var boundIndex: Int?

    public init(kind: Kind, gameID: String, targetIndex: Int? = nil,
                vertex: String? = nil, toMove: String? = nil, boundIndex: Int? = nil) {
        self.kind = kind; self.gameID = gameID; self.targetIndex = targetIndex
        self.vertex = vertex; self.toMove = toMove; self.boundIndex = boundIndex
    }

    public func encodedData() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> WatchCommand {
        try JSONDecoder().decode(WatchCommand.self, from: data)
    }
}

/// iPhone→watch reply. `accepted` means the command entered the same engine
/// seam the phone's own UI uses (goTo → GobanState.go(to:); play → the
/// kata-check-move → play path a board tap takes) — not that the move has
/// landed. The engine's own legality check still stands after acceptance: a
/// candidate raced against a fresher position (see WatchSnapshotBuilder's
/// analysis-freshness gate) can still be rejected there, surfacing on the
/// iPhone (e.g. a ko/superko "Play Anyway" prompt). So the watch's success
/// haptic means "accepted", not "played".
public struct WatchCommandReply: Codable, Equatable, Sendable {
    public static let messageKey = "watchReply"
    public var accepted: Bool
    /// User-facing rejection reason, shown on the watch.
    public var reason: String?

    public init(accepted: Bool, reason: String? = nil) {
        self.accepted = accepted; self.reason = reason
    }

    public func encodedData() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> WatchCommandReply {
        try JSONDecoder().decode(WatchCommandReply.self, from: data)
    }
}
