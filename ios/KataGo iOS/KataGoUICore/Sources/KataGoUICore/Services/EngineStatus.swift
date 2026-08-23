//
//  EngineStatus.swift
//  KataGoUICore
//
//  Engine availability is a STATE the board displays — never a screen that
//  replaces it. The board always shows the record position; this says whether
//  anything is able to analyse it.
//
//  The five states are the glossary's: Absent (no model chosen), Launching
//  (a model is loading, possibly compiling), Ready, Failed (with a reason and a
//  way out), and Held (the running engine's NN buffer is smaller than this
//  board). Held is a board-size answer, not a screen: the position still draws,
//  analysis and taps are simply off.
//

import Foundation
import Observation

/// What the engine can do for the board right now.
public enum EngineAvailability: Equatable, Sendable {
    /// No model has been chosen (iOS, DEBUG and the deliberate "no title
    /// persisted" case). Nothing is loading; the user has to pick.
    case absent
    /// A model is loading. `EngineLaunchStatus.isCompiling` says whether a
    /// Core ML compile is part of that wait — see ADR 0007.
    case launching
    /// The engine answered its handshake and takes commands.
    case ready
    /// The engine is not coming (a timeout, a crash, a launch that never
    /// finished). `reason` is shown verbatim on every platform but tvOS, which
    /// has one line and cannot truncate.
    case failed(reason: String)
    /// The record's board is larger than the RUNNING engine's Max Board Size.
    /// The board still draws; the engine simply cannot be fed it.
    case held(maxBoardLength: Int)

    /// The accessibility identifier the inline status view puts on its
    /// container. Nil while ready, because a ready engine renders nothing —
    /// which is also what the UI suite's `waitForBoardInSync` asserts (no
    /// element whose identifier begins with `EngineStatus.` may survive).
    public var accessibilityIdentifier: String? {
        switch self {
        case .absent: return "EngineStatus.absent"
        case .launching: return "EngineStatus.launching"
        case .ready: return nil
        case .failed: return "EngineStatus.failed"
        case .held: return "EngineStatus.held"
        }
    }
}

/// The ways out a status line can offer. The host decides which apply (only
/// iOS has a model picker) and what they do.
public enum EngineStatusAction: Equatable, Sendable {
    case retry
    case chooseModel
}

/// The observable availability state, owned by `GameSession`
/// (`session.engineStatus`) and injected into the view tree with
/// `.environment(session.engineStatus)`.
///
/// Read it as `@Environment(EngineStatus.self) var engineStatus: EngineStatus?`
/// — OPTIONAL, so a host that has not been converted yet (and therefore injects
/// nothing) behaves as it always did. Never as an `@Entry` environment key:
/// a `@MainActor` default value in the nonisolated `EnvironmentValues` context
/// is a Swift 6 error.
@MainActor @Observable
public final class EngineStatus {
    /// Starts *Launching*, not *Ready*: a session that has handshaken with
    /// nothing has, by definition, nothing to offer. Only a completed handshake
    /// moves it to `.ready`.
    public var availability: EngineAvailability = .launching

    /// A host-owned aside that is orthogonal to availability — "⟨title⟩ was
    /// removed — using the built-in network" is true of a perfectly READY
    /// engine. The session never writes it, so it survives a relaunch the host
    /// did not initiate.
    public var note: String?

    /// The ways out this state offers. The session seeds `[.retry]` on a
    /// failure and clears them on ready; a host may add `.chooseModel`.
    public var actions: [EngineStatusAction] = []

    /// The Max Board Size the RUNNING engine was launched with, i.e. the number
    /// `.held` reports. Nil until an engine has been launched.
    public var launchedMaxBoardLength: Int?

    /// The net the running engine loaded, and its `version` reply. Set by the
    /// handshake so any surface can name what is actually running.
    public var modelTitle: String?
    public var engineVersion: String?

