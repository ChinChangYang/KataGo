//
//  Downloader.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/25.
//

import Foundation
import SwiftUI

@MainActor
@Observable
public class Downloader: NSObject, URLSessionDownloadDelegate {
    public var progress: Double = 0.0
    public var isDownloading: Bool = false
    public var downloadedFileURL: URL?
    private var downloadTask: URLSessionDownloadTask?
    nonisolated public let destinationURL: URL

    /// Called on the MainActor after a successful download completes and
    /// the file has been moved to `destinationURL`. Callers (e.g.
    /// `ModelDetailView`) use this seam to hash the file and schedule a
    /// background precompile without coupling `Downloader` to the scheduler.
    public var onDownloadComplete: (@MainActor (URL) async -> Void)?

    public init(destinationURL: URL) {
        self.destinationURL = destinationURL
    }

    public func download(from sourceURL: URL) async throws {
        progress = 0.0
        isDownloading = true
        downloadedFileURL = nil

        let urlSession = URLSession(configuration: .default,
                                    delegate: self,
                                    delegateQueue: nil)

        downloadTask = urlSession.downloadTask(with: sourceURL)
        downloadTask?.resume()
    }

    public func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        progress = 0.0
    }

    nonisolated public func urlSession(_: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData _: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task {
            await MainActor.run {
                progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    nonisolated public func urlSession(_: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // Remove if exists
        try? FileManager.default.removeItem(at: destinationURL)
        // The downloaded file will be removed automatically.
        try? FileManager.default.moveItem(at: location, to: destinationURL)

        Task { @MainActor in
            downloadedFileURL = destinationURL
            isDownloading = false
            // Hash the file and fire precompile now that it's at its final URL.
            await self.onDownloadComplete?(destinationURL)
        }
    }

    nonisolated public func urlSession(_: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: (any Error)?) {
        // This is called for both success (error == nil) and failure/cancel
        Task { @MainActor in
            // If canceled or failed without producing a file, mark as not downloading
            if error != nil && downloadedFileURL == nil {
                isDownloading = false
                progress = 0.0
            }
        }
    }
}
