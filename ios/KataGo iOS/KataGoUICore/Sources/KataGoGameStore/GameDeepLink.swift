import Foundation

public enum GameDeepLink {
    public static let scheme = "katago-anytime"
    public static let host = "open-game"
    /// Hand-off from the Messages extension: the app imports an SGF spooled
    /// into the App Group container (the extension may not write the store).
    public static let importSgfHost = "import-sgf"

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

    // MARK: - Messages-extension SGF hand-off

    /// katago-anytime://import-sgf?file=<name>.sgf
    public static func importSgfURL(fileName: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = importSgfHost
        c.queryItems = [URLQueryItem(name: "file", value: fileName)]
        return c.url!
    }

    /// The spool file name for an import-sgf deep link, or nil for other
    /// URLs. Rejects anything that is not a plain "<uuid>.sgf" leaf name so
    /// a crafted link cannot traverse outside the spool directory.
    public static func importSgfFileName(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == importSgfHost,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "file" })?.value,
              value.hasSuffix(".sgf"),
              UUID(uuidString: String(value.dropLast(4))) != nil else { return nil }
        return value
    }

    /// Spool directory inside the App Group container, shared between the
    /// Messages extension (writer) and the app (reader/deleter).
    public static func messagesHandoffDirectory() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedModelContainer.appGroupID)?
            .appendingPathComponent("Library/Caches/MessagesHandoff", isDirectory: true)
    }
}
