import Foundation

public enum GameDeepLink {
    public static let scheme = "katago-anytime"
    public static let host = "open-game"

    public static func url(for id: UUID) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        return c.url!
    }

    public static func gameID(from url: URL) -> UUID? {
        guard url.scheme == scheme, url.host == host,
              let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "id" }),
              let value = item.value else { return nil }
        return UUID(uuidString: value)
    }
}

/// Serializes a deep-link game selection against engine readiness so a deep link
/// arriving before the engine is ready doesn't drive GTP at a not-yet-ready
/// engine (F14). On macOS the engine is a subprocess that finishes its GTP
/// handshake asynchronously; a cold launch from the Saved Game widget can fire
/// `selectGame(byID:)` (→ `loadsgf`/`kata-analyze`) before that handshake
/// completes, and those commands are dropped. When the engine isn't ready the
/// requested game ID is stashed; the caller drains it once the engine signals
/// ready (on macOS, right after `boardReadiness.isEngineReady` flips true).
public struct DeepLinkSelectionGate {
    /// The deep-link game awaiting an engine-ready signal, if any. Last request
    /// wins: a newer tap supersedes an older deferred one.
    public private(set) var pendingGameID: UUID?

    public init() {}

    /// A deep link requested `gameID`. Returns the ID to apply NOW (engine
    /// ready), or `nil` when the request was deferred — stashed in
    /// `pendingGameID` for a later `drainOnEngineReady()`.
    public mutating func request(gameID: UUID, isEngineReady: Bool) -> UUID? {
        if isEngineReady {
            pendingGameID = nil   // drop any stale deferred tap; this one wins
            return gameID
        }
        pendingGameID = gameID
        return nil
    }

    /// The engine became ready. Returns the deferred game ID to apply now (if
    /// any) and clears it so a later engine relaunch can't replay a stale deep
    /// link.
    public mutating func drainOnEngineReady() -> UUID? {
        defer { pendingGameID = nil }
        return pendingGameID
    }
}
