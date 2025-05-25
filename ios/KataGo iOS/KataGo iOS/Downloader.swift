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
class Downloader: NSObject, URLSessionDownloadDelegate {
    var progress: Double = 0.0
    var isDownloading: Bool = false
    var downloadedFileURL: URL?
    private var downloadTask: URLSessionDownloadTask?
    nonisolated let destinationURL: URL

    init(destinationURL: URL) {
        self.destinationURL = destinationURL
    }

    func download(from sourceURL: URL) async throws {
        progress = 0.0
        isDownloading = true
        downloadedFileURL = nil

        let urlSession = URLSession(configuration: .default,
                                    delegate: self,
                                    delegateQueue: nil)

        downloadTask = urlSession.downloadTask(with: sourceURL)
        downloadTask?.resume()
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task {
            await MainActor.run {
                progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // Remove if exists
        try? FileManager.default.removeItem(at: destinationURL)
        // The downloaded file will be removed automatically.
        try? FileManager.default.moveItem(at: location, to: destinationURL)

        Task {
            await MainActor.run {
                downloadedFileURL = destinationURL
                isDownloading = false
            }
        }
    }
}
