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
    static let complicationKind = "ScoreLeadWidget"

    private(set) var latest: WatchSnapshot?
    private(set) var receivedAt: Date?
    let peek = WatchPeekBuffer()
    /// Ticks every 5 s so `isStale` re-evaluates without new frames.
    private(set) var now = Date()
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var lastComplicationReload: Date?
    @ObservationIgnored private var lastComplicationScore: Float?

    var isStale: Bool {
        WatchSnapshot.isStale(receivedAt: receivedAt, now: now, threshold: Self.staleAfter)
    }

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
        mirrorComplication(snapshot)
    }

    /// Budget-friendly: reload the complication only on a ≥0.5-point change
    /// and at most every 30 s.
    private func mirrorComplication(_ snapshot: WatchSnapshot) {
        let defaults = UserDefaults(suiteName: Self.appGroupID)
        defaults?.set(Double(snapshot.rootScoreLeadBlack), forKey: "watchScoreLeadBlack")
        defaults?.set(snapshot.hostTimestamp, forKey: "watchScoreUpdatedAt")
        let scoreDelta = abs((lastComplicationScore ?? .infinity) - snapshot.rootScoreLeadBlack)
        let elapsed = now.timeIntervalSince(lastComplicationReload ?? .distantPast)
        guard scoreDelta >= 0.5, elapsed >= 30 else { return }
        lastComplicationScore = snapshot.rootScoreLeadBlack
        lastComplicationReload = now
        WidgetCenter.shared.reloadTimelines(ofKind: Self.complicationKind)
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
        Task { @MainActor in
            guard self.latest == nil, let data else { return }
            self.ingest(data, receivedAt: nil)
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchSnapshot.contextKey] as? Data else { return }
        Task { @MainActor in self.ingest(data, receivedAt: Date()) }
    }
}
