//
//  EngineStatusView.swift
//  KataGoUICore
//
//  Engine availability, shown INLINE where analysis would appear — never as a
//  screen that replaces the board. Renders nothing at all while the engine is
//  ready, which is what makes it a status line rather than a gate.
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

    /// Held's remedy is the pill itself: tapping the "Board larger than Max
    /// Board Size N" line opens the model chooser — no button row (tester
    /// feedback: a button under that headline crowded the pill). Every other
    /// state keeps its buttons; a Held with no actions (macOS, tvOS) stays a
    /// bare, inert line.
    private var tapOpensChooser: Bool {
        if case .held = status.availability {
            return status.actions.contains(.chooseModel)
        }
        return false
    }

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
            if !status.actions.isEmpty, !tapOpensChooser {
                HStack(spacing: 12) {
                    if status.actions.contains(.retry) {
                        Button("Retry") { status.perform(.retry) }
                            .accessibilityIdentifier("EngineStatus.retry")
                    }
                    if status.actions.contains(.chooseModel) {
                        Button("Choose model") { status.perform(.chooseModel) }
                            .accessibilityIdentifier("EngineStatus.chooseModel")
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }
        }
        .multilineTextAlignment(.leading)
        // Text WRAPS only with fixedSize; lineLimit alone truncates. Both, so a
        // long failure reason at an accessibility text size grows the pill
        // instead of being cut off mid-sentence.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, style == .inline ? 12 : 0)
        .padding(.vertical, style == .inline ? 8 : 0)
        .background {
            if style == .inline {
                // A rounded rect rather than a true capsule: a capsule clips its
                // own corners as soon as the content is more than one line, and
                // a failure reason at an accessibility size always is.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thinMaterial)
            }
        }

        Group {
            if tapOpensChooser {
                // A real Button, not a tap gesture: the whole pill activates,
                // VoiceOver gets the button trait, and Voice Control can speak
                // the headline. `.plain` keeps the pill looking like the line
                // it replaces. The board's overlay only takes touches when
                // actions are non-empty (BoardView), which Held's
                // `[.chooseModel]` guarantees.
                Button { status.perform(.chooseModel) } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
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
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thinMaterial)
            }
            .accessibilityIdentifier("Board.unreadableRecord")
    }
}
