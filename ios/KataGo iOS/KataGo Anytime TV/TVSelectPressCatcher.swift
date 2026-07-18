//
//  TVSelectPressCatcher.swift
//  KataGo Anytime TV
//
//  Deterministic window-level press handling: the Select CATCHER (consumes a
//  press as an action) and the arrow-press MONITOR (observes press down/up,
//  consuming nothing).
//
//  Catcher: SwiftUI's .onTapGesture on a bare .focusable() view dropped the
//  FIRST Select click after every played move on tvOS 26 devices (reported
//  2026-07-17) — the third undocumented tvOS 26 input behavior after
//  "onMoveCommand is only a fallback" and "FocusState writes are post-render
//  requests". tvSelectPress(isEnabled:perform:) takes SwiftUI's gesture
//  recognition out of the loop: a UITapGestureRecognizer restricted to the
//  Select press type, attached to the WINDOW (press events route through the
//  focused item's responder chain, so the window is the one observation point
//  that sees them no matter which SwiftUI view holds focus), armed only while
//  isEnabled.
//
//  INVARIANT for every tvSelectPress call site: while isEnabled is true,
//  NOTHING else on screen may want Select — the recognizer observes
//  window-wide, so an enabled catcher plus a live Select target (button,
//  dialog, overlay) would double-handle one press. The aiming boards satisfy
//  this by disabling the side panel and timeline while aiming; attract mode
//  by having no other focusable at all; the self-play game-over interstitial
//  by disarming the catcher outright.
//
//  The monitor (tvArrowPressMonitor) is EXEMPT from that invariant: it never
//  recognizes, never consumes, never delays — pure observation — so arming
//  it window-wide while the focus engine and focused views keep responding
//  to the same arrow presses is safe by construction.
//

import SwiftUI

extension View {
    /// Run `action` on a single Siri-Remote Select press while `isEnabled`.
    /// Use this instead of .onTapGesture on any focusable tvOS surface (see
    /// the file header for why the tap gesture cannot be trusted there).
    func tvSelectPress(isEnabled: Bool,
                       perform action: @escaping () -> Void) -> some View {
        background(TVSelectPressCatcher(isEnabled: isEnabled,
                                        onSelect: action))
    }
}

struct TVSelectPressCatcher: UIViewRepresentable {
    var isEnabled: Bool
    var onSelect: () -> Void

    func makeUIView(context: Context) -> CatcherView {
        let view = CatcherView()
        // The view itself must never intercept anything: it exists only to
        // reach the window and host the recognizer's target.
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: CatcherView, context: Context) {
        view.onSelect = onSelect
        view.recognizer.isEnabled = isEnabled
    }

    static func dismantleUIView(_ view: CatcherView, coordinator: ()) {
        view.detachRecognizer()
    }

    final class CatcherView: UIView {
        lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self,
                                                    action: #selector(fire))
            recognizer.allowedPressTypes =
                [NSNumber(value: UIPress.PressType.select.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.isEnabled = false
            return recognizer
        }()

        var onSelect: () -> Void = {}

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // recognizer.view IS the window it is attached to (or nil) — the
            // single source of truth for re-homing on window changes and for
            // detaching when the screen unmounts.
            guard recognizer.view !== window else { return }
            detachRecognizer()
            window?.addGestureRecognizer(recognizer)
        }

        func detachRecognizer() {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }

        @objc private func fire() {
            onSelect()
        }
    }
}

extension View {
    /// Observe (never consume) Siri-Remote left/right edge presses window-wide
    /// while `isEnabled`, reporting raw press down/up. Feed the events into a
    /// TimelineStepClassifier to tell an edge click from a touch-surface
    /// swipe — the press events are the only signal that distinguishes them,
    /// because both deliver the identical SwiftUI move command.
    func tvArrowPressMonitor(isEnabled: Bool,
                             onPressBegan: @escaping () -> Void,
                             onPressEnded: @escaping () -> Void) -> some View {
        background(TVArrowPressMonitor(isEnabled: isEnabled,
                                       onPressBegan: onPressBegan,
                                       onPressEnded: onPressEnded))
    }
}

struct TVArrowPressMonitor: UIViewRepresentable {
    var isEnabled: Bool
    var onPressBegan: () -> Void
    var onPressEnded: () -> Void

    func makeUIView(context: Context) -> MonitorView {
        let view = MonitorView()
        // Same as the catcher: the view exists only to reach the window.
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: MonitorView, context: Context) {
        view.observer.onPressBegan = onPressBegan
        view.observer.onPressEnded = onPressEnded
        view.observer.isEnabled = isEnabled
    }

    static func dismantleUIView(_ view: MonitorView, coordinator: ()) {
        view.detachObserver()
    }

    final class MonitorView: UIView {
        lazy var observer = ArrowPressObserver()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // observer.view IS the window it is attached to (or nil) — the
            // single source of truth for re-homing on window changes and for
            // detaching when the screen unmounts.
            guard observer.view !== window else { return }
            detachObserver()
            window?.addGestureRecognizer(observer)
        }

        func detachObserver() {
            observer.view?.removeGestureRecognizer(observer)
        }
    }

    /// None of the press overrides assigns `state`: the recognizer sits in
    /// .possible forever, so UIKit can never treat it as recognized and
    /// cancel or claim the press from the focused responder / focus engine —
    /// the move command must keep firing; this type only watches it happen.
    final class ArrowPressObserver: UIGestureRecognizer {
        var onPressBegan: () -> Void = {}
        var onPressEnded: () -> Void = {}

        private static let arrowTypes: Set<UIPress.PressType> = [.leftArrow, .rightArrow]

        /// One entry per physical press currently down. Keyboard-style
        /// auto-repeat (a paired keyboard, or the Simulator) redelivers
        /// pressesBegan for the SAME held press on every repeat — without
        /// this dedupe each repeat would increment the classifier's
        /// down-count that only one release ever decrements, wedging every
        /// later swipe into a click.
        private var trackedPresses = Set<ObjectIdentifier>()

        override var isEnabled: Bool {
            didSet {
                // Disarming mid-press means the releases will never arrive;
                // drop the tracking so a stale identifier can't eat the
                // began of an (address-reused) future press.
                if !isEnabled { trackedPresses.removeAll() }
            }
        }

        init() {
            super.init(target: nil, action: nil)
            allowedPressTypes = Self.arrowTypes.map { NSNumber(value: $0.rawValue) }
            // Observation must never hold up or cancel anyone else's events.
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            isEnabled = false
        }

        // The in-override type filter backs up allowedPressTypes — its
        // delivery semantics for plain UIGestureRecognizer subclasses are
        // underdocumented, and a stray .select or .menu press slipping
        // through would corrupt the classifier's down-count.

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            for press in presses where Self.arrowTypes.contains(press.type) {
                guard trackedPresses.insert(ObjectIdentifier(press)).inserted else { continue }
                onPressBegan()
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            forwardRelease(of: presses)
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            forwardRelease(of: presses)
        }

        private func forwardRelease(of presses: Set<UIPress>) {
            for press in presses where Self.arrowTypes.contains(press.type) {
                trackedPresses.remove(ObjectIdentifier(press))
                // Forward even an untracked release (armed mid-press): the
                // classifier clamps its count and still wants the grace
                // timestamp refreshed.
                onPressEnded()
            }
        }
    }
}
