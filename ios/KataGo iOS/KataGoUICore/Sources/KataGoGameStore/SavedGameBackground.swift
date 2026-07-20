/// The user-selectable backplate of the Saved Game widget, chosen per widget
/// in the Edit Widget sheet. The widget target mirrors these cases in its
/// `AppEnum` parameter (`SavedGameBackgroundOption`) and hands the RAW VALUE
/// across, so the strings are a persistence contract: they live inside users'
/// stored widget configurations and must never change meaning.
public enum SavedGameBackground: String, Codable, Sendable, CaseIterable, Equatable {
    /// Full-bleed goban: the wood grain IS the widget background, the board
    /// draws no card of its own, and text reads as dark ink on wood.
    case wood
    /// The pre-redesign look: translucent system backplate with the board as
    /// its own wood card (dark glass + bright text on visionOS).
    case glass
    case light
    case dark

    public static let `default`: SavedGameBackground = .wood

    /// Pre-upgrade widgets have no stored background parameter, and a stale
    /// configuration could carry a raw value a future version dropped —
    /// both degrade to the designed default rather than failing.
    public static func resolve(rawValue: String?) -> SavedGameBackground {
        rawValue.flatMap(SavedGameBackground.init(rawValue:)) ?? .default
    }
}
