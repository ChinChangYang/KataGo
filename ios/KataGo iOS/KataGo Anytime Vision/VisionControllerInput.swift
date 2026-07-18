//
//  VisionControllerInput.swift
//  KataGo Anytime Vision
//
//  GCController plumbing: connect/disconnect tracking, button events, and a
//  per-frame left-stick read (polling beats valueChangedHandler for glide —
//  simpler and lower latency). The visionOS simulator exposes the Mac's
//  paired controller as a normal GCController, so no simulator special-case.
//

import Foundation
import GameController
import Observation
import simd
import KataGoUICore

enum ControllerEvent {
    case dpad(GhostCursorModel.StepDirection)
    /// A — play at the ghost stone.
    case play
    /// B — show/hide the analysis overlay (the eye).
    case toggleAnalysisVisibility
    /// X / L1 — one move back (mirrors iOS backward-frame). L1 auto-repeats
    /// while held; X stays single-shot.
    case undo
    /// R1 — one move forward through the recorded game (mirrors iOS
    /// forward-frame). Auto-repeats while held.
    case forward
    /// Y — pass (immediate).
    case pass
    /// L2 — jump to the start of the game (single-shot).
    case backwardToStart
    /// R2 — jump to the end of the recorded game (single-shot).
    case forwardToEnd
}

@Observable
@MainActor
final class VisionControllerInput {
    private(set) var isConnected = false

    @ObservationIgnored var onEvent: ((ControllerEvent) -> Void)?

    /// Hold-to-repeat tasks for the shoulder buttons, keyed by button identity
    /// so a re-bind or release cancels exactly its own loop. MainActor-confined.
    @ObservationIgnored private var repeatTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// L1/R1 hold-repeat cadence: first repeat after the delay, then steady.
    private static let repeatInitialDelay: Duration = .milliseconds(400)
    private static let repeatInterval: Duration = .milliseconds(125)

    @ObservationIgnored private nonisolated(unsafe) var observerTokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshConnection() }
            })
        }
        refreshConnection()
    }

    deinit {
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private var currentPad: GCExtendedGamepad? {
        GCController.current?.extendedGamepad
            ?? GCController.controllers().compactMap(\.extendedGamepad).first
    }

    private func refreshConnection() {
        isConnected = GCController.controllers().contains { $0.extendedGamepad != nil }
        bindButtons()
    }

    /// Rebound on every connect/disconnect so the handlers always live on the
    /// current pad.
    private func bindButtons() {
        // A rebind on connect/disconnect must kill any running repeat loop —
        // a pad that just vanished will never deliver its release edge.
        cancelRepeats()
        guard let pad = currentPad else { return }
        bind(pad.buttonA, to: .play)
        bind(pad.buttonB, to: .toggleAnalysisVisibility)
        bind(pad.buttonX, to: .undo)
        bind(pad.buttonY, to: .pass)
        bindRepeating(pad.leftShoulder, to: .undo)
        bindRepeating(pad.rightShoulder, to: .forward)
        bind(pad.leftTrigger, to: .backwardToStart)
        bind(pad.rightTrigger, to: .forwardToEnd)
        bind(pad.dpad.up, to: .dpad(.up))
        bind(pad.dpad.down, to: .dpad(.down))
        bind(pad.dpad.left, to: .dpad(.left))
        bind(pad.dpad.right, to: .dpad(.right))
    }

    private func bind(_ button: GCControllerButtonInput, to event: ControllerEvent) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor in self?.onEvent?(event) }
        }
    }

    /// Like bind(_:to:), but the event auto-repeats while held: one event on
    /// the press edge (preserving the single-tap feel), then after an initial
    /// delay it repeats until release. The loop double-checks
    /// button.isPressed so a press/release Task-hop inversion or a vanished
    /// release edge can never leave a runaway repeat.
    private func bindRepeating(_ button: GCControllerButtonInput, to event: ControllerEvent) {
        let key = ObjectIdentifier(button)
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in
                guard let self else { return }
                self.repeatTasks.removeValue(forKey: key)?.cancel()
                guard pressed else { return }
                self.onEvent?(event)
                self.repeatTasks[key] = Task { @MainActor [weak self, weak button] in
                    try? await Task.sleep(for: Self.repeatInitialDelay)
                    while !Task.isCancelled, let self, let button, button.isPressed {
                        self.onEvent?(event)
                        try? await Task.sleep(for: Self.repeatInterval)
                    }
                }
            }
        }
    }

    private func cancelRepeats() {
        repeatTasks.values.forEach { $0.cancel() }
        repeatTasks.removeAll()
    }

    /// Left stick with a radial deadzone; +y = stick forward = away from the
    /// viewer (+BoardPoint.y). Polled once per render frame.
    func readLeftStick() -> SIMD2<Float> {
        guard let pad = currentPad else { return .zero }
        let value = SIMD2<Float>(pad.leftThumbstick.xAxis.value,
                                 pad.leftThumbstick.yAxis.value)
        return simd_length(value) < 0.15 ? .zero : value
    }
}
