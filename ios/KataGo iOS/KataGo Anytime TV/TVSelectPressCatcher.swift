//
//  TVSelectPressCatcher.swift
//  KataGo Anytime TV
//
//  Deterministic Select handling. SwiftUI's .onTapGesture on a bare
//  .focusable() view dropped the FIRST Select click after every played move
//  on tvOS 26 devices (reported 2026-07-17) — the third undocumented tvOS 26
//  input behavior after "onMoveCommand is only a fallback" and "FocusState
//  writes are post-render requests". tvSelectPress(isEnabled:perform:) takes
//  SwiftUI's gesture recognition out of the loop: a UITapGestureRecognizer
//  restricted to the Select press type, attached to the WINDOW (press events
//  route through the focused item's responder chain, so the window is the
//  one observation point that sees them no matter which SwiftUI view holds
//  focus), armed only while isEnabled.
//
//  INVARIANT for every call site: while isEnabled is true, NOTHING else on
//  screen may want Select — the recognizer observes window-wide, so an
//  enabled catcher plus a live Select target (button, dialog, overlay) would
//  double-handle one press. The aiming boards satisfy this by disabling the
//  side panel and timeline while aiming; attract mode by having no other
//  focusable at all; the self-play game-over interstitial by disarming the
//  catcher outright.
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
