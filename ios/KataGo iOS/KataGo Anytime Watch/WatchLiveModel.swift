import Foundation
import Observation
import WatchConnectivity
import WatchKit
import KataGoGameStore

/// Watch-side receiver: decodes WatchSnapshot frames from the application
/// context, feeds the peek buffer, tracks staleness, and mirrors the full
/// record — game name, comment, parked position, branch state — into the
/// App Group for the complication. WCSession persists the most recent
/// application context across launches (`receivedApplicationContext`),
/// which IS the spec's "cache the last snapshot" — no extra storage needed.
@Observable
@MainActor
final class WatchLiveModel: NSObject, WCSessionDelegate {
    static let staleAfter: TimeInterval = 10
    static let appGroupID = "group.chinchangyang.KataGo-iOS.tw"

    private(set) var latest: WatchSnapshot?
    private(set) var receivedAt: Date?
    let peek = WatchPeekBuffer()
    /// Ticks every 5 s so `isStale` re-evaluates without new frames.
    private(set) var now = Date()
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    /// Set by WatchRootView. The model does not own the mirror: writing the
    /// record needs the SwiftData container for the library half, and the
    /// live path must never touch SwiftData.
    @ObservationIgnored var widgetMirror: WatchWidgetMirror?
    /// Resolves a game id to its library name, so a frame from a phone that
    /// predates the v1.3 wire fields still produces a named tile.
    @ObservationIgnored var libraryName: ((String) -> String?)?

    let cursor = WatchSharedCursor()
    private(set) var isReachable = false
    /// Transient user-facing rejection/failure banner text (auto-clears).
    private(set) var rejectionMessage: String?
    /// True while a play command awaits its reply (debounces double-taps).
    private(set) var playPending = false
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var rejectionClearTask: Task<Void, Never>?
    /// In-flight handles for the `Task`s that `session(_:didReceiveUserInfo:)`,
    /// `session(_:didReceiveApplicationContext:)`, and
    /// `session(_:activationDidCompleteWith:)` each spawn to decode a frame
    /// and, via `ingest`/`ingestComplicationPayload` → `mirrorWidget` /
    /// `widgetMirror?.mirrorLive`, write the widget record.
    /// `hasContentPending` only reflects delivery to the delegate, not
    /// completion of any of these unawaited hops, so
    /// `drainWatchConnectivity()` needs actual handles to wait on — these
    /// are them.
    ///
    /// This is a collection, not a single `Task?` slot, because THREE
    /// separate delegate entry points can each spawn one of these, and a
    /// single slot lets a later delivery silently overwrite an earlier
    /// delivery's handle before the drain has awaited it. (This file used
    /// to use a single slot and get away with it only because the ingest
    /// chain happened to contain no suspension point between the
    /// assignment and the read — an unstated, unguarded invariant.) Keying
    /// by a monotonically increasing `Int`, assigned before the wrapping
    /// `Task` is even created, guarantees every registration keeps its own
    /// slot no matter how many deliveries land concurrently or whether the
    /// work they spawn ever suspends — so correctness no longer depends on
    /// the ingest chain being suspension-free. Do not collapse this back
    /// to a single handle.
    ///
    /// Entries are self-pruning: each registered task removes its own key
    /// the moment it finishes (see `registerIngestTask`). That bound
    /// matters because `didReceiveApplicationContext` alone can fire at up
    /// to 2 Hz while the app is foreground, where no drain ever runs to
    /// consume anything — without self-pruning this dictionary would grow
    /// for the life of the process.
    ///
    /// Mutated only on the main actor.
    @ObservationIgnored private var inFlightIngestTasks: [Int: Task<Void, Never>] = [:]
    /// Next key for `inFlightIngestTasks`. A monotonically increasing `Int`
    /// (rather than, say, a `UUID`) is the simplest thing that is
    /// guaranteed unique per registration and cheap to hand out from the
    /// main actor.
    @ObservationIgnored private var nextIngestTaskID = 0
    /// The hostGameID captured at the moment a goTo was proposed (scrub-time),
    /// not at debounce-fire — so a game switch mid-debounce can't rebind the
    /// stale crown target onto the new game.
    @ObservationIgnored private var pendingGoToGameID: String?

