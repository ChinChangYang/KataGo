//
//  VisionBoardSceneModel.swift
//  KataGo Anytime Vision
//
//  Owns the RealityKit entity graph for the 3D goban and diffs engine state
//  into it. Write-side only — VisionBoardRealityView's update closure reads
//  the observables and calls into here.
//
//  Entity hierarchy:
//    volumeRoot                (floor-aligned by the hosting RealityView)
//    └── boardRoot
//        ├── board model       (go_board_NxN.usdz, feet on y=0)
//        ├── stonesRoot        (one clone per placed stone)
//        ├── ghostRoot         (semi-transparent aiming stone)
//        └── analysisRoot      (candidate markers + labels)
//

import Foundation
import RealityKit
import SwiftUI
import KataGoUICore

@MainActor
final class VisionBoardSceneModel {
    enum LoadError: Error {
        case missingAsset(String)
    }

    let volumeRoot = Entity()
    let analysisRoot = Entity()

    private let boardRoot = Entity()
    private let stonesRoot = Entity()
    private let ghostRoot = Entity()

    private(set) var geometry: BoardSceneGeometry?
    private(set) var boardSize = 0
    private(set) var isLoadingBoard = false

    /// Retains the RealityView frame-update subscription (stick polling).
    var frameSubscription: EventSubscription?

    private var manifest: BoardAssetManifest?
    private var boardModel: Entity?
    private var stonePrototypes: [PlayerColor: Entity] = [:]
    private var placed: [BoardPoint: (color: PlayerColor, entity: Entity)] = [:]
    private var ghostEntity: Entity?
    private var ghostColor: PlayerColor = .unknown

    init() {
        volumeRoot.addChild(boardRoot)
        boardRoot.addChild(stonesRoot)
        boardRoot.addChild(ghostRoot)
        boardRoot.addChild(analysisRoot)
    }

    // MARK: - Loading

    private static func assetURL(_ name: String, ext: String) throws -> URL {
        guard let url = Bundle.main.url(
            forResource: name, withExtension: ext, subdirectory: "BoardAssets") else {
            throw LoadError.missingAsset("\(name).\(ext)")
        }
        return url
    }

