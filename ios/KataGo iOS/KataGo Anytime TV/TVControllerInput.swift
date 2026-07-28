//
//  TVControllerInput.swift
//  KataGo Anytime TV
//
//  GCController plumbing for the focus-SAFE buttons only. Ported from
//  VisionControllerInput, minus everything that does not exist on tvOS:
//  `.handlesGameControllerEvents(matching:)` and `GCEventInteraction` are
//  API_UNAVAILABLE(tvos), and none is needed — the tvOS default already
//  delivers controller input through the responder chain (so the focus engine
//  drives the UI) while GameController element handlers fire alongside it.
//
//  NEVER install a GCEventViewController: its controllerUserInteractionEnabled
//  defaults to false, which suppresses UIEvents from controllers and would kill
//  the focus engine, TVSelectPressCatcher, .onMoveCommand, .onExitCommand and
//  .onPlayPauseCommand in one stroke.
//
//  ONE owner, a handler STACK: `pressedChangedHandler` is a single assignable
//  slot per button, and the review screen and the self-play screen coexist on
//  the same NavigationStack path — two owners would silently clobber each other
//  and leave the review screen's bindings dead after a pop.
//

import Foundation
import GameController
import Observation
import KataGoUICore

@Observable
@MainActor
final class TVControllerInput {
    /// True only for a real gamepad: the Siri Remote vends microGamepad /
    /// directionalGamepad, never extendedGamepad.
    private(set) var isConnected = false
    /// For the Settings section's heading. Nullable and not unique per Apple.
    private(set) var vendorName: String?

    /// LIFO: only the topmost screen receives events.
    @ObservationIgnored
    private var handlers: [(token: UUID, handler: (TVControllerEvent) -> Void)] = []

    @ObservationIgnored
    private var repeatTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// L1/R1 hold-repeat cadence: first repeat after the delay, then steady.
    private static let repeatInitialDelay: Duration = .milliseconds(400)
    private static let repeatInterval: Duration = .milliseconds(125)

    @ObservationIgnored
    private nonisolated(unsafe) var observerTokens: [NSObjectProtocol] = []

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

    // MARK: - Subscribers

    func pushHandler(_ token: UUID, _ handler: @escaping (TVControllerEvent) -> Void) {
        handlers.removeAll { $0.token == token }
        handlers.append((token, handler))
    }

    func popHandler(_ token: UUID) {
        handlers.removeAll { $0.token == token }
    }

    private func deliver(_ event: TVControllerEvent) {
        handlers.last?.handler(event)
    }

    // MARK: - Pad

    /// GCController.current on tvOS is "the most recently used controller",
    /// which is frequently the Siri Remote (extendedGamepad nil) — the fallback
    /// is what keeps the bindings alive after the user touches the remote.
    private var currentPad: GCExtendedGamepad? {
        GCController.current?.extendedGamepad
            ?? GCController.controllers().compactMap(\.extendedGamepad).first
    }

    private func refreshConnection() {
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
        isConnected = !pads.isEmpty
        vendorName = pads.first?.vendorName
        bindButtons()
    }

    private func bindButtons() {
        // A pad that just vanished never delivers its release edge.
        cancelRepeats()
        guard let pad = currentPad else { return }
        bind(pad.buttonX, to: .buttonX)
        bind(pad.buttonY, to: .buttonY)
        bindRepeating(pad.leftShoulder, to: .leftShoulder)
        bindRepeating(pad.rightShoulder, to: .rightShoulder)
        bind(pad.leftTrigger, to: .leftTrigger)
        bind(pad.rightTrigger, to: .rightTrigger)
        // buttonA / buttonB / buttonMenu / dpad are NOT bound — the focus
        // engine already delivers them as UIPress events.
    }

    /// The handler block is a plain ObjC block on GCDevice.handlerQueue, not
    /// statically MainActor-isolated under Swift 6 — hop explicitly.
    private func bind(_ button: GCControllerButtonInput, to event: TVControllerEvent) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor in self?.deliver(event) }
        }
    }

    /// One event on the press edge, then auto-repeat while held. The loop
    /// re-checks `button.isPressed` so a lost release edge can never wedge a
    /// runaway repeat — which on the review screen would run the timeline away.
    private func bindRepeating(_ button: GCControllerButtonInput, to event: TVControllerEvent) {
        let key = ObjectIdentifier(button)
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in
                guard let self else { return }
                self.repeatTasks.removeValue(forKey: key)?.cancel()
                guard pressed else { return }
                self.deliver(event)
                self.repeatTasks[key] = Task { @MainActor [weak self, weak button] in
                    try? await Task.sleep(for: Self.repeatInitialDelay)
                    while !Task.isCancelled, let self, let button, button.isPressed {
                        self.deliver(event)
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
}
