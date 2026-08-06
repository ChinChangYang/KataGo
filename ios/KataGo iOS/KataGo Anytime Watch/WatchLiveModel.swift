import Foundation
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit
import KataGoGameStore

/// Watch-side receiver: decodes WatchSnapshot frames from the application
/// context, feeds the peek buffer, tracks staleness, and mirrors the score
/// lead into the App Group for the complication. WCSession persists the most
/// recent application context across launches (`receivedApplicationContext`),
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

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        // Replay the persisted last context so a cold launch shows the cached
        // position (stale-badged) instead of a blank screen.
        if let data = session.receivedApplicationContext[WatchSnapshot.contextKey] as? Data {
            ingest(data, receivedAt: nil)
        }
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.now = Date()
            }
        }
    }

    func ingest(_ data: Data, receivedAt: Date?) {
        guard let snapshot = try? WatchSnapshot.decode(data) else { return }
        // Spec: haptic on live-move arrival — only for a real position change
        // on a live (not cold-replay) frame while the user is pinned to live.
        let positionChanged = latest.map { $0.positionKey != snapshot.positionKey } ?? false
        if positionChanged, receivedAt != nil, peek.isLive {
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
            if kind == .play { WKInterfaceDevice.current().play(.success) }
        } else {
            if kind == .goTo { cursor.abandon(); pendingGoToGameID = nil }
            WKInterfaceDevice.current().play(.failure)
            showRejection(reply.reason ?? "Rejected by iPhone")
        }
    }

    private func handleTransportFailure(_ message: String, for kind: WatchCommand.Kind) {
        if kind == .play { playPending = false }
        if kind == .goTo { cursor.abandon(); pendingGoToGameID = nil }
        WKInterfaceDevice.current().play(.failure)
        showRejection(message)
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
    /// `WatchWidgetMirror` now gates the WRITE on the displayed content and
    /// keeps time only as a floor.
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
        let data = session.receivedApplicationContext[WatchSnapshot.contextKey] as? Data
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            guard self.latest == nil, let data else { return }
            self.ingest(data, receivedAt: nil)
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchSnapshot.contextKey] as? Data else { return }
        Task { @MainActor in self.ingest(data, receivedAt: Date()) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }
}
