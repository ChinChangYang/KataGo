//
//  EngineStatusView.swift
//  KataGoUICore
//
//  Engine availability, shown INLINE where analysis would appear — never as a
//  screen that replaces the board. Renders nothing at all while the engine is
//  ready, which is what makes it a status line rather than a gate.
//
//  Since ADR 0010 the board hosts mount this only for the TRANSIENT Launching
//  state (and tvOS its side-panel line): the resting states (Absent, Failed,
//  Held) surface through the analysis control instead, and their remedies
//  live in `EngineStatusHeaderView` on the model-selection surface. The pill
//  is inert again — it narrates a wait, it is not a control.
//
//  Three styles because the chrome differs, not the content: `.inline` draws
//  its own pill over the board (iOS/macOS), `.ornament` lets the visionOS
//  ornament be the chrome, and `.tvLine` is the ONE fixed short line tvOS can
//  afford (see `EngineStatusText.tvLine` — never the raw failure reason, which
//  has no length bound and would clip).
//

import SwiftUI

public struct EngineStatusView: View {
    public enum Style: Sendable {
        /// A pill over the top of the board (iOS, macOS).
        case inline
        /// Bare content: the host's ornament/panel supplies the background.
        case ornament
        /// One fixed short line, 10-foot legible, never wrapped or truncated.
        case tvLine
    }

    private let status: EngineStatus
    private let launchStatus: EngineLaunchStatus?
    private let style: Style

    /// Ticks the trailing dots onto the headline, so "Loading engine…" answers
    /// the user's actual question — whether the app is stuck.
    @State private var dotCount = 0

    /// - Parameter launchStatus: optional because macOS does not inject one —
    ///   its engine is a subprocess with no compile-status channel back to the
    ///   app (ADR 0007's deliberate gap). A nil one simply means "not
    ///   compiling", which on macOS is all the app can honestly say.
    public init(status: EngineStatus,
                launchStatus: EngineLaunchStatus? = nil,
                style: Style = .inline) {
        self.status = status
        self.launchStatus = launchStatus
        self.style = style
    }

    private var isCompiling: Bool { launchStatus?.isCompiling ?? false }
    private var isLaunching: Bool { status.availability == .launching }

    public var body: some View {
        let text = EngineStatusText.decide(availability: status.availability,
                                           isCompiling: isCompiling,
                                           note: status.note)
        // Ready says nothing, and "nothing" means no view — not an empty pill.
        if text.headline == nil, text.secondary == nil, text.note == nil {
            EmptyView()
        } else if style == .tvLine {
            tvLine
        } else {
            stack(text)
        }
    }

    // MARK: - tvOS

    @ViewBuilder
    private var tvLine: some View {
        if let line = EngineStatusText.tvLine(availability: status.availability,
                                              isCompiling: isCompiling) {
            Text(line)
                .font(.title3)
                .foregroundStyle(.secondary)
                // Nothing on a tvOS screen may wrap or truncate; the strings
                // are fixed and short precisely so this never has to. The
                // scale factor is the belt to that braces: `lineLimit(1)`
                // alone TRUNCATES, so at an accessibility text size the line
                // shrinks rather than losing its tail.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityIdentifier(status.availability.accessibilityIdentifier
                                         ?? Self.noteIdentifier)
        }
    }

    // MARK: - Inline / ornament

    @ViewBuilder
    private func stack(_ text: (headline: String?, secondary: String?, note: String?)) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            if let headline = text.headline {
                Text(headline + String(repeating: ".", count: isLaunching ? dotCount : 0))
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText())
            }
            if let secondary = text.secondary {
                line(secondary)
            }
            if let note = text.note {
                line(note)
            }
        }
        .multilineTextAlignment(.leading)
        // Text WRAPS only with fixedSize; lineLimit alone truncates. Both, so a
        // long failure reason at an accessibility text size grows the pill
        // instead of being cut off mid-sentence.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, style == .inline ? 12 : 0)
        .padding(.vertical, style == .inline ? 8 : 0)
        // Only `.inline` wears chrome of its own: the visionOS ornament card
        // supplies `glassBackgroundEffect()` around `.ornament`, and the tvOS
        // side panel carries its own material around `.tvLine`.
        .boardOverlayChrome(enabled: style == .inline)

        content
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(status.availability.accessibilityIdentifier
                                 ?? Self.noteIdentifier)
        .task(id: isLaunching) {
            // Only the launching state ticks; every other state is static and
            // must not keep a timer alive behind the board.
            guard isLaunching else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                withAnimation {
                    dotCount = (dotCount + 1) % 4
                }
            }
        }
    }

    private func line(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(4)
    }

    /// A READY engine with a note (the built-in-fallback message) still renders.
    /// Its identifier deliberately does NOT start with `EngineStatus.`, because
    /// the UI suite's `waitForBoardInSync` treats any such element as "the
    /// engine is not ready yet" — and this one says the opposite.
    private static let noteIdentifier = "Board.engineNote"
}

/// The record — not the engine — is the problem: the C++ SGF parser rejected
/// this game, so no position could be replayed and the engine was fed nothing.
/// Shown regardless of engine availability, because it is true regardless.
public struct UnreadableRecordView: View {
    public init() {}

    public var body: some View {
        Text("Can't read this game")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .boardOverlayChrome(enabled: true)
            .accessibilityIdentifier("Board.unreadableRecord")
    }
}

// MARK: - Board-overlay chrome

/// The one chrome the board ever wears over itself. The launch pill and the
/// unreadable-record line share it, so the two never mismatch when both are
/// up (they stack 6 pt apart in `BoardView`).
///
/// Liquid Glass, the app's style for floating chrome, in a 14 pt continuous
/// rounded rect rather than a true capsule: a capsule clips its own corners
/// as soon as the content is more than one line, and the compile caption or
/// an accessibility text size always makes it one. `.regular`, not `.clear`:
/// the pill sits over the wood texture, and `.clear` is meant for media the
/// user must keep seeing through, with a dimming layer of its own. Inert
/// glass, no `.interactive()`: ADR 0010 made the pill a narration, not a
/// control, and `BoardView` keeps it out of hit testing.
///
/// `#if os(visionOS)` and NOT the `|| os(tvOS)` this package uses elsewhere
/// for glass button styles: in the 26 SDKs `glassEffect` is
/// `@available(iOS 26, macOS 26, tvOS 26, watchOS 26, *)` with
/// `@available(visionOS, unavailable)`, so visionOS is the only platform that
/// cannot compile it (DeepReportView records the same reasoning). visionOS
/// never mounts the `.inline` pill, so its branch exists to keep the package
/// building and keeps the material the pill wore before.
private extension View {
    @ViewBuilder
    func boardOverlayChrome(enabled: Bool) -> some View {
        if enabled {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
#if os(visionOS)
            self.background(shape.fill(.thinMaterial))
#else
            self.glassEffect(.regular, in: shape)
#endif
        } else {
            self
        }
    }
}
