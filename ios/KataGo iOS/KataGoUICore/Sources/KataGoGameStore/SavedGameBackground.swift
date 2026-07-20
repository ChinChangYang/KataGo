/// The user-selectable backplate of the Saved Game widget, chosen per widget
/// in the Edit Widget sheet. The widget intent stores the RAW VALUE String
/// (`SelectGameIntent.background`), so the strings are a persistence
/// contract — and they double as the display titles, because the Edit sheet
/// shows the raw value verbatim for a never-configured widget (it only maps
/// values picked from the options list to their item titles).
///
/// Declaration order drives the picker: the neutral defaults, the full-bleed
/// goban wood, then the four material backdrops.
public enum SavedGameBackground: String, Codable, Sendable, CaseIterable, Equatable {
    case light = "Light"
    case dark = "Dark"
    /// Full-bleed goban: the wood grain IS the widget background, the board
    /// draws no card of its own, and text reads as dark ink on wood.
    case wood = "Wood"
    // The material backdrops: a full-bleed procedural texture with the board
    // as its own wood card on top — a goban resting on the material (see
    // `WidgetBackplateTexture`).
    case grass = "Grass"
    case tatami = "Tatami"
    case slate = "Slate"
    case sky = "Sky"

    public static let `default`: SavedGameBackground = .light

    /// Human-readable picker title — identical to the raw value on purpose
    /// (see the type comment); kept as a named property so call sites say
    /// what they mean.
    public var displayName: String { rawValue }

    /// Pre-upgrade widgets have no stored background parameter, and a stale
    /// configuration could carry a raw value a version dropped (the retired
    /// "Glass") or a future one added — all degrade to the designed default
    /// rather than failing. Rendering degrades; the Edit sheet cannot: it
    /// shows the stored raw value verbatim until the user re-picks, so a
    /// retired name may linger in the Background row (cosmetic, no API to
    /// rewrite a stored configuration).
    public static func resolve(rawValue: String?) -> SavedGameBackground {
        rawValue.flatMap(SavedGameBackground.init(rawValue:)) ?? .default
    }
}
