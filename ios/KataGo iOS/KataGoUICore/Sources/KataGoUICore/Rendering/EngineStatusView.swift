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

    /// The pill never shows a button row (tester feedback, twice: a button
    /// under the headline crowded the pill — first on Held, then on Absent).
    /// The pill IS the control: with exactly one way out, tapping the pill
    /// performs it; with two (a failure offering Retry and Choose model),
    /// tapping the pill opens a menu of them. A pill with no actions (macOS,
    /// tvOS) stays a bare, inert line.
    private var soleAction: EngineStatusAction? {
        status.actions.count == 1 ? status.actions.first : nil
    }

    /// The identifier the pill-as-button carries, so the UI suite can keep
    /// addressing "the Choose model button" even though the button is now the
    /// whole pill.
    private static func actionIdentifier(_ action: EngineStatusAction) -> String {
        switch action {
        case .retry: return "EngineStatus.retry"
        case .chooseModel: return "EngineStatus.chooseModel"
        }
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
            if let action = soleAction {
                // A real Button, not a tap gesture: the whole pill activates,
                // VoiceOver gets the button trait, and Voice Control can speak
                // the headline. `.plain` keeps the pill looking like the line
                // it replaces. The board's overlay only takes touches when
                // actions are non-empty (BoardView), which any tappable pill
                // guarantees.
                Button { status.perform(action) } label: { content }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(Self.actionIdentifier(action))
            } else if !status.actions.isEmpty {
                // Two ways out share one pill: tapping it offers both, so the
                // pill still carries no button row of its own.
                Menu {
                    if status.actions.contains(.retry) {
                        Button("Retry") { status.perform(.retry) }
                            .accessibilityIdentifier("EngineStatus.retry")
                    }
                    if status.actions.contains(.chooseModel) {
                        Button("Choose model") { status.perform(.chooseModel) }
                            .accessibilityIdentifier("EngineStatus.chooseModel")
                    }
                } label: {
                    content
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("EngineStatus.actions")
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
