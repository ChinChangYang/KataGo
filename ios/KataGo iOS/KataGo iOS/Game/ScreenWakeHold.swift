//
//  ScreenWakeHold.swift
//  KataGo iOS
//
//  Feedback 2026-08-31: "Add an option to prevent the screen from turning
//  off when a stone is just played by AI for a few seconds." On a 30-second
//  Auto-Lock a long think locked the phone before, or just after, the
//  engine's stone appeared.
//
//  The one place the iOS app touches the idle timer. The rule is
//  `ScreenWakePolicy` (pure, tested); this is the adapter that feeds it the
//  live inputs and writes `UIApplication.shared.isIdleTimerDisabled`. It
//  releases on every path out (inactive scene, another game, disappearing)
//  because a leaked hold is the one failure worse than the complaint.
//

import SwiftUI
import KataGoUICore

struct ScreenWakeHold: ViewModifier {
    @Environment(GobanState.self) private var gobanState
    @Environment(Stones.self) private var stones
    @Environment(Turn.self) private var player
    @Environment(NavigationContext.self) private var navigationContext
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(GlobalSettingsKeys.keepScreenAwake)
    private var keepScreenAwake = ScreenWakePolicy.defaultEnabled

    /// When the AI's last stone landed in this game.
    @State private var lastLandingAt: Date?
    /// When the current hold last saw an activity event (see the policy).
    @State private var holdStartedAt: Date?
    /// Advanced by the deadline task: a static board after the AI's move
    /// changes nothing observable, and the tail and the ceiling are wall-clock
    /// expiries that need a clock tick of their own.
    @State private var now = Date()
    @State private var wasOwing = false
    @State private var wasAutoPlaying = false

    /// The app is waiting on a stone: the AI side is to move, the engine is in
    /// sync with the board, and no overwrite confirmation is parked on the
    /// reply (while one is, `shouldGenMove` stays true with nothing running).
    private var engineOwesMove: Bool {
        guard let config = navigationContext.selectedGameRecord?.config else { return false }
        return gobanState.shouldGenMove(config: config, player: player)
            && stones.isReady
            && !gobanState.confirmingAIOverwrite
    }

    private var desired: Bool {
        ScreenWakePolicy.shouldHold(
            enabled: keepScreenAwake,
            engineOwesMove: engineOwesMove,
            secondsSinceAIMove: lastLandingAt.map { now.timeIntervalSince($0) },
            isAutoPlaying: gobanState.isAutoPlaying,
            isActive: scenePhase == .active,
            holdAge: holdStartedAt.map { now.timeIntervalSince($0) })
    }

    /// The next moment the answer can change on its own: the tail's end, or
    /// the ceiling while a hold is on.
    private var nextDeadline: Date? {
        var deadlines: [Date] = []
        if let lastLandingAt {
            deadlines.append(lastLandingAt.addingTimeInterval(ScreenWakePolicy.tailSeconds))
        }
        if let holdStartedAt, desired {
            deadlines.append(holdStartedAt.addingTimeInterval(ScreenWakePolicy.ceilingSeconds))
        }
        return deadlines.filter { $0 > now }.min()
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: engineOwesMove, initial: true) { _, isOwing in
                if isOwing && !wasOwing { touch() }
                wasOwing = isOwing
            }
            .onChange(of: gobanState.isAutoPlaying, initial: true) { _, playing in
                if playing && !wasAutoPlaying { touch() }
                wasAutoPlaying = playing
            }
            .onChange(of: gobanState.aiMoveLandingGeneration) { _, _ in
                lastLandingAt = .now
                touch()
            }
            .onChange(of: stones.positionGeneration) { _, _ in
                // Every auto-play step re-projects the board; each one is
                // activity, so a long replay never trips the ceiling.
                if gobanState.isAutoPlaying { touch() }
            }
            .onChange(of: navigationContext.selectedGameRecord?.persistentModelID) { _, _ in
                lastLandingAt = nil
                holdStartedAt = nil
                now = .now
            }
            // The flag is written from a change handler, never from body.
            .onChange(of: desired, initial: true) { _, hold in
                UIApplication.shared.isIdleTimerDisabled = hold
                #if DEBUG
                NSLog("ScreenWakeHold: isIdleTimerDisabled=%@ (owes=%@ autoPlay=%@)",
                      hold ? "true" : "false",
                      engineOwesMove ? "true" : "false",
                      gobanState.isAutoPlaying ? "true" : "false")
                #endif
            }
            .task(id: nextDeadline) {
                guard let deadline = nextDeadline else { return }
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                now = .now
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
    }

    /// A fresh activity event: the hold's age restarts from now.
    private func touch() {
        holdStartedAt = .now
        now = .now
    }
}
