//
//  EngineStatusHeaderModel.swift
//  KataGoUICore
//
//  The words the remedy surface's engine-status header shows. The resting
//  engine states (Absent, Failed, Held) no longer overlay the board (ADR
//  0010); the model-selection surface is where they are explained and fixed,
//  and this model decides what that explanation says.
//
//  Pure, so the strings are pinned by tests. Reuses `EngineStatusText`'s
//  headlines so the wording cannot drift from what the (Launching-only) board
//  pill and the tvOS line say.
//

import Foundation

public struct EngineStatusHeaderModel: Equatable, Sendable {
    /// Where the Held hint points its reader. The Max Board Size control and
    /// the alternative nets live in different places per platform, so the
    /// hint's wording differs while its logic (raise vs switch) is shared.
    public enum HeldHintStyle: Equatable, Sendable {
        /// iOS: Max Board Size is in the model's Backend Settings sheet.
        case iosBackendSettings
        /// macOS: the Manage Models window's detail pane.
        case macDetailPane
        /// visionOS: the Models ornament's per-model settings.
        case visionInline
    }

    /// "No model chosen" / "Loading engine…" / "Engine failed" / the Held
    /// headline. Nil when a ready engine has nothing to say.
    public let stateLine: String?
    /// The failure reason verbatim, or the compile caption while a compile is
    /// genuinely running.
    public let detail: String?
    /// The host-owned aside ("⟨title⟩ was removed — using the built-in
    /// network"), true of a perfectly ready engine.
    public let note: String?
    /// Whether a Retry button is offered. Follows the status's seeded actions,
    /// so the failed-last-launch policy (Choose model only, never a retry
    /// loop) holds here without restating it.
    public let showsRetry: Bool
    /// The Held remedy pointer, when held: which way out (raise Max Board
    /// Size vs switch nets) and where to find it.
    public let heldHint: String?

    public init(stateLine: String?, detail: String?, note: String?,
                showsRetry: Bool, heldHint: String?) {
        self.stateLine = stateLine
        self.detail = detail
        self.note = note
        self.showsRetry = showsRetry
        self.heldHint = heldHint
    }

    /// True when the header would show nothing at all — a ready engine with no
    /// note. The view renders no section in that case.
    public var isEmpty: Bool {
        stateLine == nil && detail == nil && note == nil && !showsRetry && heldHint == nil
    }

    /// - Parameters:
    ///   - boardWidth/boardHeight: the PROJECTED record position's size (what
    ///     `EngineHeldRule` was fed). Only the Held hint reads them.
    ///   - modelBoardCap: the active net's own board cap (`nnLen`), deciding
    ///     whether raising Max Board Size can ever fit this board. Nil means
    ///     "unknown", which reads as raisable — the optimistic wording.
    public static func make(availability: EngineAvailability,
                            isCompiling: Bool,
                            note: String?,
                            actions: [EngineStatusAction],
                            boardWidth: Int,
                            boardHeight: Int,
                            modelBoardCap: Int?,
                            heldHintStyle: HeldHintStyle) -> EngineStatusHeaderModel {
        let showsRetry = actions.contains(.retry)
        switch availability {
        case .launching:
            return EngineStatusHeaderModel(
                stateLine: EngineStatusText.loadingHeadline + "…",
                detail: isCompiling ? EngineStatusText.compilingCaption : nil,
                note: note, showsRetry: showsRetry, heldHint: nil)
        case .absent:
            return EngineStatusHeaderModel(
                stateLine: EngineStatusText.absentHeadline,
                detail: nil, note: note, showsRetry: showsRetry, heldHint: nil)
        case .failed(let reason):
            return EngineStatusHeaderModel(
                stateLine: EngineStatusText.failedHeadline,
                detail: reason, note: note, showsRetry: showsRetry, heldHint: nil)
        case .held(let maxBoardLength):
            return EngineStatusHeaderModel(
                stateLine: EngineStatusText.heldHeadline(maxBoardLength: maxBoardLength),
                detail: nil, note: note, showsRetry: showsRetry,
                heldHint: heldHint(boardWidth: boardWidth,
                                   boardHeight: boardHeight,
                                   maxBoardLength: maxBoardLength,
                                   modelBoardCap: modelBoardCap,
                                   style: heldHintStyle))
        case .ready:
            // The note is deliberately NOT dropped: a ready engine running the
            // built-in fallback still has something to say — here, now that
            // the board no longer carries it.
            return EngineStatusHeaderModel(
                stateLine: nil, detail: nil, note: note,
                showsRetry: showsRetry, heldHint: nil)
        }
    }

    /// The Held remedy, with the raise-vs-switch decision the visionOS
    /// "Board Too Large" card used to make: a capped net (its own `nnLen`
    /// below this board) can never be raised far enough, so the honest exit
    /// there is switching nets.
    static func heldHint(boardWidth: Int, boardHeight: Int,
                         maxBoardLength: Int, modelBoardCap: Int?,
                         style: HeldHintStyle) -> String {
        let raisable: Bool
        if let cap = modelBoardCap {
            raisable = boardWidth <= cap && boardHeight <= cap
        } else {
            raisable = true
        }
        let board = "This game uses a \(boardWidth)×\(boardHeight) board, "
        if raisable {
            let location: String
            switch style {
            case .iosBackendSettings:
                location = "in the model's Backend Settings"
            case .macDetailPane, .visionInline:
                location = "in the model's settings below"
            }
            return board + "larger than the current Max Board Size (\(maxBoardLength)×\(maxBoardLength)). Analysis is off until you raise Max Board Size \(location)."
        } else {
            let cap = modelBoardCap ?? maxBoardLength
            return board + "larger than the current neural net supports (\(cap)×\(cap)). Analysis is off until you switch the neural net."
        }
    }
}
