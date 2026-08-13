//
//  DownloadCenter.swift
//  KataGo Anytime
//
//  The one place a catalog asset is fetched. See
//  docs/adr/0005-downloads-run-through-one-center-resumed-by-range.md.
//
//  Keyed by DESTINATION URL, not by file name: that is what makes a duplicate
//  transfer of the same asset unrepresentable, and the background session has
//  to persist that mapping anyway in order to move a file after a relaunch.
//
//  Assets are fetched in fixed-size ranged chunks. A URLSessionDownloadTask
//  surrenders its bytes only when it FINISHES, so one open-ended request would
//  lose everything to a dropped connection — exactly the case resumability
//  exists for — and the resume-data alternative pins a redirect that expires
//  in about thirty minutes. Chunking bounds the loss at one chunk and
//  re-resolves the redirect on every request.
//

import Foundation
import CoreMLCacheKit

@MainActor
@Observable
public final class DownloadCenter {

    public static let shared = DownloadCenter()

    /// Pass in `XCUIApplication.launchArguments` to make the center inert.
    /// Without it, a background session that auto-resumes at launch would
    /// issue unattended network traffic inside a suite whose offline
    /// guarantee is the reason `ModelStagingUITestSupport` exists at all.
    public static let disableLaunchArgument = "--uitest-disable-downloads"

    /// Stable across launches — the system matches a relaunch's background
    /// events to the session by this string.
    public static let sessionIdentifier = "tw.chinchangyang.KataGoAnytime.downloads"

    /// 32 MiB. Big enough that the per-request round trip is noise against the
    /// transfer (eight requests for the largest book, ~1.5 s on a healthy
    /// link), small enough that a drop or a pause never costs more than that.
    static let chunkSize: Int64 = 32 * 1024 * 1024

    /// The destination of the download that most recently succeeded, paired
    /// with a counter so a consumer can react to two finishes of the same
    /// asset. This is how a freshly downloaded opening book gets activated
    /// even when the detail view that started it has been popped.
    public private(set) var lastFinishedDestination: URL?
    public private(set) var finishedGeneration: Int = 0

    @ObservationIgnored private var downloads: [String: Download] = [:]
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var activeKey: String?
    @ObservationIgnored private var activeTask: URLSessionDownloadTask?
    @ObservationIgnored private var pausedKeys: Set<String> = []
    @ObservationIgnored private var backgroundEvents: CheckedContinuation<Void, Never>?
    @ObservationIgnored private let sessionDelegate = DownloadSessionDelegate()
    @ObservationIgnored public let downloadsDisabled: Bool

