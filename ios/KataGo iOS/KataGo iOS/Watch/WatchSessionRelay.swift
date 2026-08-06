import Foundation
import UIKit
import WatchConnectivity
import KataGoUICore
import KataGoGameStore

/// iPhone→watch push: every 500 ms build a WatchSnapshot from the live
/// GameSession and, when it differs from the last sent frame, push it via
/// updateApplicationContext (latest-wins, no reachability needed — WCSession
/// delivers the newest context when the watch wakes). Equality gating means
/// an idle board sends nothing after the first frame.
@MainActor
final class WatchSessionRelay: NSObject, WCSessionDelegate {
    private var lastSent: WatchSnapshot?
    private var loopTask: Task<Void, Never>?

    private weak var gameSession: GameSession?
    private weak var navigationContext: NavigationContext?
    private weak var audioModel: AudioModel?
    /// SgfOperations parses the whole SGF — memoize moveSize per SGF string so
    /// the 500 ms tick doesn't re-parse a long game.
    private var moveCountMemo: (sgf: String, count: Int?)?
    /// Content key and time of the last complication payload enqueued, so a
    /// heartbeat that changes nothing the tile shows never spends a transfer.
    /// Persisted (see `WatchComplicationPushThrottle`), not a plain property —
    /// an in-memory-only value forgets itself on every process relaunch.
    private let pushThrottle: WatchComplicationPushThrottle

    /// `pushThrottleDefaults` defaults to `.standard` for the real app; tests
    /// inject a throwaway suite so they never touch the developer's own
    /// defaults domain.
    init(pushThrottleDefaults: UserDefaults = .standard) {
        pushThrottle = WatchComplicationPushThrottle(defaults: pushThrottleDefaults)
        super.init()
    }

    func start(session gameSession: GameSession,
               navigationContext: NavigationContext,
               audioModel: AudioModel) {
        guard WCSession.isSupported() else { return }   // iPad: no-op
        self.gameSession = gameSession
        self.navigationContext = navigationContext
        self.audioModel = audioModel
        let wcSession = WCSession.default
        wcSession.delegate = self
        wcSession.activate()

        loopTask?.cancel()
        loopTask = Task { [weak self, weak gameSession] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let gameSession else { return }
                self.pushIfChanged(from: gameSession)
            }
        }
    }

    private func currentMoveCount(for gameRecord: GameRecord?) -> Int? {
        guard let sgf = gameRecord?.sgf else { return nil }
        if moveCountMemo?.sgf != sgf {
            moveCountMemo = (sgf, SgfOperations(sgf: sgf).moveSize)
        }
        return moveCountMemo?.count
    }

    private func pushIfChanged(from gameSession: GameSession) {
        let wcSession = WCSession.default
        guard wcSession.activationState == .activated,
              wcSession.isPaired, wcSession.isWatchAppInstalled else { return }
        let gameRecord = navigationContext?.selectedGameRecord
        let snapshot = WatchSnapshotBuilder.makeSnapshot(
            session: gameSession, gameRecord: gameRecord,
            moveCount: currentMoveCount(for: gameRecord))
        // Equality must ignore the timestamp, or every tick "changes".
        if var previous = lastSent {
            previous.hostTimestamp = snapshot.hostTimestamp
            if previous == snapshot { return }
        }
        guard let data = try? snapshot.encodedData() else { return }
        do {
            try wcSession.updateApplicationContext([WatchSnapshot.contextKey: data])
            lastSent = snapshot
            pushComplicationIfDue(snapshot, data: data,
                                  session: wcSession, now: snapshot.hostTimestamp)
        } catch {
            // Transient WCSession errors (e.g. not activated yet): drop the
            // frame; the next changed tick retries. Latest-wins semantics make
            // skipped frames harmless.
        }
    }

    /// Wake the watch app in the background so the complication updates
    /// without the user opening it.
    ///
    /// Degrades rather than hard-gates. `isComplicationEnabled` is true only
    /// while the tile sits on an ACTIVE watch face; a Smart-Stack-only
    /// placement leaves it false and `remainingComplicationUserInfoTransfers`
    /// at zero. In that case a plain `transferUserInfo` still lands the next
    /// time the watch app runs, which is no worse than the application context
    /// already achieves — and correctness never depends on this path.
    private func pushComplicationIfDue(_ snapshot: WatchSnapshot,
                                       data: Data,
                                       session: WCSession,
                                       now: Date) {
        guard let key = WatchWidgetLiveSource.pushKey(for: snapshot) else { return }
        let elapsed = now.timeIntervalSince(pushThrottle.lastPushedAt ?? .distantPast)
        guard WatchWidgetRefreshPolicy.shouldPush(previousKey: pushThrottle.lastPushedKey,
                                                  nextKey: key,
                                                  elapsed: elapsed) else { return }

        // Sweep our own stale transfers first. The queue is FIFO, and the
        // header is explicit that re-tagging a new payload as current only
        // UNTAGS the previous one — it stays queued and can be delivered AFTER
        // the newer frame. The watch's monotonic clock rule makes that
        // harmless, but there is no reason to spend delivery on it.
        for transfer in session.outstandingUserInfoTransfers
        where transfer.userInfo[WatchSnapshot.contextKey] != nil {
            transfer.cancel()
        }

        if session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
            session.transferCurrentComplicationUserInfo([WatchSnapshot.contextKey: data])
        } else {
            session.transferUserInfo([WatchSnapshot.contextKey: data])
        }
        pushThrottle.recordPush(key: key, at: now)
    }

    // MARK: WCSessionDelegate (iOS side requires all three)
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()   // re-activate after watch switch, per Apple docs
        // Clear the equality gate so the newly active watch gets a frame even
        // from an idle board (otherwise the unchanged snapshot is suppressed).
        Task { @MainActor in self.lastSent = nil }
    }

    // MARK: Watch→phone commands (v1.1 write path)

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        // Extract the Sendable Data before hopping (house Swift 6 pattern);
        // box the reply closure — WCSession documents it callable from any
        // queue, but the SDK import may lack @Sendable.
        let data = message[WatchCommand.messageKey] as? Data
        let reply = UncheckedSendableBox(replyHandler)
        Task { @MainActor in
            let result: WatchCommandReply
            if let gameSession = self.gameSession {
                result = WatchCommandHandler.handle(
                    data: data,
                    session: gameSession,
                    gameRecord: self.navigationContext?.selectedGameRecord,
                    moveCount: self.currentMoveCount(for: self.navigationContext?.selectedGameRecord),
                    audioModel: self.audioModel,
                    hostIsActive: UIApplication.shared.applicationState != .background)
            } else {
                result = WatchCommandReply(accepted: false, reason: "No active game")
            }
            let payload = (try? result.encodedData()) ?? Data()
            reply.value([WatchCommandReply.messageKey: payload])
        }
    }
}

