//
//  DownloadSessionDelegate.swift
//  KataGo Anytime
//
//  The URLSession face of DownloadCenter. Kept in its own file because it is
//  the only nonisolated code in the feature and the isolation boundary is the
//  thing most likely to be got wrong by a later edit.
//

import Foundation

/// Absorbs finished chunks and forwards everything else to the center.
///
/// `@unchecked Sendable`: `center` is written exactly once, on the main actor,
/// before the session that owns this delegate can deliver anything, and every
/// use of it hops back to the main actor first. `@MainActor` classes are
/// implicitly `Sendable`, so holding the reference across the boundary is safe.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    weak var center: DownloadCenter?

    /// What absorbing a finished chunk produced. `Sendable` so it can cross
    /// back to the main actor.
    private enum AbsorbOutcome: Sendable {
        case absorbed(key: String, assembled: Int64, total: Int64?, wasRestart: Bool, etag: String?)
        case rejected(key: String, reason: String)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        let written = totalBytesWritten
        Task { @MainActor [weak center] in
            center?.chunkProgress(key: key, bytesInChunk: written)
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted the moment this method returns, so ALL of
        // the file work happens here, synchronously, on the delegate queue.
        // Hopping to an actor first and moving the file there is the classic
        // way to lose a download to a race that only shows up under load.
        let outcome = Self.absorb(temp: location, task: downloadTask)
        Task { @MainActor [weak center] in
            guard let center, let outcome else { return }
            switch outcome {
            case let .absorbed(key, assembled, total, wasRestart, etag):
                center.absorbed(key: key, assembled: assembled, total: total, wasRestart: wasRestart, etag: etag)
            case let .rejected(key, reason):
                center.rejected(key: key, reason: reason)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        // Success is already handled by didFinishDownloadingTo; only failures
        // and cancellations reach the center from here. `failed` does not
        // distinguish a cancellation from any other error — see the comment
        // there for why.
        guard let key = task.taskDescription, error != nil else { return }
        Task { @MainActor [weak center] in
            center?.failed(key: key)
        }
    }

    #if !os(macOS)
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak center] in
            center?.backgroundEventsFinished()
        }
    }
    #endif

    // MARK: - Absorption

    /// Decides what a finished chunk was and writes it into staging. Pure I/O
    /// plus one call into `ResumeDecision`; no policy lives here.
    private static func absorb(temp: URL, task: URLSessionDownloadTask) -> AbsorbOutcome? {
        guard let key = task.taskDescription else { return nil }

        let response = task.response as? HTTPURLResponse
        let status = response?.statusCode ?? -1
        let rangeHeader = task.originalRequest?.value(forHTTPHeaderField: "Range")
        let requestedOffset = offset(fromRangeHeader: rangeHeader)

        var declaredLength: Int64?
        if let response, response.expectedContentLength >= 0 {
            declaredLength = response.expectedContentLength
        }

        let decision = ResumeDecision.decide(
            sentRange: rangeHeader != nil,
            requestedOffset: requestedOffset,
            statusCode: status,
            contentRange: response?.value(forHTTPHeaderField: "Content-Range"),
            contentLength: declaredLength)

        let etag = response?.value(forHTTPHeaderField: "ETag")

        switch decision {
        case let .append(total):
            // Offset 0 has nothing to append to; moving the file is both
            // cheaper and the only thing that works on the first chunk.
            let assembled = requestedOffset == 0
                ? DownloadStaging.replacePartial(withTemp: temp, forKey: key)
                : DownloadStaging.appendChunk(from: temp, toKey: key)
            return .absorbed(key: key, assembled: assembled, total: total, wasRestart: false, etag: etag)

        case let .restart(total):
            // The server ignored our range and sent the whole asset, so
            // whatever we had is superseded rather than extended.
            let assembled = DownloadStaging.replacePartial(withTemp: temp, forKey: key)
            return .absorbed(key: key, assembled: assembled, total: total, wasRestart: true, etag: etag)

        case let .fail(reason):
            // Nothing is written. The partial survives exactly as it was, so a
            // refused body can never corrupt bytes we already verified.
            return .rejected(key: key, reason: reason)
        }
    }

    /// `bytes=1024-2047` -> 1024. Absent or unparseable -> 0.
    static func offset(fromRangeHeader header: String?) -> Int64 {
        guard let header, header.hasPrefix("bytes=") else { return 0 }
        let spec = header.dropFirst("bytes=".count)
        let first = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first
        return first.flatMap { Int64($0) } ?? 0
    }
}
