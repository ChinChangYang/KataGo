//
//  WatchWidgetRecord.swift
//  KataGoAnalysisKit
//
//  What the complication renders, behind one App-Group key.
//
//  This used to hold two mirrors — one fed by the phone's WatchConnectivity
//  frames, one by the watch's own CloudKit library — with a resolution rule, a
//  per-field merge, a 24-hour expiry ceiling and an eviction pass. The phone
//  channel is gone, so all of that machinery served a contrast that no longer
//  exists and has been deleted with it.
//

import Foundation

public struct WatchWidgetRecord: Codable, Equatable, Sendable {
    /// From the newest row of the watch's own CloudKit-synced library.
    ///
    /// The property name is also the JSON key, and it is deliberately
    /// unchanged: an App-Group blob written by the previous two-mirror build
    /// decodes cleanly here because `JSONDecoder` ignores the now-unknown
    /// "live" key. Renaming this property (without `CodingKeys`) would blank
    /// every tile until the watch app next ran. Pinned by
    /// `WatchWidgetRecordTests.aTwoMirrorBlobStillDecodesItsLibraryHalf`.
    public var library: WatchWidgetSnapshot?

    public init(library: WatchWidgetSnapshot? = nil) {
        self.library = library
    }

    /// The updated record if `candidate` is worth storing, else nil so the
    /// caller skips the encode and the `UserDefaults` write entirely.
    ///
    /// An unchanged `contentKey` means nothing the tile shows has moved, so
    /// the caller skips the write entirely and the stored `capturedAt` is
    /// left untouched — there is no freshness rule riding on that, since
    /// nothing reads `capturedAt` back. There is no monotonicity guard:
    /// exactly one writer exists and it is serialized on the main actor, and
    /// a game edited on another device can legitimately arrive with an
    /// earlier timestamp.
    public func accepting(_ candidate: WatchWidgetSnapshot) -> WatchWidgetRecord? {
        if let library, library.contentKey == candidate.contentKey { return nil }
        return WatchWidgetRecord(library: candidate)
    }
}
