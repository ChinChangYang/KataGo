/// The user-selectable backplate of the Saved Game widget, chosen per widget
/// in the Edit Widget sheet. The widget intent stores the RAW VALUE String
/// (`SelectGameIntent.background`), so the strings are a persistence
/// contract — and they double as the display titles, because the Edit sheet
/// shows the raw value verbatim for a never-configured widget (it only maps
/// values picked from the options list to their item titles).
public enum SavedGameBackground: String, Codable, Sendable, CaseIterable, Equatable {
    /// Full-bleed goban: the wood grain IS the widget background, the board
    /// draws no card of its own, and text reads as dark ink on wood.
    case wood = "Wood"
    /// The pre-redesign look: translucent system backplate with the board as
    /// its own wood card (dark glass + bright text on visionOS).
    case glass = "Glass"
    case light = "Light"
    case dark = "Dark"

    public static let `default`: SavedGameBackground = .wood

    /// Human-readable picker title — identical to the raw value on purpose
    /// (see the type comment); kept as a named property so call sites say
    /// what they mean.
    public var displayName: String { rawValue }

    /// Pre-upgrade widgets have no stored background parameter, and a stale
    /// configuration could carry a raw value a future version dropped —
    /// both degrade to the designed default rather than failing.
    public static func resolve(rawValue: String?) -> SavedGameBackground {
        rawValue.flatMap(SavedGameBackground.init(rawValue:)) ?? .default
    }
}