    /// The USDZ meshes declare `doubleSided = 1`, but RealityKit ignores that
    /// flag and back-face-culls — lathe-built legs/slab sides vanish into
    /// lens-shaped slivers. Honor the assets' declared intent by disabling
    /// face culling on every loaded material.
    private static func disableFaceCulling(in entity: Entity) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                if var pbr = material as? PhysicallyBasedMaterial {
                    pbr.faceCulling = .none
                    return pbr
                }
                if var unlit = material as? UnlitMaterial {
                    unlit.faceCulling = .none
                    return unlit
                }
                if var simple = material as? SimpleMaterial {
                    simple.faceCulling = .none
                    return simple
                }
                return material
            }
            entity.components.set(model)
        }
        entity.children.forEach { disableFaceCulling(in: $0) }
    }

    private func loadManifestIfNeeded() throws -> BoardAssetManifest {
        if let manifest { return manifest }
        let data = try Data(contentsOf: Self.assetURL("boards_manifest", ext: "json"))
        let parsed = try BoardAssetManifest.parse(data)
        manifest = parsed
        return parsed
    }

    /// Swaps in the `size`×`size` board model (real scale, feet on y=0) and
    /// resets the stone layer. No-op while a load is in flight or when the
    /// size is already mounted.
    func loadBoard(size: Int) async throws {
        guard size != boardSize, !isLoadingBoard else { return }
        isLoadingBoard = true
        defer { isLoadingBoard = false }

        let manifest = try loadManifestIfNeeded()
        guard let entry = manifest.entry(forSquareSize: size) else {
            throw LoadError.missingAsset("go_board_\(size)x\(size).usdz")
        }

        if stonePrototypes.isEmpty {
            let black = try await Entity(contentsOf: Self.assetURL("stone_black", ext: "usdz"))
            let white = try await Entity(contentsOf: Self.assetURL("stone_white", ext: "usdz"))
            Self.disableFaceCulling(in: black)
            Self.disableFaceCulling(in: white)
            stonePrototypes[.black] = black
            stonePrototypes[.white] = white
        }

        let board = try await Entity(contentsOf: Self.assetURL(entry.fileUSDZ.replacingOccurrences(of: ".usdz", with: ""), ext: "usdz"))
        Self.disableFaceCulling(in: board)
        boardModel?.removeFromParent()
        boardModel = board
        boardRoot.addChild(board)

        // Normalize whatever transform the USDZ loader produced back to the
        // asset contract (footprint center at the origin, feet on y=0), so
        // manifest intersection coordinates land exactly on the drawn grid.
        let local = board.visualBounds(relativeTo: boardRoot)
        board.position -= SIMD3<Float>(local.center.x, local.min.y, local.center.z)
        #if DEBUG
        NSLog("VisionScene normalize localBounds center=(%.3f, %.3f, %.3f) min.y=%.3f -> boardPos=(%.3f, %.3f, %.3f)",
              local.center.x, local.center.y, local.center.z, local.min.y,
              board.position.x, board.position.y, board.position.z)
        #endif

        geometry = BoardSceneGeometry(entry: entry)
        boardSize = size

        #if DEBUG
        let bounds = board.visualBounds(relativeTo: nil)
        NSLog("VisionScene loadBoard n=%d file=%@ extents=(%.3f, %.3f, %.3f) center=(%.3f, %.3f, %.3f)",
              size, entry.fileUSDZ,
              bounds.extents.x, bounds.extents.y, bounds.extents.z,
              bounds.center.x, bounds.center.y, bounds.center.z)
        #endif

        placed.values.forEach { $0.entity.removeFromParent() }
        placed.removeAll()
        setGhost(point: nil, color: .unknown)
        analysisRoot.children.forEach { $0.removeFromParent() }
    }

    // MARK: - Stones

    /// Diffs the engine's stone lists against the mounted entities —
    /// O(changed), not O(board).
    func applyStones(black: [BoardPoint], white: [BoardPoint]) {
        guard let geometry else { return }

        var desired: [BoardPoint: PlayerColor] = [:]
        black.forEach { desired[$0] = .black }
        white.forEach { desired[$0] = .white }
        // A pass is encoded as an off-board sentinel point — never mount it.
        desired = desired.filter { geometry.position(of: $0.key) != nil }

        for (point, current) in placed where desired[point] != current.color {
            current.entity.removeFromParent()
            placed.removeValue(forKey: point)
        }

        for (point, color) in desired where placed[point] == nil {
            guard let prototype = stonePrototypes[color],
                  let position = geometry.position(of: point) else { continue }
            let stone = prototype.clone(recursive: true)
            stone.position = position
            stone.transform.rotation = simd_quatf(angle: Self.grainAngle(for: point),
                                                  axis: [0, 1, 0])
            stonesRoot.addChild(stone)
            placed[point] = (color, stone)
            #if DEBUG
            NSLog("VisionScene stone %@ at (%d,%d) pos=(%.4f, %.4f, %.4f)",
                  color == .black ? "black" : "white", point.x, point.y,
                  position.x, position.y, position.z)
            #endif
        }
    }

    /// Deterministic per-point grain rotation: stones look naturally varied
    /// but don't spin when the board re-syncs.
    private static func grainAngle(for point: BoardPoint) -> Float {
        let hash = UInt32(bitPattern: Int32(truncatingIfNeeded: point.x &* 73_856_093 ^ point.y &* 19_349_663))
        return Float(hash % 360) * .pi / 180
    }

    // MARK: - Orientation

    private var isStanding = false
    private var hasAppliedOrientation = false

    /// Lays the board flat on the volume floor (tabletop) or stands it
    /// upright facing the viewer (wall demonstration board). Standing rotates
    /// boardRoot +90° about X, which maps the board's +Y (up) onto +Z (toward
    /// the viewer): row 1 lands at the bottom and the legs point away — and
    /// the controller's +row stick direction stays visually "up".
    func setOrientation(standing: Bool, animated: Bool) {
        guard standing != isStanding || !hasAppliedOrientation else { return }
        isStanding = standing
        hasAppliedOrientation = true

        var target = Transform.identity
        if standing {
            target.rotation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            // Vertically centered in the 0.6 m volume (root sits on the
            // floor); the rotated grid spans ±depth/2 about this point.
            target.translation = [0, 0.3, 0]
        }

        if animated {
            boardRoot.move(to: target, relativeTo: volumeRoot, duration: 0.5,
                           timingFunction: .easeInOut)
        } else {
            boardRoot.transform = target
        }
    }

    // MARK: - Analysis markers

    /// View-model for one candidate move's 3D marker + label.
    struct CandidateMarker: Equatable, Identifiable {
        let point: BoardPoint
        let vertex: String
        let visits: Int
        let winrate: Float
        let isBest: Bool
        var id: String { vertex }
    }

    private var markerEntities: [BoardPoint: ModelEntity] = [:]
    private var bestBackingEntity: ModelEntity?
    private var labelEntities: [String: Entity] = [:]
    private var markerMesh: MeshResource?
    private var bestBackingMesh: MeshResource?
    /// Material cache keyed by the discretized hue (21 buckets) — recreating
    /// materials every analysis tick is the plan's noted jank risk.
    private var markerMaterials: [Int: UnlitMaterial] = [:]

    private var markerRadius: Float {
        Float(manifest?.stoneRef.diameter ?? 0.0224) * 0.45
    }

    func applyCandidates(_ candidates: [CandidateMarker], maxVisits: Int) {
        guard let geometry else { return }

        let desired = Set(candidates.map(\.point))
        for (point, entity) in markerEntities where !desired.contains(point) {
            entity.removeFromParent()
            markerEntities.removeValue(forKey: point)
        }

        if markerMesh == nil {
            markerMesh = MeshResource.generateCylinder(height: 0.002, radius: markerRadius)
        }

        for candidate in candidates {
            guard let position = geometry.position(of: candidate.point) else { continue }
            let material = markerMaterial(visits: candidate.visits, maxVisits: maxVisits)
            let entity: ModelEntity
            if let existing = markerEntities[candidate.point] {
                entity = existing
                entity.model?.materials = [material]
            } else {
                entity = ModelEntity(mesh: markerMesh!, materials: [material])
                analysisRoot.addChild(entity)
                markerEntities[candidate.point] = entity
            }
            entity.position = position + SIMD3<Float>(0, 0.0015, 0)
            entity.scale = candidate.isBest ? [1.35, 1, 1.35] : .one
        }

        updateBestBacking(candidates: candidates, geometry: geometry)
    }

    /// A white disc under the best move — the "distinct" treatment on top of
    /// the shared quality hue.
    private func updateBestBacking(candidates: [CandidateMarker], geometry: BoardSceneGeometry) {
        guard let best = candidates.first(where: \.isBest),
              let position = geometry.position(of: best.point) else {
            bestBackingEntity?.removeFromParent()
            bestBackingEntity = nil
            return
        }
        if bestBackingEntity == nil {
            if bestBackingMesh == nil {
                bestBackingMesh = MeshResource.generateCylinder(height: 0.001, radius: markerRadius * 1.6)
            }
            let entity = ModelEntity(mesh: bestBackingMesh!,
                                     materials: [UnlitMaterial(color: .white)])
            analysisRoot.addChild(entity)
            bestBackingEntity = entity
        }
        bestBackingEntity?.position = position + SIMD3<Float>(0, 0.0008, 0)
    }

    private func markerMaterial(visits: Int, maxVisits: Int) -> UnlitMaterial {
        let hue = analysisBaseHue(visits: visits, maxVisits: maxVisits)
        let bucket = Int((hue * 1000).rounded())
        if let cached = markerMaterials[bucket] { return cached }
        var material = UnlitMaterial(color: UIColor(analysisBaseColor(visits: visits, maxVisits: maxVisits)))
        material.faceCulling = .none
        // Color alpha alone is ignored unless blending is transparent.
        material.blending = .transparent(opacity: 0.8)
        markerMaterials[bucket] = material
        return material
    }

    /// Mounts/positions the SwiftUI label entity for a candidate; labels
    /// billboard toward the viewer above the marker.
    func mountLabel(_ entity: Entity, vertex: String, point: BoardPoint) {
        guard let geometry, let position = geometry.position(of: point) else { return }
        entity.position = position + SIMD3<Float>(0, 0.035, 0)
        entity.components.set(BillboardComponent())
        if entity.parent !== analysisRoot {
            analysisRoot.addChild(entity)
        }
        labelEntities[vertex] = entity
    }

    func removeStaleLabels(current: Set<String>) {
        for (vertex, entity) in labelEntities where !current.contains(vertex) {
            entity.removeFromParent()
            labelEntities.removeValue(forKey: vertex)
        }
    }

    // MARK: - Ghost

    /// Shows the aiming ghost stone at `point` in the to-move color, or hides
    /// it when `point` is nil.
    func setGhost(point: BoardPoint?, color: PlayerColor) {
        guard let point, let geometry, let position = geometry.position(of: point) else {
            ghostEntity?.removeFromParent()
            ghostEntity = nil
            ghostColor = .unknown
            return
        }
        if ghostEntity == nil || ghostColor != color {
            ghostEntity?.removeFromParent()
            guard let prototype = stonePrototypes[color == .white ? .white : .black] else { return }
            let ghost = prototype.clone(recursive: true)
            ghost.components.set(OpacityComponent(opacity: 0.45))
            ghostRoot.addChild(ghost)
            ghostEntity = ghost
            ghostColor = color
        }
        ghostEntity?.position = position
    }
}