    /// Lazy so that merely constructing a `Download` — in a SwiftUI preview,
    /// say — never spins up a background session.
    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Not discretionary: the user asked for this and is watching a
        // progress icon. Discretionary would let the system defer it to a
        // charging-and-on-Wi-Fi window, which reads as a broken button.
        configuration.isDiscretionary = false
        // A background session already waits for connectivity; setting this
        // states the intent and keeps the behaviour if the configuration ever
        // stops being a background one.
        configuration.waitsForConnectivity = true
        #if !os(macOS)
        configuration.sessionSendsLaunchEvents = true
        #endif
        sessionDelegate.center = self
        return URLSession(configuration: configuration,
                          delegate: sessionDelegate,
                          delegateQueue: nil)
    }()

    private init() {
        downloadsDisabled = ProcessInfo.processInfo.arguments.contains(Self.disableLaunchArgument)
    }

    // MARK: - Vending

    /// The one `Download` for this destination, created on first ask and
    /// seeded from any partial already on disk.
    public func download(for destinationURL: URL) -> Download {
        let key = DownloadStaging.key(for: destinationURL)
        if let existing = downloads[key] { return existing }

        let download = Download(key: key, destinationURL: destinationURL)
        download.receivedBytes = DownloadStaging.partialSize(forKey: key)
        if let metadata = DownloadStaging.readMetadata(forKey: key) {
            download.sourceURL = URL(string: metadata.sourceURLString)
            download.etag = metadata.etag
            download.totalBytes = metadata.declaredTotal
            download.state = metadata.pausedByUser ? .paused : .interrupted
        }
        downloads[key] = download
        return download
    }

    // MARK: - Commands

    public func start(_ download: Download, from sourceURL: URL) {
        guard !downloadsDisabled else { return }
        download.retryTask?.cancel()
        download.retryTask = nil
        download.attempt = 0
        download.sourceURL = sourceURL
        pausedKeys.remove(download.key)
        persist(download, pausedByUser: false)
        enqueue(download)
    }

    /// Stop means pause. The partial survives and nothing resumes it until the
    /// user says so — which is why every consumer reads `state` rather than
    /// the old `isDownloading` true->false edge, an edge a pause and a
    /// completion share.
    public func pause(_ download: Download) {
        download.retryTask?.cancel()
        download.retryTask = nil
        download.attempt = 0
        if activeKey == download.key {
            pausedKeys.insert(download.key)
            activeTask?.cancel()
            activeTask = nil
            activeKey = nil
        }
        queue.removeAll { $0 == download.key }
        download.state = .paused
        persist(download, pausedByUser: true)
        advanceQueue()
    }

    // MARK: - Launch

    /// Sweeps staging, reattaches to anything the background daemon kept
    /// running while the app was gone, and resumes what was interrupted.
    /// Paused downloads are left alone by design.
    public func restoreOnLaunch() {
        sweepStaging()
        guard !downloadsDisabled else { return }
        session.getAllTasks { tasks in
            // Only Strings cross the boundary — never the tasks themselves.
            let live = Set(tasks.compactMap { task -> String? in
                task.state == .completed ? nil : task.taskDescription
            })
            Task { @MainActor [weak self] in
                self?.finishRestore(liveKeys: live)
            }
        }
    }

    public func sweepStaging() {
        let doomed = StagingSweep.keysToDiscard(DownloadStaging.scan(), now: Date())
        for key in doomed where key != activeKey {
            DownloadStaging.discardPartial(forKey: key)
        }
    }

    /// Suspends until the background session has delivered every event it
    /// woke the app up for. Driven by `Scene.backgroundTask(.urlSession(_:))`.
    public func awaitBackgroundURLSessionEvents() async {
        await withCheckedContinuation { continuation in
            // Two overlapping wake-ups: let the earlier one go rather than
            // leak a continuation, which traps at runtime.
            backgroundEvents?.resume()
            backgroundEvents = continuation
        }
    }

    // MARK: - Delegate callbacks

    func chunkProgress(key: String, bytesInChunk: Int64) {
        guard activeKey == key, let download = downloads[key] else { return }
        download.receivedBytes = download.chunkStartOffset + bytesInChunk
    }

    func absorbed(key: String, assembled: Int64, total: Int64?, etag: String?) {
        activeKey = nil
        activeTask = nil
        guard let download = downloads[key] else {
            advanceQueue()
            return
        }
        download.receivedBytes = assembled
        if let total { download.totalBytes = total }
        if let etag { download.etag = etag }
        download.attempt = 0
        persist(download, pausedByUser: false)

        // A server that declared no total gave us all it was going to give.
        guard let expected = download.totalBytes, assembled < expected else {
            finish(download, assembledBytes: assembled)
            return
        }
        beginNextChunk(for: download)
    }

    func rejected(key: String, reason: String) {
        if activeKey == key {
            activeKey = nil
            activeTask = nil
        }
        guard let download = downloads[key] else {
            advanceQueue()
            return
        }
        // Nothing was written for a refused body, so the partial is still
        // exactly the bytes we already proved were ours.
        download.receivedBytes = DownloadStaging.partialSize(forKey: key)
        download.state = .interrupted
        scheduleRetry(download)
        advanceQueue()
    }

    func failed(key: String, isCancellation: Bool) {
        if activeKey == key {
            activeKey = nil
            activeTask = nil
        }
        // A pause cancels its own task; that is not a failure and must not
        // arm a retry that would undo the pause.
        if pausedKeys.remove(key) != nil {
            advanceQueue()
            return
        }
        guard let download = downloads[key] else {
            advanceQueue()
            return
        }
        download.receivedBytes = DownloadStaging.partialSize(forKey: key)
        download.state = .interrupted
        scheduleRetry(download)
        advanceQueue()
    }

    func backgroundEventsFinished() {
        backgroundEvents?.resume()
        backgroundEvents = nil
    }

    // MARK: - Internals

    private func enqueue(_ download: Download) {
        guard activeKey != download.key, !queue.contains(download.key) else { return }
        guard activeKey == nil else {
            // Waiting, not paused: nobody stopped it. Parallel transfers were
            // measured to buy nothing, so a queue is strictly better — full
            // throughput to one file and an honest ETA.
            download.state = .waiting
            queue.append(download.key)
            return
        }
        beginNextChunk(for: download)
    }

    private func advanceQueue() {
        guard activeKey == nil else { return }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let download = downloads[next], download.state == .waiting {
                beginNextChunk(for: download)
                return
            }
        }
    }

    private func beginNextChunk(for download: Download) {
        guard !downloadsDisabled, let sourceURL = download.sourceURL else { return }

        let offset = DownloadStaging.partialSize(forKey: download.key)
        download.receivedBytes = offset
        download.chunkStartOffset = offset

        if let total = download.totalBytes, offset >= total {
            finish(download, assembledBytes: offset)
            return
        }

        var request = URLRequest(url: sourceURL)
        request.setValue("bytes=\(offset)-\(offset + Self.chunkSize - 1)",
                         forHTTPHeaderField: "Range")
        // If-Range only matters once we have bytes to protect. Sending the
        // ETag we were given means a changed asset comes back 200 (whole
        // body) instead of splicing new bytes onto old ones.
        if offset > 0, let etag = download.etag {
            request.setValue(etag, forHTTPHeaderField: "If-Range")
        }

        let task = session.downloadTask(with: request)
        // Survives a background relaunch, which is how the delegate finds its
        // way back to the right staging file when no view ever ran.
        task.taskDescription = download.key
        activeKey = download.key
        activeTask = task
        download.state = .transferring
        task.resume()
    }

    private func finish(_ download: Download, assembledBytes: Int64) {
        activeKey = nil
        activeTask = nil

        switch TransferVerification.check(assembledBytes: assembledBytes,
                                          declaredTotal: download.totalBytes) {
        case .verified:
            if DownloadStaging.install(key: download.key, destination: download.destinationURL) {
                download.state = .succeeded
                download.receivedBytes = assembledBytes
                lastFinishedDestination = download.destinationURL
                finishedGeneration &+= 1
                prewarmCacheIdentity(for: download.destinationURL)
            } else {
                download.state = .interrupted
                scheduleRetry(download)
            }

        case .sizeMismatch:
            // These bytes are not what the server promised, so they are not
            // worth resuming from either. Throw them away and start over
            // rather than append onto a body of unknown provenance.
            DownloadStaging.discardPartial(forKey: download.key)
            download.receivedBytes = 0
            download.state = .interrupted
            scheduleRetry(download)
        }
        advanceQueue()
    }

    private func scheduleRetry(_ download: Download) {
        guard !downloadsDisabled else { return }
        guard let delay = RetryBackoff.delay(forAttempt: download.attempt) else {
            // Retries exhausted. Land paused with the partial intact — one tap
            // from resuming — and say nothing. Retries plus a preserved
            // partial make the common failure recoverable without a message.
            download.state = .paused
            persist(download, pausedByUser: true)
            return
        }
        download.attempt += 1
        download.retryTask = Task { [weak self, weak download] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self, let download,
                  download.state == .interrupted else { return }
            self.enqueue(download)
        }
    }

    private func finishRestore(liveKeys: Set<String>) {
        for key in liveKeys {
            guard let download = rehydrate(key: key) else { continue }
            download.state = .transferring
            if activeKey == nil { activeKey = key }
        }
        for partial in DownloadStaging.scan() where !liveKeys.contains(partial.key) {
            guard let metadata = DownloadStaging.readMetadata(forKey: partial.key),
                  !metadata.pausedByUser,
                  let download = rehydrate(key: partial.key) else { continue }
            download.state = .interrupted
            download.attempt = 0
            enqueue(download)
        }
    }

    private func rehydrate(key: String) -> Download? {
        if let existing = downloads[key] { return existing }
        guard let metadata = DownloadStaging.readMetadata(forKey: key) else { return nil }
        let download = Download(key: key,
                                destinationURL: URL(fileURLWithPath: metadata.destinationPath))
        download.sourceURL = URL(string: metadata.sourceURLString)
        download.etag = metadata.etag
        download.totalBytes = metadata.declaredTotal
        download.receivedBytes = DownloadStaging.partialSize(forKey: key)
        downloads[key] = download
        return download
    }

    private func persist(_ download: Download, pausedByUser: Bool) {
        guard let source = download.sourceURL else { return }
        DownloadStaging.writeMetadata(
            PartialMetadata(destinationPath: download.destinationURL.path,
                            sourceURLString: source.absoluteString,
                            etag: download.etag,
                            declaredTotal: download.totalBytes,
                            pausedByUser: pausedByUser),
            forKey: download.key)
    }

    /// A network's Core ML cache key needs the file's hash, so computing it
    /// now keeps the first engine launch that selects it off the hot path.
    /// This used to be wired by hand at three call sites and on no book path;
    /// it is one center-owned hook because books are far larger and have no
    /// cache key at all.
    private func prewarmCacheIdentity(for url: URL) {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent != OpeningBook.booksDirectory().standardizedFileURL else { return }
        Task.detached(priority: .userInitiated) {
            _ = try? await BinFileHasher.shared.identityForDownloadedFile(url)
        }
    }
}
