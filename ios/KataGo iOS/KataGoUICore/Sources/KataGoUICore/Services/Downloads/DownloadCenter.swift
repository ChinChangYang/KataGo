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

    /// `finishedGeneration` counts completed installs; observing it is how a
    /// freshly downloaded opening book gets activated even when the detail
    /// view that started it has been popped.
    ///
    /// `lastFinishedDestination` is informational — a last-value slot, and NOT
    /// a queue. Two finishes can land in one main-actor turn (`finish` ends
    /// with `advanceQueue`, which starts the next download, which
    /// short-circuits straight back to `finish` when its staged partial
    /// already covers the declared total), so one of the two destinations is
    /// overwritten before any observer runs. Consumers must therefore re-scan
    /// disk for what they care about rather than dispatch on this value; both
    /// the iOS and the macOS hook do.
    public private(set) var lastFinishedDestination: URL?
    public private(set) var finishedGeneration: Int = 0

    @ObservationIgnored private var downloads: [String: Download] = [:]
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var activeKey: String?
    @ObservationIgnored private var activeTask: URLSessionDownloadTask?
    /// `activeTask`'s `taskIdentifier`, or nil while the active transfer was
    /// reattached from a previous launch and its identifier is not yet known.
    /// Every delegate callback carries the identifier of the task it came
    /// from and is matched against this — see `callbackIsCurrent`.
    @ObservationIgnored private var activeTaskIdentifier: Int?
    /// True when `activeKey` was reattached from a previous launch and there
    /// is no in-process `URLSessionDownloadTask` handle for it: only
    /// `getAllTasks` can hand one back, and a `URLSessionTask` may not cross
    /// out of that completion, so cancelling it needs `cancelDetachedTask`
    /// instead of `activeTask?.cancel()`.
    @ObservationIgnored private var activeTaskIsDetached = false
    @ObservationIgnored private var pausedKeys: Set<String> = []
    @ObservationIgnored private var backgroundEvents: CheckedContinuation<Void, Never>?
    /// Set when `backgroundEventsFinished()` arrives with no continuation
    /// waiting — the events can finish before `awaitBackgroundURLSessionEvents()`
    /// is even entered, and without this latch that completion would be
    /// dropped and the next continuation would wait forever.
    @ObservationIgnored private var pendingBackgroundEvents = false
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

    /// The one seam between this state machine and the network: it creates,
    /// names and starts the ranged request and returns the `taskIdentifier`
    /// its callbacks will carry. `nil` — the production value — means the real
    /// background session below.
    ///
    /// It exists because every defect this file has ever had lived in the
    /// queue / active-slot / state transitions, and not one of them needs a
    /// socket to reproduce: a test sets this and then drives `absorbed`,
    /// `rejected` and `failed` by hand. A background `URLSession` ignores
    /// `URLProtocol` stubs, so there is no other way to reach this code from a
    /// unit test.
    @ObservationIgnored var launchTask: ((URLRequest, String) -> Int)?

    private init() {
        downloadsDisabled = ProcessInfo.processInfo.arguments.contains(Self.disableLaunchArgument)
    }

    /// Internal, and taking the kill switch as a parameter, so a unit test can
    /// build its own center instead of mutating the process-lifetime `shared`
    /// — and so it does not inherit the host process's launch arguments.
    init(downloadsDisabled: Bool) {
        self.downloadsDisabled = downloadsDisabled
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
        download.verificationFailures = 0
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
            if let activeTask {
                activeTask.cancel()
            } else if activeTaskIsDetached {
                cancelDetachedTask(forKey: download.key)
            }
            clearActiveSlot()
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
            // Only `.running`: a `.suspended` or `.canceling` task may never
            // deliver a terminal callback, and one that does not would pin
            // `activeKey` for the process lifetime and strand the queue.
            // Treating it as interrupted instead costs at most one chunk,
            // which is the loss budget chunking was chosen for.
            let live = Set(tasks.compactMap { task -> String? in
                task.state == .running ? task.taskDescription : nil
            })
            Task { @MainActor [weak self] in
                self?.finishRestore(liveKeys: live)
            }
        }
    }

    public func sweepStaging() {
        let doomed = StagingSweep.keysToDiscard(DownloadStaging.scan(), now: Date())
        for key in doomed where key != activeKey && !queue.contains(key) {
            DownloadStaging.discardPartial(forKey: key)
        }
    }

    /// Suspends until the background session has delivered every event it
    /// woke the app up for. Driven by `Scene.backgroundTask(.urlSession(_:))`.
    public func awaitBackgroundURLSessionEvents() async {
        #if os(macOS)
        // macOS never relaunches an app for background session events — the
        // only resumer of this continuation is `urlSessionDidFinishEvents`,
        // which is compiled out on macOS. Nothing would ever call it, so
        // return immediately rather than hang forever.
        return
        #else
        // Materialise the session. On a background relaunch no scene is
        // mounted, so nothing else in the process has touched `session` yet
        // — and without a live delegate, nsurlsessiond has nowhere to
        // deliver the events we were woken for.
        _ = session
        // The events can finish before this closure is even entered; without
        // this latch that completion would be dropped and we would wait
        // forever.
        if pendingBackgroundEvents {
            pendingBackgroundEvents = false
            return
        }
        await withCheckedContinuation { continuation in
            // Two overlapping wake-ups: let the earlier one go rather than
            // leak a continuation, which traps at runtime.
            backgroundEvents?.resume()
            backgroundEvents = continuation
        }
        #endif
    }

    // MARK: - Delegate callbacks

    /// Whether a callback still belongs to the transfer this center is
    /// running. Callbacks are matched by TASK, not by key: a `pause` followed
    /// by a `start` of the same download cancels one task and creates another,
    /// and the cancellation lands AFTERWARDS carrying the dead task's
    /// identifier. Acting on it would clear the live task's bookkeeping and
    /// arm a retry, and that retry would start a third task while the second
    /// was still appending to the same partial — two live transfers, one
    /// staging file. (It fails safe: the doubled bytes overshoot the declared
    /// total, `TransferVerification` reports `.sizeMismatch` and the partial is
    /// thrown away. It also costs a whole re-download.)
    ///
    /// A callback for a key that does not currently hold the active slot is
    /// always current: there is nothing for it to be stale against, and the
    /// background-relaunch path — where no scene mounted, so nothing is active
    /// — depends on those callbacks being processed rather than dropped.
    ///
    /// Permissive for a transfer reattached from a previous launch: only
    /// `getAllTasks` can hand back its identifier and a `URLSessionTask` may
    /// not cross out of that completion, so the first callback to arrive
    /// adopts it.
    ///
    /// That adoption has a narrow residual: `restoreOnLaunch` filters
    /// `liveKeys` to `.running` tasks only, so a task left `.canceling` by a
    /// `pause` the process did not outlive is excluded from the snapshot —
    /// but still has a completion queued in the daemon. If that stale
    /// completion arrives before the adopted (live) task's first callback,
    /// its identifier is adopted instead, and the slot is then cleared for
    /// the wrong task. It fails safe the same way the stale-callback case
    /// above does: the live task keeps writing after its identifier was
    /// dropped, the overshoot trips `TransferVerification`'s `.sizeMismatch`,
    /// and the partial is discarded rather than installed wrong. Restricting
    /// adoption to `chunkProgress` — where a progress callback proves the
    /// adopting task is actually alive, rather than merely first to arrive —
    /// would close most of this; not done here because it is a behaviour
    /// change and this residual already fails safe.
    private func callbackIsCurrent(key: String, taskIdentifier: Int) -> Bool {
        guard activeKey == key else { return true }
        guard let current = activeTaskIdentifier else {
            if activeTaskIsDetached { activeTaskIdentifier = taskIdentifier }
            return true
        }
        return current == taskIdentifier
    }

    /// Releases the one active slot. All four fields are cleared together on
    /// purpose: forgetting one of them — the detached flag, and now the task
    /// identifier — has twice been the shape of a defect in this file.
    private func clearActiveSlot() {
        activeKey = nil
        activeTask = nil
        activeTaskIdentifier = nil
        activeTaskIsDetached = false
    }

    func chunkProgress(key: String, taskIdentifier: Int, bytesInChunk: Int64) {
        guard callbackIsCurrent(key: key, taskIdentifier: taskIdentifier),
              activeKey == key,
              let download = downloads[key] else { return }
        download.receivedBytes = download.chunkStartOffset + bytesInChunk
    }

    func absorbed(key: String,
                  taskIdentifier: Int,
                  assembled: Int64,
                  total: Int64?,
                  wasRestart: Bool,
                  etag: String?) {
        guard callbackIsCurrent(key: key, taskIdentifier: taskIdentifier) else { return }
        if activeKey == key {
            clearActiveSlot()
        }
        // `rehydrate`, not `downloads[key]`: on a background relaunch no scene
        // mounts, so nothing ever vended a `Download` and this used to bail —
        // which left a COMPLETED transfer sitting in staging, uninstalled,
        // until the next foreground launch, and issued no next chunk. The
        // sidecar holds everything needed to rebuild the download, which is
        // what makes ADR 0005 decision 2's handoff actually work.
        guard let download = rehydrate(key: key) else {
            advanceQueue()
            return
        }
        download.receivedBytes = assembled
        if let total { download.totalBytes = total }
        if let etag { download.etag = etag }
        download.attempt = 0

        // A pause that landed while this chunk was being written to disk
        // still wins. `absorb` does up to a chunk's worth of file I/O on the
        // delegate queue before hopping here, so the user's tap can genuinely
        // arrive first — and the cancel it issued hit a task that had already
        // finished, so no error callback is coming to carry the pause. Keep
        // the bytes, honour the stop.
        //
        // `download.state == .paused` catches the same stop arriving in a
        // FRESH process: `pausedKeys` is always empty there, but `rehydrate`
        // above already seeded `.paused` from the sidecar. This has to run
        // BEFORE `persist(download, pausedByUser: false)` below, or that call
        // clears the very flag being checked.
        if pausedKeys.remove(key) != nil || download.state == .paused {
            download.state = .paused
            persist(download, pausedByUser: true)
            advanceQueue()
            return
        }
        persist(download, pausedByUser: false)

        guard let expected = download.totalBytes else {
            if wasRestart {
                // A 200 really is the whole asset, so there is nothing left
                // to bound and nothing left to fetch.
                finish(download, assembledBytes: assembled)
            } else {
                // A 206 with `Content-Range: bytes x-y/*` legally omits the
                // total. `TransferVerification` treats an undeclared total as
                // "nothing to check" — correct for a whole-asset GET, wrong
                // here, where the body legitimately ends at the range's end
                // rather than the asset's end. Refuse instead of installing a
                // truncated prefix as verified.
                rejected(key: key,
                         taskIdentifier: taskIdentifier,
                         reason: "206 without a declared total; cannot bound the transfer")
            }
            return
        }
        guard assembled < expected else {
            finish(download, assembledBytes: assembled)
            return
        }
        beginNextChunk(for: download)
    }

    func rejected(key: String, taskIdentifier: Int, reason: String) {
        guard callbackIsCurrent(key: key, taskIdentifier: taskIdentifier) else { return }
        if activeKey == key {
            clearActiveSlot()
        }
        // `rehydrate` for the same reason as `absorbed`: a background relaunch
        // has no `Download` on record and still has to issue the next chunk.
        guard let download = rehydrate(key: key) else {
            advanceQueue()
            return
        }
        // Nothing was written for a refused body, so the partial is still
        // exactly the bytes we already proved were ours.
        download.receivedBytes = DownloadStaging.partialSize(forKey: key)
        // Same race as `absorbed`: a pause that landed during the delegate's
        // file work must not be undone by a retry armed here. And the same
        // fresh-process case as `absorbed`: `pausedKeys` is empty right after
        // a relaunch, but `rehydrate` above already seeded `.paused` from the
        // sidecar when that is what it found there.
        if pausedKeys.remove(key) != nil || download.state == .paused {
            download.state = .paused
            persist(download, pausedByUser: true)
            advanceQueue()
            return
        }
        // Still queued behind another transfer: leave it alone. See `failed`
        // for why overwriting a `.waiting` key here strands it.
        if queue.contains(key) {
            advanceQueue()
            return
        }
        download.state = .interrupted
        scheduleRetry(download)
        advanceQueue()
    }

    func failed(key: String, taskIdentifier: Int) {
        guard callbackIsCurrent(key: key, taskIdentifier: taskIdentifier) else { return }
        if activeKey == key {
            clearActiveSlot()
        }
        // A pause cancels its own task; that is not a failure and must not
        // arm a retry that would undo the pause.
        if pausedKeys.remove(key) != nil {
            advanceQueue()
            return
        }
        // Not special-cased: a system-initiated cancel (e.g. the OS tearing
        // the app down) is a plain failure and SHOULD arm a retry below, so
        // the transfer resumes on the next launch instead of staying stuck.
        // `rehydrate`, not `downloads[key]`, so a background relaunch can
        // retry a transfer no view ever vended.
        guard let download = rehydrate(key: key) else {
            advanceQueue()
            return
        }
        // Same fresh-process case as `absorbed`/`rejected`: the `pausedKeys`
        // check above cannot see a pause that predates this process, but
        // `rehydrate` just seeded `.paused` from the sidecar when that is
        // what it found there. Honour it — keep the partial, keep the pause,
        // arm no retry.
        if download.state == .paused {
            persist(download, pausedByUser: true)
            advanceQueue()
            return
        }
        // A key still sitting in the queue is left exactly as it is. Its task
        // is already over — this callback is what says so — and it is waiting
        // its turn, not failing. Marking it `.interrupted` here used to strand
        // it outright: the retry armed below no-ops on `enqueue`'s
        // `!queue.contains` guard, and when its turn came `advanceQueue` saw a
        // state that was not `.waiting`. Reachable by pausing a transfer that
        // another download is queued behind and resuming it before the
        // cancellation callback lands.
        if queue.contains(key) {
            advanceQueue()
            return
        }
        download.receivedBytes = DownloadStaging.partialSize(forKey: key)
        download.state = .interrupted
        scheduleRetry(download)
        advanceQueue()
    }

    func backgroundEventsFinished() {
        if let backgroundEvents {
            backgroundEvents.resume()
            self.backgroundEvents = nil
        } else {
            pendingBackgroundEvents = true
        }
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

    /// Cancels a transfer we inherited from a previous launch. The task is
    /// the background session's, not ours, so it is cancelled inside
    /// `getAllTasks` — no `URLSessionTask` crosses the isolation boundary.
    private func cancelDetachedTask(forKey key: String) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == key {
                task.cancel()
            }
        }
    }

    private func advanceQueue() {
        while !queue.isEmpty {
            // Re-checked every iteration, not just on entry: `beginNextChunk`
            // can hand a download to `finish`, which starts the next one.
            guard activeKey == nil else { return }
            let next = queue.removeFirst()
            guard let download = downloads[next] else { continue }
            // A queued entry whose state was not `.waiting` used to be dropped
            // here without a word — a fail-silent branch that stranded a
            // download whose retry budget had already been spent. Spell out
            // instead which states may legitimately turn up in the queue and
            // what each one means.
            switch download.state {
            case .waiting:
                break
            case .interrupted, .transferring, .idle:
                // A terminal callback for a task that is already over can land
                // while its key is still queued and demote it out of
                // `.waiting`. It was queued in order to run, so re-mark it and
                // run it rather than dropping it.
                download.state = .waiting
            case .paused, .succeeded:
                // Neither can legitimately appear: `pause` removes its key from
                // the queue, and a finished transfer has nothing left to fetch.
                // Starting either would be wrong — a paused download must never
                // resume itself, and a succeeded one would re-download an asset
                // already installed — so drop the entry.
                continue
            }
            // A bail (e.g. a corrupted sourceURL) must not stall the rest
            // of the app-wide queue behind one unstartable download.
            if beginNextChunk(for: download) { return }
        }
    }

    /// - Returns: `true` when a transfer was started or the download was
    ///   terminally handed to `finish`. `false` means one of two things: it
    ///   bailed and is left in a state nobody may wait on (no source URL, or
    ///   the center is disabled), or the active slot was already someone
    ///   else's and the download was safely appended to the queue as
    ///   `.waiting`. Either way the caller must not read `false` as "a
    ///   transfer is now running"; `advanceQueue` moves on to the next key.
    @discardableResult
    private func beginNextChunk(for download: Download) -> Bool {
        guard !downloadsDisabled else { return false }
        guard let sourceURL = download.sourceURL else {
            // No source URL on record — nothing this download can do until a
            // fresh `start` supplies one. Land it rather than leave it
            // spinning at `.waiting` forever.
            download.state = .interrupted
            return false
        }

        let offset = DownloadStaging.partialSize(forKey: download.key)
        download.receivedBytes = offset
        download.chunkStartOffset = offset

        if let total = download.totalBytes, offset >= total {
            finish(download, assembledBytes: offset)
            return true
        }

        // The one active slot is claimed here and nowhere else, and only when
        // it is free or already this download's. Claiming it unconditionally
        // overwrote the RUNNING transfer's bookkeeping, after which `pause` on
        // that transfer found `activeKey != download.key`, cancelled nothing
        // and recorded nothing: the user tapped Stop, the UI said Paused, and
        // the bytes kept coming. A shadowed caller queues instead, which is a
        // benign delay rather than a lost stop button.
        guard activeKey == nil || activeKey == download.key else {
            download.state = .waiting
            if !queue.contains(download.key) { queue.append(download.key) }
            return false
        }

        var request = URLRequest(url: sourceURL)
        request.setValue("bytes=\(offset)-\(offset + Self.chunkSize - 1)",
                         forHTTPHeaderField: "Range")
        // If-Range only matters once we have bytes to protect. Sending back
        // the validator the server gave us — its ETag, or its Last-Modified
        // date when it sent no ETag — means a changed asset comes back 200
        // (whole body) instead of splicing new bytes onto old ones.
        if offset > 0, let etag = download.etag {
            request.setValue(etag, forHTTPHeaderField: "If-Range")
        }

        activeKey = download.key
        if let launchTask {
            // Test seam: no session, no socket, no task handle. `pause` finds
            // no `activeTask` and nothing detached, so it cancels nothing —
            // which is exactly right, since nothing is running.
            activeTask = nil
            activeTaskIdentifier = launchTask(request, download.key)
        } else {
            let task = session.downloadTask(with: request)
            // Survives a background relaunch, which is how the delegate finds
            // its way back to the right staging file when no view ever ran.
            task.taskDescription = download.key
            activeTask = task
            activeTaskIdentifier = task.taskIdentifier
            task.resume()
        }
        // We hold a real handle again, so `pause` must cancel through it
        // rather than through `cancelDetachedTask`.
        activeTaskIsDetached = false
        download.state = .transferring
        return true
    }

    private func finish(_ download: Download, assembledBytes: Int64) {
        if activeKey == download.key {
            clearActiveSlot()
        }

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
            // worth resuming from either. Throw them away and start over.
            DownloadStaging.discardPartial(forKey: download.key)
            download.receivedBytes = 0
            download.verificationFailures += 1
            guard download.verificationFailures <= RetryBackoff.delays.count else {
                // Counted separately from transport retries on purpose: every
                // successful chunk resets `attempt`, so the transport's cap
                // can never engage here, and each of these retries costs a
                // whole re-download.
                //
                // No `persist` here: the partial was just discarded, so a
                // sidecar written now would be an orphan `.partialmeta` that
                // `scan()` — which enumerates only `.partial` — can never
                // sweep. Nothing needs it: with no bytes on disk there is
                // nothing to resume, and a fresh `start` writes it again.
                download.state = .paused
                break
            }
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
        // A previous back-off sleep, if any, must not survive to fire
        // alongside this one — two overlapping sleepers would each call
        // `enqueue` and double-increment `attempt`, silently halving the
        // retry budget.
        download.retryTask?.cancel()
        download.retryTask = Task { [weak self, weak download] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self, let download,
                  download.state == .interrupted else { return }
            self.enqueue(download)
        }
    }

    func finishRestore(liveKeys: Set<String>) {
        for key in liveKeys {
            guard let download = rehydrate(key: key) else { continue }
            if activeKey == nil {
                activeKey = key
                // The task belongs to the background session from a previous
                // launch; only `getAllTasks` can hand it back, and a
                // `URLSessionTask` may not cross out of that completion. So
                // record that our handle is missing and look it up on demand.
                // The identifier is unknown for the same reason; the first
                // callback that arrives for this key adopts it (see
                // `callbackIsCurrent`).
                activeTask = nil
                activeTaskIdentifier = nil
                activeTaskIsDetached = true
                download.state = .transferring
            } else if key == activeKey {
                // Our OWN in-process transfer: `start` landed after
                // `getAllTasks` was asked and before its snapshot came back,
                // so this key is both live and already holding the slot.
                // Cancelling here would kill a transfer that is perfectly
                // healthy.
                continue
            } else {
                // Something already took the one active slot while
                // `getAllTasks` was in flight — a fresh `start` landing
                // before this callback ran. Leaving THIS key `.transferring`
                // would let its next chunk (`beginNextChunk`, on the delegate
                // callback) overwrite the active download's `activeKey`/
                // `activeTask` bookkeeping unconditionally, after which
                // Pause on the active download silently stops working (its
                // `activeKey == download.key` guard would fail). Cancel this
                // detached task and requeue instead — at most one 32 MiB
                // chunk is lost, the same loss budget chunking was chosen
                // for.
                cancelDetachedTask(forKey: key)
                download.state = .interrupted
                download.attempt = 0
                enqueue(download)
            }
        }
        for partial in DownloadStaging.scan()
        where !liveKeys.contains(partial.key) && partial.key != activeKey && !queue.contains(partial.key) {
            guard let metadata = DownloadStaging.readMetadata(forKey: partial.key),
                  !metadata.pausedByUser,
                  let download = rehydrate(key: partial.key) else { continue }
            // visionOS's Info.plist allows several scenes and each one calls
            // `restoreOnLaunch()`, so this loop can run more than once per
            // launch. Cancel any sleeping back-off rather than leave it to
            // fire alongside the restart below (a leaked sleeper per scene
            // mount), and do NOT reset `attempt`: a second mount must not hand
            // a persistently failing download a fresh retry budget. A genuine
            // cold launch rehydrates a brand-new `Download`, whose `attempt`
            // is already 0.
            download.retryTask?.cancel()
            download.retryTask = nil
            download.state = .interrupted
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
        // Without this, the progress bar collapses to near zero right after a
        // relaunch and re-climbs, because `chunkProgress` would otherwise add
        // this chunk's bytes-written on top of a zero baseline instead of the
        // bytes already on disk.
        download.chunkStartOffset = DownloadStaging.partialSize(forKey: key)
        // Seed from the sidecar the way `download(for:)` already does. A
        // callback reaching `rehydrate` means it landed in a fresh process —
        // the only place a paused download gets rebuilt rather than read from
        // `downloads` — and `pausedKeys` is empty there. Without this, a
        // download the user explicitly stopped comes back `.idle`, the
        // `absorbed`/`rejected`/`failed` callbacks below have no pause to see,
        // and an explicit Stop is silently undone: `absorbed` even persists
        // `pausedByUser: false`, erasing the pause from the sidecar too.
        download.state = metadata.pausedByUser ? .paused : .interrupted
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
