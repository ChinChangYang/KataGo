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
    let hiddenAnalysisVisitRatio: Float

    /// Thumbstick glide rate, in intersections per second at full deflection.
    private static let glideSpeed: Float = 8

    var body: some View {
        GeometryReader3D { proxy in
            let candidates = candidateMarkers
            let candidatePoints = Set(candidates.map(\.point))
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
                let showOwnership = session.gobanState.showOwnership
                let ownershipUnits = session.analysis.ownershipUnits
                let snapshot = SceneSnapshot(
                    width: Int(session.board.width),
                    height: Int(session.board.height),
                    black: session.stones.blackPoints,
                    white: session.stones.whitePoints,
                    stonesReady: session.stones.isReady,
                    ghostPoint: ghost.point,
                    nextColor: session.player.nextColorForPlayCommand,
                    candidates: candidates,
                    analysisVisible: analysisVisible,
                    analysisInformation: session.gobanState.analysisInformation,
                    // Candidate points render their ownership inside the
                    // marker attachment (see candidateMarkers) — a scene
                    // quad there would draw OVER the circle, because
                    // RealityKit cannot sort transparents behind
                    // attachment planar UI.
                    ownership: (showOwnership ? ownershipUnits : [])
                        .filter { !candidatePoints.contains($0.point) },
                    isBoardStanding: shell.isBoardStanding,
                    isBranchActive: session.gobanState.isBranchActive
                )
                syncScene(snapshot)
                syncMarkers(snapshot, attachments: attachments)
            } attachments: {
                ForEach(candidates) { marker in
                    Attachment(id: marker.vertex) {
                        VisionCandidateMarkerView(mark: marker.mark)
                    }
                }
            }
        }
    }

    /// Top analysis candidates as flat-marker view-models. 2D parity for the
    /// Analysis information setting: None hides the whole candidate layer
    /// (ownership is gated separately). The ring keys on max utilityLcb over
    /// ALL info points, so it can vanish when that point falls outside the
    /// top-N list — accepted divergence (the 2D board draws every info
    /// point).
    private var candidateMarkers: [VisionBoardSceneModel.CandidateMarker] {
        guard !session.gobanState.isAnalysisInformationNone else { return [] }
        let information = session.gobanState.analysisInformation
        let maxVisits = max(1, session.analysis.maxVisits ?? 1)
        let maxUtilityLcb = session.analysis.info.values.map(\.utilityLcb).max()
        let spacing = sceneModel.cellSpacing
        // Same gate as the scene quads: no squares when ownership is off.
        let ownershipByPoint = session.gobanState.showOwnership
            ? Dictionary(session.analysis.ownershipUnits.map { ($0.point, $0) },
                         uniquingKeysWith: { first, _ in first })
            : [:]
        return session.analysis
            .candidateMoves(width: Int(session.board.width),
                            height: Int(session.board.height),
                            limit: VisionBoardSceneModel.candidateMoveLimit)
            .map { candidate in
                VisionBoardSceneModel.CandidateMarker(
                    point: candidate.point,
                    vertex: candidate.vertex,
                    mark: VisionCandidateMark.make(
                        visits: candidate.visits,
                        maxVisits: maxVisits,
                        utilityLcb: candidate.utilityLcb,
                        maxUtilityLcb: maxUtilityLcb,
                        hiddenAnalysisVisitRatio: hiddenAnalysisVisitRatio,
                        analysisInformation: information,
                        winrate: candidate.winrate,
                        scoreLead: candidate.scoreLead,
                        cellSpacingX: spacing.x,
                        cellSpacingZ: spacing.z,
                        ownership: ownershipByPoint[candidate.point]))
            }
    }

    /// Per-frame stick poll driving the ghost glide. RealityKit delivers
    /// scene updates on the main thread.
    private func subscribeToFrameUpdates(content: RealityViewContent) {
        sceneModel.frameSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
            MainActor.assumeIsolated {
                let stick = controllerInput.readLeftStick()
                guard stick != .zero, sceneModel.boardWidth > 0 else { return }
                let dt = Float(event.deltaTime)
                ghost.glide(dColumn: stick.x * Self.glideSpeed * dt,
                            dRow: stick.y * Self.glideSpeed * dt,
                            width: sceneModel.boardWidth,
                            height: sceneModel.boardHeight)
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
        let analysisVisible: Bool
        let analysisInformation: Int
        let ownership: [OwnershipUnit]
        let isBoardStanding: Bool
        let isBranchActive: Bool
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

        if sceneModel.boardWidth != snapshot.width || sceneModel.boardHeight != snapshot.height {
            guard !sceneModel.isLoadingBoard else { return }
            Task { @MainActor in
                try? await sceneModel.loadBoard(width: snapshot.width, height: snapshot.height)
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
        sceneModel.applyOwnership(snapshot.ownership)
        sceneModel.setBranchFrame(active: snapshot.isBranchActive)
    }

    private func syncMarkers(_ snapshot: SceneSnapshot, attachments: RealityViewAttachments) {
        for marker in snapshot.candidates {
            if let entity = attachments.entity(for: marker.vertex) {
                sceneModel.mountMarker(entity, marker: marker)
            }
        }
        sceneModel.removeStaleMarkers(current: Set(snapshot.candidates.map(\.vertex)))
    }
}

/// The whole flat 2D-parity candidate marker — AnalysisView's circle + text
/// without glass or shadow: visits-hue fill, blue max-utilityLcb ring, black
/// fit-to-circle monospaced text with the winrate line bold. Rendered
/// supersampled; the scene model scales the attachment entity back down.
private struct VisionCandidateMarkerView: View {
    let mark: VisionCandidateMark

    var body: some View {
        ZStack {
            // The intersection's ownership, beneath the circle — the same
            // gray square the scene draws on non-candidate points (those
            // points are filtered out of the quad overlay; see
            // VisionCandidateMark.OwnershipSquare).
            if let square = mark.ownership {
                Rectangle()
                    .fill(Color(white: square.whiteness)
                        .opacity(square.opacity))
                    .frame(width: mark.framePoints * square.widthFraction,
                           height: mark.framePoints * square.heightFraction)
            }
            Circle()
                .fill(Color(hue: mark.hue, saturation: 1, brightness: 1))
                .opacity(mark.opacity)
            if mark.showsRing {
                Circle()
                    .stroke(.blue, lineWidth: mark.ringLineWidthPoints)
            }
            if !mark.labelLines.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(mark.labelLines.enumerated()),
                            id: \.offset) { index, line in
                        Text(line)
                            .contentTransition(.numericText())
                            .font(.system(size: 500, design: .monospaced))
                            .minimumScaleFactor(0.01)
                            .bold(index == mark.boldLineIndex)
                            .foregroundStyle(.black)
                    }
                }
            }
        }
        .frame(width: mark.framePoints, height: mark.framePoints)
        // Purely decorative (L1/R1 cycles candidates) — keep the hosted
        // attachment out of gaze targeting so it can never soak up a
        // controller press or a pinch.
        .allowsHitTesting(false)
    }
}