    /// What a status button does. Wiring, not observable UI state.
    @ObservationIgnored public var onAction: ((EngineStatusAction) -> Void)?

    public var isReady: Bool { availability == .ready }

    public init() {}

    /// Invokes `onAction` for `action`. Convenience so the view does not have
    /// to reach through an optional at every button.
    public func perform(_ action: EngineStatusAction) {
        onAction?(action)
    }
}

/// The words each availability gets. Pure, so the strings are pinned by tests
/// rather than by reading them off a screenshot.
///
/// ADR 0007 lives here: the compile caption is raised only by work that really
/// is a compile, and it makes no claim about whether that work will recur.
public enum EngineStatusText {
    /// The one spelling of the Core ML compile caption. `EngineLaunchStatus`,
    /// the two launch screens and the inline status line all read it from here
    /// so it cannot drift.
    public static let compilingCaption = "Compiling Core ML model…"
    public static let loadingHeadline = "Loading engine"
    public static let absentHeadline = "No model chosen"
    public static let failedHeadline = "Engine failed"

    public static func heldHeadline(maxBoardLength: Int) -> String {
        "Board larger than Max Board Size \(maxBoardLength)"
    }

    /// The inline line's three slots. Any of them may be nil; all three nil
    /// means "render nothing at all", which is what Ready looks like.
    ///
    /// - Parameter isCompiling: `EngineLaunchStatus.isCompiling`. Only
    ///   `.launching` reads it — a compile that is somehow running while the
    ///   engine is already ready is not the board's business.
    public static func decide(availability: EngineAvailability,
                              isCompiling: Bool,
                              note: String?) -> (headline: String?, secondary: String?, note: String?) {
        switch availability {
        case .launching:
            // The view ticks the dots onto the headline, so it carries none.
            return (loadingHeadline, isCompiling ? compilingCaption : nil, note)
        case .absent:
            return (absentHeadline, nil, note)
        case .failed(let reason):
            return (failedHeadline, reason, note)
        case .held(let maxBoardLength):
            return (heldHeadline(maxBoardLength: maxBoardLength), nil, note)
        case .ready:
            // The note is deliberately NOT dropped: a ready engine running the
            // built-in fallback still has something to say.
            return (nil, nil, note)
        }
    }

    /// tvOS gets ONE short line and may never truncate or wrap, so every state
    /// maps to a fixed string — never to the engine's raw failure reason, which
    /// has no length bound.
    public static func tvLine(availability: EngineAvailability,
                              isCompiling: Bool) -> String? {
        switch availability {
        case .launching:
            // With one line to spend, the more informative one wins.
            return isCompiling ? compilingCaption : "Loading engine…"
        case .absent:
            return absentHeadline
        case .failed:
            return "Engine failed — see Settings"
        case .held(let maxBoardLength):
            return heldHeadline(maxBoardLength: maxBoardLength)
        case .ready:
            return nil
        }
    }
}

/// Why the engine stopped. The restart paths (model switch, Max Board Size,
/// Quit) ask for it and must stay silent; anything else is a failure the user
/// has to be told about.
///
/// Shared by the iOS/visionOS/tvOS engine-thread exit paths and the macOS
/// `Process` termination handler so the rule exists once.
public enum EngineExitDisposition: Equatable, Sendable {
    case expected
    case failed(reason: String)

    /// What a death with no diagnosable cause says. A jetsam/OOM kill is not a
    /// C++ exception, so nothing reaches `KataGoHelper.lastFatalError` — and a
    /// blank reason is worse than a vague one.
    public static let defaultReason = "The engine stopped."

    public static func decide(fatalError: String?,
                              stopWasRequested: Bool) -> EngineExitDisposition {
        // A requested stop stays expected even with a fatal error attached: the
        // teardown races the exception seam, and a restart must never surface a
        // failure the user did not cause.
        if stopWasRequested { return .expected }
        return .failed(reason: fatalError ?? defaultReason)
    }
}
