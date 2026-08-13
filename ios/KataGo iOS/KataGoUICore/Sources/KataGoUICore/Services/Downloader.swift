//
//  Downloader.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/25.
//
//  TRANSITIONAL. Downloads now run through `DownloadCenter` (ADR 0005); this
//  is a facade over it so the five consumers can move one at a time rather
//  than in a single commit that rewrites three app targets at once. Delete it
//  once the last consumer is gone — nothing new should be written against it.
//

import Foundation
import SwiftUI

@MainActor
@Observable
public final class Downloader {

    nonisolated public let destinationURL: URL

    /// The real thing. Memoized by the center against `destinationURL`, so two
    /// `Downloader`s for the same asset share one transfer — which is what
    /// closed the duplicate-download bug that made "too slow" look like a
    /// bandwidth problem.
    @ObservationIgnored private let entry: Download

    /// Ignored. The center pre-hashes a finished network itself, once, instead
    /// of at three hand-wired call sites and on no book path. Kept only so the
    /// existing assignments still compile during the migration.
    @ObservationIgnored public var onDownloadComplete: (@MainActor (URL) async -> Void)?

    public var progress: Double { entry.progress }

    /// True while transferring OR queued. A paused download reads false here,
    /// exactly as a cancelled one used to — consumers that need to tell those
    /// apart must move to `Download.state`.
    public var isDownloading: Bool { entry.isBusy }

    public var downloadedFileURL: URL? { entry.state == .succeeded ? destinationURL : nil }

    public init(destinationURL: URL) {
        self.destinationURL = destinationURL
        self.entry = DownloadCenter.shared.download(for: destinationURL)
    }

    /// `async throws` is preserved for source compatibility; it neither
    /// suspends nor throws. It never did — the old body returned as soon as
    /// `resume()` was called.
    public func download(from sourceURL: URL) async throws {
        DownloadCenter.shared.start(entry, from: sourceURL)
    }

    /// Now a pause: the partial is kept and one more tap continues it.
    public func cancel() {
        DownloadCenter.shared.pause(entry)
    }
}
