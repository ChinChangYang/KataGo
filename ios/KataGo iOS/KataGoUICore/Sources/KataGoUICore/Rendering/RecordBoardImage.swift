//
//  RecordBoardImage.swift
//  KataGoUICore
//
//  A rasterized `RecordBoardPreview`, for the handful of consumers that need
//  PIXELS rather than a live view: Now Playing artwork (MediaPlayer wants a
//  UIImage) and the share sheet's preview.
//
//  Library rows deliberately do NOT come through here — they host
//  `ReportBoardView` directly, so stone style, vertical flip and appearance
//  changes reflow without any invalidation logic. Rasterize only where a raster
//  is what the API takes.
//

import SwiftUI

@MainActor
public enum RecordBoardImage {
#if os(macOS)
    public typealias PlatformImage = NSImage
#else
    public typealias PlatformImage = UIImage
#endif

    /// The board `record` is parked on, rendered at `side` points square.
    ///
    /// Nil when the record's SGF cannot be read — the same rejection the rows
    /// make, so an unreadable game is unreadable everywhere.
    public static func render(for record: GameRecord,
                              side: CGFloat,
                              isClassicStoneStyle: Bool = false,
                              verticalFlip: Bool = Config.compatibleVerticalFlip) -> PlatformImage? {
        guard let preview = RecordBoardPreviewSource.preview(for: record) else { return nil }

        let content = ReportBoardView(width: preview.width,
                                      height: preview.height,
                                      blackVertices: preview.blackVertices,
                                      whiteVertices: preview.whiteVertices,
                                      overlay: .none,
                                      lastMoveVertex: preview.lastMoveVertex,
                                      isClassicStoneStyle: isClassicStoneStyle,
                                      showCoordinate: false,
                                      verticalFlip: verticalFlip)
            .frame(width: side, height: side)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1  // frame points == pixels, as in GameGifRenderer
#if os(macOS)
        return renderer.nsImage
#else
        return renderer.uiImage
#endif
    }

    /// The same board as a SwiftUI `Image`, for APIs that take one (a
    /// `SharePreview`). Nil for an unreadable record.
    public static func image(for record: GameRecord,
                             side: CGFloat,
                             isClassicStoneStyle: Bool = false,
                             verticalFlip: Bool = Config.compatibleVerticalFlip) -> Image? {
        guard let rendered = render(for: record,
                                    side: side,
                                    isClassicStoneStyle: isClassicStoneStyle,
                                    verticalFlip: verticalFlip) else { return nil }
#if os(macOS)
        return Image(nsImage: rendered)
#else
        return Image(uiImage: rendered)
#endif
    }
}
