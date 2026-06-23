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
