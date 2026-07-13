//
//  VisionBoardRealityView.swift
//  KataGo Anytime Vision
//
//  Hosts the RealityKit board scene in the volume. The update closure reads
//  the session observables (stones, board size, ghost) so SwiftUI re-runs it
//  on every engine sync, and the scene model diffs entities accordingly.
//

import SwiftUI
import RealityKit
import KataGoUICore

struct VisionBoardRealityView: View {
    let session: GameSession
    let ghost: GhostCursorModel
    let sceneModel: VisionBoardSceneModel
    let controllerInput: VisionControllerInput
    let shell: VisionGameShell

    /// Thumbstick glide rate, in intersections per second at full deflection.
    private static let glideSpeed: Float = 8

    var body: some View {
        GeometryReader3D { proxy in
            let candidates = candidateMarkers
            let maxVisits = max(1, session.analysis.maxVisits ?? 1)
            let analysisVisible = session.gobanState.eyeStatus == .opened

            RealityView { content, _ in
                content.add(sceneModel.volumeRoot)
                alignToVolumeFloor(content: content, proxy: proxy)
                subscribeToFrameUpdates(content: content)
            } update: { content, attachments in
                alignToVolumeFloor(content: content, proxy: proxy)
                // Read EVERY observable dependency unconditionally, right
                // here in the update closure: reads deferred into the async
                // board-load Task are invisible to SwiftUI's dependency
                // tracking, and the view would never update again.
                let snapshot = SceneSnapshot(
                    width: Int(session.board.width),
                    height: Int(session.board.height),
                    black: session.stones.blackPoints,
                    white: session.stones.whitePoints,
                    stonesReady: session.stones.isReady,
                    ghostPoint: ghost.point,
                    nextColor: session.player.nextColorForPlayCommand,
                    candidates: candidates,
                    maxVisits: maxVisits,
                    analysisVisible: analysisVisible,
                    isBoardStanding: shell.isBoardStanding
                )
                syncScene(snapshot)
                syncLabels(snapshot, attachments: attachments)
            } attachments: {
                ForEach(candidates) { marker in
                    Attachment(id: marker.vertex) {
                        Text("\(Int((marker.winrate * 100).rounded()))%")
                            .font(marker.isBest ? .caption.bold() : .caption2)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .glassBackgroundEffect()
                    }
                }
            }
        }
    }

    /// Top analysis candidates as marker view-models; `[0]` is the best move.
    private var candidateMarkers: [VisionBoardSceneModel.CandidateMarker] {
        session.analysis
            .candidateMoves(width: Int(session.board.width),
                            height: Int(session.board.height),
                            limit: 8)
            .enumerated()
            .map { index, candidate in
                VisionBoardSceneModel.CandidateMarker(point: candidate.point,
                                                      vertex: candidate.vertex,
                                                      visits: candidate.visits,
                                                      winrate: candidate.winrate,
                                                      isBest: index == 0)
            }
    }

    /// Per-frame stick poll driving the ghost glide. RealityKit delivers
    /// scene updates on the main thread.
    private func subscribeToFrameUpdates(content: RealityViewContent) {
        sceneModel.frameSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
            MainActor.assumeIsolated {
                let stick = controllerInput.readLeftStick()
                guard stick != .zero, sceneModel.boardSize > 0 else { return }
                let dt = Float(event.deltaTime)
                ghost.glide(dColumn: stick.x * Self.glideSpeed * dt,
                            dRow: stick.y * Self.glideSpeed * dt,
                            width: sceneModel.boardSize,
                            height: sceneModel.boardSize)
            }
        }
    }

    /// One frame's worth of observable state, captured inside the update
    /// closure so SwiftUI tracks all of it.
    struct SceneSnapshot {
        let width: Int
        let height: Int
        let black: [BoardPoint]
        let white: [BoardPoint]
        let stonesReady: Bool
        let ghostPoint: BoardPoint?
        let nextColor: PlayerColor
        let candidates: [VisionBoardSceneModel.CandidateMarker]
        let maxVisits: Int
        let analysisVisible: Bool
        let isBoardStanding: Bool
    }

    /// The board asset's feet rest on y=0, so seating it on the volume floor
    /// is a single y-offset of the root (risk noted in the plan: keep this in
    /// one place).
    private func alignToVolumeFloor(content: RealityViewContent, proxy: GeometryProxy3D) {
        let frame = proxy.frame(in: .local)
        let bounds = content.convert(frame, from: .local, to: .scene)
        let position = SIMD3<Float>(0, bounds.min.y, 0)
        if sceneModel.volumeRoot.position != position {
            sceneModel.volumeRoot.position = position
            #if DEBUG
            NSLog("VisionScene align volumeRoot=(%.3f, %.3f, %.3f) sceneBounds min=(%.3f, %.3f, %.3f) max=(%.3f, %.3f, %.3f) localFrame=(%.0f x %.0f x %.0f)",
                  position.x, position.y, position.z,
                  bounds.min.x, bounds.min.y, bounds.min.z,
                  bounds.max.x, bounds.max.y, bounds.max.z,
                  frame.size.width, frame.size.height, frame.size.depth)
            #endif
        }
    }

    private func syncScene(_ snapshot: SceneSnapshot) {
        guard visionBoardIsSupported(width: snapshot.width, height: snapshot.height) else { return }

        if sceneModel.boardSize != snapshot.width {
            guard !sceneModel.isLoadingBoard else { return }
            Task { @MainActor in
                try? await sceneModel.loadBoard(size: snapshot.width)
                applyDynamicState(snapshot)
            }
        } else {
            applyDynamicState(snapshot)
        }
    }

    private func applyDynamicState(_ snapshot: SceneSnapshot) {
        sceneModel.setOrientation(standing: snapshot.isBoardStanding, animated: true)
        sceneModel.applyStones(black: snapshot.black, white: snapshot.white)
        sceneModel.setGhost(point: snapshot.ghostPoint, color: snapshot.nextColor)
        sceneModel.analysisRoot.isEnabled = snapshot.analysisVisible
        sceneModel.applyCandidates(snapshot.candidates, maxVisits: snapshot.maxVisits)
    }

    private func syncLabels(_ snapshot: SceneSnapshot, attachments: RealityViewAttachments) {
        for marker in snapshot.candidates {
            if let entity = attachments.entity(for: marker.vertex) {
                sceneModel.mountLabel(entity, vertex: marker.vertex, point: marker.point)
            }
        }
        sceneModel.removeStaleLabels(current: Set(snapshot.candidates.map(\.vertex)))
    }
}