/// WCSession's replyHandler is documented callable from any queue; box it for
/// the MainActor hop in case the SDK import lacks @Sendable. Harmless if the
/// signature is already @Sendable.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Rate-limit bookkeeping for `WatchSessionRelay.pushComplicationIfDue`,
/// persisted to phone-local `UserDefaults` rather than kept as plain
/// in-memory properties.
///
/// Why persisted: iOS backgrounds and kills this app routinely — far more
/// often than a user force-quit — and `WatchWidgetRefreshPolicy.shouldPush`
/// returns true unconditionally when `previousKey` is nil, which is correct
/// for a genuine first push and wrong for "the process merely relaunched".
/// Plain properties reset to nil on every launch and reopen that unthrottled
/// branch for the next changed frame; against a budget of roughly 50
/// complication transfers a day, that is plausibly 10-20 wasted transfers
/// daily, not a rare edge. A future reader who sees only `var lastPushedKey`
/// might "simplify" this back to a plain property, so this comment (and the
/// dedicated test in WatchComplicationPushThrottleTests.swift) exist to head
/// that off.
///
/// Deliberately `UserDefaults.standard`, NOT the App Group: the watch never
/// reads this state — it is purely how the PHONE throttles its own pushes —
/// and the App Group is a watch-local channel (see `WatchWidgetDefaults`);
/// storing phone-only state there would mislead a future reader into
/// thinking the watch consumes it.
struct WatchComplicationPushThrottle {
    /// Shared prefix so both keys read as a pair in a `defaults` dump and any
    /// future addition to this struct is obviously grouped with them.
    private static let keyPrefix = "WatchComplicationPushThrottle."
    static let lastPushedKeyDefaultsKey = keyPrefix + "lastPushedKey"
    static let lastPushedAtDefaultsKey = keyPrefix + "lastPushedAt"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Read directly from `defaults` on every access (never cached at init),
    /// so a freshly constructed instance — e.g. after a background relaunch —
    /// always sees whatever the previous process last wrote.
    var lastPushedKey: String? {
        defaults.string(forKey: Self.lastPushedKeyDefaultsKey)
    }

    var lastPushedAt: Date? {
        defaults.object(forKey: Self.lastPushedAtDefaultsKey) as? Date
    }

    /// Write both fields after a successful enqueue. `UserDefaults` is a
    /// reference type, so this needs no `mutating` keyword and the struct can
    /// be held as a `let`.
    func recordPush(key: String, at date: Date) {
        defaults.set(key, forKey: Self.lastPushedKeyDefaultsKey)
        defaults.set(date, forKey: Self.lastPushedAtDefaultsKey)
    }
}
