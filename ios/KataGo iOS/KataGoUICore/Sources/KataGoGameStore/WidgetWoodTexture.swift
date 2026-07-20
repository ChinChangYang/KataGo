import CoreGraphics

/// The widget appex's ONLY door to the procedural wood. The full-resolution
/// `BoardTopTexture.generate` produces a 2048-px-long image for a 19x19 —
/// ~16 MB of pixels plus a CGImage copy, which alone would blow the appex's
/// hard 30 MB jetsam limit. This wrapper clamps generation to a fixed small
/// square and memoizes the one CGImage the widget ever needs, so repeated
/// body evaluations and GeometryReader relayouts never regenerate it.
public enum WidgetWoodTexture {
    /// 640 * 640 * 4 B = 1.6 MB pixel buffer (~3.3 MB transient while the
    /// CGImage copy is made). At widget point sizes the grain reads the same
    /// as the in-app 2048-px texture.
    public static let maxSidePX = 640

    /// Wood-only grain (no grid/hoshi ink), clamped to the cap.
    public static func texture(widthPX: Int, heightPX: Int) -> BoardTopTexture {
        BoardTopTexture.generateWood(widthPX: min(max(widthPX, 1), maxSidePX),
                                     heightPX: min(max(heightPX, 1), maxSidePX))
    }

    @MainActor private static var cachedImage: CGImage?

    /// The shared square wood image: the full-bleed Wood backplate and the
    /// board's own wood card both draw this (scaled to fill), so the widget
    /// holds exactly one wood bitmap at a time.
    @MainActor public static func sharedSquareImage() -> CGImage? {
        if let cachedImage { return cachedImage }
        let image = texture(widthPX: maxSidePX, heightPX: maxSidePX).cgImage
        cachedImage = image
        return image
    }
}
