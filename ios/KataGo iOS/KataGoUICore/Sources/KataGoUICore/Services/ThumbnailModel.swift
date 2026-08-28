//
//  ThumbnailModel.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/3/31.
//

import CoreGraphics
import Foundation

/// Transient game-list state. The thumbnail *size* no longer lives here — it is
/// the app-wide `GlobalSettings.thumbnailSize` preference, read off
/// `GobanState` like every other display preference. What is left is the one
/// piece of state that is genuinely about this session's list being on screen.
@Observable
public class ThumbnailModel {
    public var isGameListViewAppeared: Bool = false

    public init() {}
}

/// The point size a game-list thumbnail is drawn at, resolved from the
/// persisted `GlobalSettings.thumbnailSize` index.
///
/// `nil` means the row draws no picture at all — and, deliberately, does no
/// work to find one: resolving a row's board replays that game's SGF, so a
/// hidden thumbnail must not reach `RecordBoardPreviewSource`. Turning the
/// picture off also retires the row's `square.grid.3x3` *unreadable record*
/// signal (ADR 0014), which was always a property of the picture slot.
public enum ThumbnailMetrics {
    // The Mac sidebar is a narrow source list, not a phone-width row, so it
    // gets its own pair: Small keeps the 40 pt board `GameRowView` has always
    // drawn, and Large stops well short of the iOS 128 pt.
    #if os(macOS)
    public static let smallSide: CGFloat = 40
    public static let largeSide: CGFloat = 72
    #else
    public static let smallSide: CGFloat = 64
    public static let largeSide: CGFloat = 128
    #endif

    /// The side length for a persisted index, or `nil` when the picture is off.
    /// An out-of-range index falls back to the default size rather than to
    /// `nil`: a corrupt value should not silently empty the library.
    public static func side(for index: Int) -> CGFloat? {
        guard Config.thumbnailSizes.indices.contains(index) else {
            return side(for: Config.defaultThumbnailSize)
        }

        switch Config.thumbnailSizes[index] {
        case Config.offThumbnailSize: return nil
        case Config.largeThumbnailSize: return largeSide
        default: return smallSide
        }
    }
}

/// Carries the retired `isLargeThumbnail` bool onto the Off/Small/Large index.
public enum ThumbnailSizePreference {
    /// The pre-`GlobalSettings` key, written by `ThumbnailModel.save()` until
    /// the thumbnail preference became app-wide. Never written again — only
    /// read once, so an update neither resizes nor hides anybody's thumbnails.
    static let legacyIsLargeKey = "isLargeThumbnail"

    static var smallIndex: Int {
        Config.thumbnailSizes.firstIndex(of: Config.smallThumbnailSize) ?? Config.defaultThumbnailSize
    }

    static var largeIndex: Int {
        Config.thumbnailSizes.firstIndex(of: Config.largeThumbnailSize) ?? Config.defaultThumbnailSize
    }

    /// Idempotent: once the new key exists it is the answer, so a later launch
    /// (or a user who has since picked Off) is never overwritten by the legacy
    /// bool. Must run *before* the preference is seeded into `GobanState`.
    public static func migrateLegacyValueIfNeeded(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: GlobalSettingsKeys.thumbnailSize) == nil else { return }
        // `object(forKey:)`, not `bool(forKey:)`: an absent legacy key means
        // this install never had the old preference, which is not the same as
        // having had it set to false.
        guard let wasLarge = defaults.object(forKey: legacyIsLargeKey) as? Bool else { return }
        defaults.set(wasLarge ? largeIndex : smallIndex, forKey: GlobalSettingsKeys.thumbnailSize)
    }
}