    var isStale: Bool {
        WatchSnapshot.isStale(receivedAt: receivedAt, now: now, threshold: Self.staleAfter)
    }

    /// The write path is usable: fresh frames, phone reachable for
    /// sendMessage, and a v1.1 host that currently allows navigation.
    var sharedCursorAvailable: Bool {
        !isStale && isReachable
            && latest?.canScrub == true
            && latest?.hostMoveIndex != nil
            && latest?.hostGameID != nil
    }

    var canPlayNow: Bool {
        !isStale && isReachable && latest?.canPlay == true && latest?.hostGameID != nil
    }

    var cursorPendingTarget: Int? { cursor.pendingTarget }

    /// The launch-critical half: register the delegate, activate, and replay
    /// the persisted context. Called from `App.init()` so a BACKGROUND launch
    /// — which never evaluates the window body, and therefore never runs
    /// `.onAppear` — still has a delegate to receive the complication payload.
    func activateForLaunch() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        if let data = session.receivedApplicationContext[WatchSnapshot.contextKey] as? Data {
            ingest(data, receivedAt: nil)
        }
    }

    /// The UI-only half: a 5 s tick so `isStale` re-evaluates without new
    /// frames. Started from the live view, never from `init()` — a background
    /// wake has no staleness to render and no business running a timer.
    func startClock() {
        guard clockTask == nil else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.now = Date()
            }
        }
    }

    /// Upper bound on the whole drain. A `WKBackgroundTask` that never
    /// completes gets the process terminated (0xc51bad01/02/03) rather than
    /// merely finishing late, so this method must never wait unconditionally
    /// on anything. 5 s is generous headroom over the work actually being
    /// awaited — a UserDefaults write plus a `WidgetCenter` reload request,
    /// both local and normally sub-second — while staying comfortably inside
    /// a watchOS background-refresh task's own budget (tens of seconds), so
    /// a stuck write still lets the background task complete on time instead
    /// of running out the OS's clock.
    private static let drainCeiling: Duration = .seconds(5)

    /// How long to wait, once `hasContentPending` has cleared, for an entry
    /// to actually show up in `inFlightIngestTasks` before concluding this
    /// wake has no ingest work at all. See the reasoning in
    /// `drainWatchConnectivity()`.
    private static let taskAppearanceGrace: Duration = .milliseconds(500)

    /// Hold the process alive until WatchConnectivity has nothing pending
    /// AND every delegate-spawned downstream task — decoding a frame and
    /// writing the widget record — has actually finished.
    ///
    /// `hasContentPending` alone is not enough: it reflects delivery to a
    /// delegate method, not completion of the `Task { @MainActor in ... }`
    /// chain that `session(_:didReceiveUserInfo:)`,
    /// `session(_:didReceiveApplicationContext:)`, and
    /// `session(_:activationDidCompleteWith:)` each spawn and deliberately
    /// do not await (see those methods and `inFlightIngestTasks`). Polling
    /// it alone can return before any of those chains has even run, and
    /// `WKBackgroundTask` documents that failing to complete a background
    /// task terminates the app — so the wake would happen and produce
    /// nothing.
    func drainWatchConnectivity() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.drainCeiling)

        while WCSession.default.hasContentPending, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }

        // `hasContentPending` clearing and a delegate method's own hop onto
        // the main actor race independently of each other and of this
        // method, so `inFlightIngestTasks` can legitimately still be empty
        // here — including on entry, if this drain starts running before
        // WatchConnectivity has dispatched anything at all. The drain being
        // invoked at all is proof the system woke this process for
        // WatchConnectivity content, so a delegate call is expected
        // imminently even when it has not landed yet: give it a short grace
        // window rather than concluding immediately that there is nothing to
        // wait for. The window is short (not the full ceiling) so a wake
        // that turns out to carry no complication payload — e.g. some other
        // WatchConnectivity delivery — does not sit out the whole budget for
        // a task that will never arrive.
        let graceDeadline = min(clock.now.advanced(by: Self.taskAppearanceGrace), deadline)
        while inFlightIngestTasks.isEmpty, clock.now < graceDeadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }

        // Loop rather than snapshot-and-await-once: a delegate call landing
        // WHILE this method is asleep in the poll below registers a fresh
        // entry that must also be waited for, not silently skipped — that
        // gap (a delivery arriving mid-drain going unobserved) is exactly
        // what the old single-handle design left open. Because every
        // registered task removes its own key the instant it finishes
        // (`registerIngestTask`), polling for the collection to become
        // empty is equivalent to awaiting every task that is, or later
        // becomes, in flight, with no separate bookkeeping of which handles
        // have already been seen. `clock.now < deadline` keeps this bounded
        // by the same ceiling as the rest of the method, so a hung write
        // still lets the background task complete instead of hanging.
        while !inFlightIngestTasks.isEmpty, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Registers `work` as in-flight under a fresh key in
    /// `inFlightIngestTasks`, and removes that key the instant `work`
    /// finishes running — whether or not `work` itself ever suspends. Every
    /// call site is already hopped onto the main actor (the three delegate
    /// methods below each do `Task { @MainActor in ... }` before calling
    /// this), so the registration itself is a plain synchronous dictionary
    /// write: there is no window where `drainWatchConnectivity()` could
    /// observe a task running without a corresponding entry, or vice versa.
    private func registerIngestTask(_ work: @escaping @MainActor () -> Void) {
        let id = nextIngestTaskID
        nextIngestTaskID += 1
        inFlightIngestTasks[id] = Task { @MainActor in
            work()
            self.inFlightIngestTasks[id] = nil
        }
    }

    func ingest(_ data: Data, receivedAt: Date?) {
        guard let snapshot = try? WatchSnapshot.decode(data) else { return }
        // Spec: haptic on live-move arrival — only for a real position change
        // on a live (not cold-replay) frame while the user is pinned to live.
        let positionChanged = latest.map { $0.positionKey != snapshot.positionKey } ?? false
        // `applicationState` matters now that the delegate is registered from
        // `init()`: before that, a frame could only arrive with UI on screen.
        // A background delivery must be silent. Not observable in the
        // simulator, which reports the app as active.
        if positionChanged, receivedAt != nil, peek.isLive,
           WKApplication.shared().applicationState == .active {
            WKInterfaceDevice.current().play(.click)
        }
        latest = snapshot
        self.receivedAt = receivedAt
        now = Date()
        peek.ingest(snapshot)
        switch cursor.observe(hostIndex: snapshot.hostMoveIndex, now: Date()) {
        case .timedOut:
            pendingGoToGameID = nil
            showRejection("iPhone didn't respond")
        case .confirmed:
            pendingGoToGameID = nil
        case .waiting, nil:
            break
        }
        mirrorWidget(snapshot)
    }

    /// Crown moved to `target` (host mainline index). Debounced goTo.
    func scrub(to target: Int) {
        guard sharedCursorAvailable else { return }
        // Already there and nothing in flight → no-op (also swallows the
        // programmatic crown resyncs the page performs).
        if target == latest?.hostMoveIndex, cursor.pendingTarget == nil { return }
        guard cursor.propose(target: target) else { return }
        // Bind the gameID now, at propose time — not at debounce-fire — so a
        // game switch inside the debounce window can't rebind this target
        // onto the new game (Finding 3).
        pendingGoToGameID = latest?.hostGameID
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(WatchSharedCursor.debounce))
            guard !Task.isCancelled else { return }
            self?.sendPendingGoTo()
        }
    }

    private func sendPendingGoTo() {
        // Take the due target FIRST so the cursor can never wedge in
        // `.debouncing` if the bound gameID has since gone away (Finding 2).
        guard let target = cursor.takeDue(now: Date()) else { return }
        guard let gameID = pendingGoToGameID else {
            cursor.abandon()
            return
        }
        send(WatchCommand(kind: .goTo, gameID: gameID, targetIndex: target))
    }

    func playCandidate(vertex: String) {
        guard canPlayNow, let s = latest, let gameID = s.hostGameID, !playPending else { return }
        playPending = true
        send(WatchCommand(kind: .play, gameID: gameID, vertex: vertex,
                          toMove: s.toMove, boundIndex: s.hostMoveIndex))
    }

    private func send(_ command: WatchCommand) {
        guard let data = try? command.encodedData() else { return }
        // Both handlers MUST be @Sendable: WCSession invokes them on its own
        // background queue, but sendMessage's ObjC signature carries no
        // isolation annotations — so a plain closure literal formed here
        // inherits this class's @MainActor isolation and the compiler wraps
        // it in a dynamic main-queue assertion that traps (EXC_BREAKPOINT)
        // the moment the reply arrives off-main. @Sendable makes the closures
        // nonisolated; they only extract Sendable values before hopping.
        WCSession.default.sendMessage(
            [WatchCommand.messageKey: data],
            replyHandler: { @Sendable reply in
                // Extract Sendable Data before hopping (house pattern).
                let replyData = reply[WatchCommandReply.messageKey] as? Data
                Task { @MainActor in self.handleReply(replyData, for: command.kind) }
            },
            errorHandler: { @Sendable error in
                let message = error.localizedDescription
                Task { @MainActor in self.handleTransportFailure(message, for: command.kind) }
            })
    }

    private func handleReply(_ data: Data?, for kind: WatchCommand.Kind) {
        if kind == .play { playPending = false }
        guard let data, let reply = try? WatchCommandReply.decode(data) else {
            handleTransportFailure("Bad reply from iPhone", for: kind)
            return
        }
        if reply.accepted {
            // goTo: confirmation arrives as the next frame (cursor.observe in
            // ingest). play: the move lands as a position-change frame.
            if kind == .play { playHapticIfVisible(.success) }
        } else {
            if kind == .goTo { cursor.abandon(); pendingGoToGameID = nil }
            playHapticIfVisible(.failure)
            showRejection(reply.reason ?? "Rejected by iPhone")
        }
    }

    private func handleTransportFailure(_ message: String, for kind: WatchCommand.Kind) {
        if kind == .play { playPending = false }
        if kind == .goTo { cursor.abandon(); pendingGoToGameID = nil }
        playHapticIfVisible(.failure)
        showRejection(message)
    }

    /// Haptics are feedback for something the wearer just did, so they are
    /// suppressed whenever the app is not on screen.
    private func playHapticIfVisible(_ type: WKHapticType) {
        guard WKApplication.shared().applicationState == .active else { return }
        WKInterfaceDevice.current().play(type)
    }

    private func showRejection(_ text: String) {
        rejectionMessage = text
        rejectionClearTask?.cancel()
        rejectionClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.rejectionMessage = nil
        }
    }

    /// Project the frame into the complication's record.
    ///
    /// The previous version wrote two App-Group scalars on EVERY ingest — up
    /// to 2 Hz — and gated only the reload, on a half-point score move. Both
    /// halves were wrong for a tile that shows a name and a comment: those
    /// change while the score sits still, and a JSON encode plus a cfprefsd
    /// transaction twice a second is not something to do on watch hardware.
    /// `WatchWidgetMirror` now gates the WRITE on the displayed content
    /// instead, which eliminates the write whenever that content is
    /// unchanged — an idle board, a paused analysis, a repeated frame. It
    /// does NOT eliminate the 2 Hz rate on its own: a root score lead moves
    /// by more than the rounding tolerance on most frames, so a live
    /// analysis still writes at frame rate while it runs. That is bounded —
    /// only while the watch app is foregrounded and the phone is analysing —
    /// not a bug this gate was meant to close.
    private func mirrorWidget(_ snapshot: WatchSnapshot) {
        guard let gameID = snapshot.hostGameID,
              let candidate = WatchWidgetLiveSource.snapshot(
                from: snapshot,
                fallbackName: libraryName?(gameID),
                capturedAt: Date()) else { return }
        widgetMirror?.mirrorLive(candidate)
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        // `receivedApplicationContext` is documented empty until activation
        // completes, so a true cold launch misses the synchronous replay in
        // `activate()`. Replay again here — but only if no live frame has
        // arrived yet, so a fresh frame is never downgraded to stale. Read the
        // (Sendable) Data here so the non-Sendable session isn't captured.
        //
        // This is the COMMON path, not a rare fallback: on a true cold
        // launch the synchronous replay in `activateForLaunch()` typically
        // misses (activation hasn't completed yet when it runs), so this is
        // what actually restores a cached snapshot most of the time.
        // Routing through `registerIngestTask`, like the other two delegate
        // methods, is what lets `drainWatchConnectivity()` gate on it
        // instead of silently no-op-ing on a background wake.
        let data = session.receivedApplicationContext[WatchSnapshot.contextKey] as? Data
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            guard self.latest == nil, let data else { return }
            self.registerIngestTask { self.ingest(data, receivedAt: nil) }
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchSnapshot.contextKey] as? Data else { return }
        // Registers via `registerIngestTask` like the other two delegate
        // methods (see `inFlightIngestTasks`) even though most deliveries
        // land in the foreground, where no drain is running to consume the
        // entry — the task still self-prunes on completion regardless of
        // whether anything is waiting on it, so this adds no unbounded
        // growth.
        Task { @MainActor in
            self.registerIngestTask { self.ingest(data, receivedAt: Date()) }
        }
    }

    /// The phone's complication payload. Deliberately does NOT go through
    /// `ingest`, for two reasons.
    ///
    /// `session(_:activationDidCompleteWith:)` replays the persisted context
    /// only under `guard self.latest == nil`; setting `latest` from here would
    /// permanently suppress the real mirror frame for the rest of the process,
    /// and `sharedCursorAvailable`, `canPlayNow`, the board page and the launch
    /// route all read it. And this callback fires on a background launch,
    /// where the peek buffer, the shared cursor and the haptics have no
    /// meaning.
    ///
    /// `nonisolated` and Sendable-extracting for the reason this file already
    /// documents at the sendMessage call site: WCSession invokes delegate
    /// methods on its own queue, and a plainly-declared method on a
    /// `@MainActor` type traps off-main.
    nonisolated func session(_ session: WCSession,
                             didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchSnapshot.contextKey] as? Data else { return }
        // Registers the spawned work via `registerIngestTask` so
        // `drainWatchConnectivity()` has an actual handle to await instead
        // of the `hasContentPending` signal, which only reflects delivery
        // to this method, not completion of `ingestComplicationPayload`.
        Task { @MainActor in
            self.registerIngestTask { self.ingestComplicationPayload(data) }
        }
    }

    private func ingestComplicationPayload(_ data: Data) {
        guard let frame = try? WatchSnapshot.decode(data),
              let gameID = frame.hostGameID,
              let candidate = WatchWidgetLiveSource.snapshot(
                from: frame,
                fallbackName: libraryName?(gameID),
                capturedAt: Date()) else { return }
        // `immediate`: refreshing the tile is the entire purpose of the wake,
        // so the reload floor does not apply. The mirror's monotonic rule
        // still rejects a late-delivered older payload.
        widgetMirror?.mirrorLive(candidate, immediate: true)
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }
}
