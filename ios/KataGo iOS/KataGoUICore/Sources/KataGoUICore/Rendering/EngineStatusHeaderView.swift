//
//  EngineStatusHeaderView.swift
//  KataGoUICore
//
//  The engine-status header the remedy surfaces mount above their model list
//  (iOS's model picker sheet, macOS's Manage Models window, visionOS's Models
//  ornament). It says what the removed resting pills used to say — the state,
//  the failure reason, the Held remedy, the built-in-fallback note — and
//  carries the Retry button, routed through the same `EngineStatusAction`
//  seam the pill used.
//
//  Accessibility identifiers use the `EngineHeader.` prefix, NEVER
//  `EngineStatus.`: the UI suite's `waitForBoardInSync` treats any surviving
//  `EngineStatus.`-prefixed element as "the engine is not ready yet", and this
//  header may legitimately be on screen (showing a note) with a ready engine.
//

import SwiftUI

public struct EngineStatusHeaderView: View {
    private let status: EngineStatus
    private let launchStatus: EngineLaunchStatus?
    private let board: BoardSize?
    private let modelBoardCap: Int?
    private let hintStyle: EngineStatusHeaderModel.HeldHintStyle

    /// - Parameters:
    ///   - launchStatus: nil on macOS — its subprocess engine has no
    ///     compile-status channel back to the app (ADR 0007's deliberate gap).
    ///   - board: the live projected record position's size, for the Held
    ///     hint. Nil when the host has no board to speak of.
    ///   - modelBoardCap: the active net's own `nnLen`, deciding the Held
    ///     hint's raise-vs-switch wording.
    public init(status: EngineStatus,
                launchStatus: EngineLaunchStatus? = nil,
                board: BoardSize? = nil,
                modelBoardCap: Int? = nil,
                hintStyle: EngineStatusHeaderModel.HeldHintStyle) {
        self.status = status
        self.launchStatus = launchStatus
        self.board = board
        self.modelBoardCap = modelBoardCap
        self.hintStyle = hintStyle
    }

    public var body: some View {
        let model = EngineStatusHeaderModel.make(
            availability: status.availability,
            isCompiling: launchStatus?.isCompiling ?? false,
            note: status.note,
            actions: status.actions,
            boardWidth: Int(board?.width ?? 0),
            boardHeight: Int(board?.height ?? 0),
            modelBoardCap: modelBoardCap,
            heldHintStyle: hintStyle)
        if !model.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let stateLine = model.stateLine {
                    Text(stateLine)
                        .font(.subheadline.weight(.semibold))
                }
                if let detail = model.detail {
                    line(detail)
                }
                if let heldHint = model.heldHint {
                    line(heldHint)
                }
                if let note = model.note {
                    line(note)
                        .accessibilityIdentifier("EngineHeader.note")
                }
                if model.showsRetry {
                    Button("Retry") { status.perform(.retry) }
                        .accessibilityIdentifier("EngineHeader.retry")
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Text WRAPS only with fixedSize; lineLimit alone truncates, and a
            // failure reason has no length bound.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("EngineHeader.container")
        }
    }

    private func line(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
