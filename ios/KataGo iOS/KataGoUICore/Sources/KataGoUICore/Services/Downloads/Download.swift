//
//  Download.swift
//  KataGo Anytime
//
//  One catalog asset being brought onto the device. Vended by DownloadCenter,
//  never constructed by a view — the center keys them by destination URL, and
//  that is what makes a second concurrent transfer of the same asset
//  unrepresentable rather than merely discouraged.
//

import Foundation

@MainActor
@Observable
public final class Download: Identifiable {
    /// Digest of the destination path. Also the staging file name and the
    /// task description that survives a background relaunch.
    public let key: String

    /// Where the verified bytes will land.
    public let destinationURL: URL

    /// The stable catalog URL. Never a resolved redirect.
    public internal(set) var sourceURL: URL?

    public internal(set) var state: DownloadState = .idle

    /// Bytes on disk, including the chunk currently in flight.
    public internal(set) var receivedBytes: Int64 = 0

    /// The total the server declared, or nil until the first response.
    public internal(set) var totalBytes: Int64?

    /// Sent back as `If-Range` so a changed asset restarts cleanly. The
    /// server's `ETag` when it sent one, otherwise its `Last-Modified` date —
    /// `If-Range` accepts either.
    @ObservationIgnored internal var etag: String?

    /// Which retry we are on, 0-based. Reset by an explicit start or pause.
    @ObservationIgnored internal var attempt: Int = 0

    /// Consecutive `TransferVerification.sizeMismatch` outcomes. Counted
    /// separately from `attempt`: every successful chunk resets `attempt` to
    /// 0, so the transport retry cap can never engage against a persistent
    /// size mismatch — this one can, and it does, because each retry here
    /// costs a whole re-download rather than one chunk. Reset by an explicit
    /// start.
    @ObservationIgnored internal var verificationFailures: Int = 0

    /// The pending back-off sleep, cancelled by a pause or a fresh start.
    @ObservationIgnored internal var retryTask: Task<Void, Never>?

    /// The partial's size when the in-flight chunk began, so live progress can
    /// be reported without re-stat'ing the file on every callback.
    @ObservationIgnored internal var chunkStartOffset: Int64 = 0

    public nonisolated var id: String { key }

    /// 0...1, and always finite: an undeclared total yields 0 rather than the
    /// NaN that would make SwiftUI drop the rotating icon entirely.
    public var progress: Double {
        DownloadProgressMath.fraction(received: receivedBytes, total: totalBytes)
    }

    /// Running or queued behind another transfer. Not "stopped but resumable".
    public var isBusy: Bool { state == .transferring || state == .waiting }

    public var hasPartial: Bool { receivedBytes > 0 }

    internal init(key: String, destinationURL: URL) {
        self.key = key
        self.destinationURL = destinationURL
    }
}
