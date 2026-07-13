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
    /// X — undo one move.
    case undo
    /// Y — pass (immediate).
    case pass
    /// L1 / R1 — cycle the ghost through the analysis candidates.
    case cycle(forward: Bool)
}

@Observable
@MainActor
final class VisionControllerInput {
    private(set) var isConnected = false

    @ObservationIgnored var onEvent: ((ControllerEvent) -> Void)?

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
        guard let pad = currentPad else { return }
        bind(pad.buttonA, to: .play)
        bind(pad.buttonB, to: .toggleAnalysisVisibility)
        bind(pad.buttonX, to: .undo)
        bind(pad.buttonY, to: .pass)
        bind(pad.leftShoulder, to: .cycle(forward: false))
        bind(pad.rightShoulder, to: .cycle(forward: true))
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

    /// Left stick with a radial deadzone; +y = stick forward = away from the
    /// viewer (+BoardPoint.y). Polled once per render frame.
    func readLeftStick() -> SIMD2<Float> {
        guard let pad = currentPad else { return .zero }
        let value = SIMD2<Float>(pad.leftThumbstick.xAxis.value,
                                 pad.leftThumbstick.yAxis.value)
        return simd_length(value) < 0.15 ? .zero : value
    }
}
