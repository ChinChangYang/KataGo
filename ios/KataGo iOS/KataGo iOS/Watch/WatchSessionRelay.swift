import Foundation
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

    func start(session gameSession: GameSession) {
        guard WCSession.isSupported() else { return }   // iPad: no-op
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

    private func pushIfChanged(from gameSession: GameSession) {
        let wcSession = WCSession.default
        guard wcSession.activationState == .activated,
              wcSession.isPaired, wcSession.isWatchAppInstalled else { return }
        let snapshot = WatchSnapshotBuilder.makeSnapshot(session: gameSession)
        // Equality must ignore the timestamp, or every tick "changes".
        if var previous = lastSent {
            previous.hostTimestamp = snapshot.hostTimestamp
            if previous == snapshot { return }
        }
        guard let data = try? snapshot.encodedData() else { return }
        do {
            try wcSession.updateApplicationContext([WatchSnapshot.contextKey: data])
            lastSent = snapshot
        } catch {
            // Transient WCSession errors (e.g. not activated yet): drop the
            // frame; the next changed tick retries. Latest-wins semantics make
            // skipped frames harmless.
        }
    }

    // MARK: WCSessionDelegate (iOS side requires all three)
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()   // re-activate after watch switch, per Apple docs
    }
}
