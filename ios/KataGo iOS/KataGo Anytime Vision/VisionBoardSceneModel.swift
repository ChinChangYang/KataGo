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
    private(set) var boardWidth = 0
    private(set) var boardHeight = 0
    private(set) var isLoadingBoard = false

    /// Retains the RealityView frame-update subscription (stick polling).
    var frameSubscription: EventSubscription?

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

    /// Swaps in the board model for a `width` x `height` game and resets the
    /// stone layer. No-op while a load is in flight or when the size is
    /// already mounted. The bundled USDZs are geometry-only squares: a
    /// rectangle reuses the width-matched square asset with its slab
    /// depth-stretched and legs repositioned (BoardGeometryRules math), and
    /// every board gets its top texture generated at load time — the swap
    /// happens BEFORE the entity mounts, so the 4x4 placeholder never shows.
    func loadBoard(width: Int, height: Int) async throws {
        guard width != boardWidth || height != boardHeight, !isLoadingBoard else { return }
        isLoadingBoard = true
        defer { isLoadingBoard = false }

        if stonePrototypes.isEmpty {
            let black = try await Entity(contentsOf: Self.assetURL("stone_black", ext: "usdz"))
            let white = try await Entity(contentsOf: Self.assetURL("stone_white", ext: "usdz"))
            Self.disableFaceCulling(in: black)
            Self.disableFaceCulling(in: white)
            stonePrototypes[.black] = black
            stonePrototypes[.white] = white
        }

        let fileName = "go_board_\(width)x\(width)"
        let board = try await Entity(contentsOf: Self.assetURL(fileName, ext: "usdz"))
        Self.disableFaceCulling(in: board)
        if height != width {
            try Self.applyRectangularShape(to: board, width: width, height: height)
        }

        // Generate the top texture off-main and swap it over the placeholder
        // while the OLD board is still mounted (no hole, no flash).
        let top = await Task.detached {
            BoardTopTexture.generate(boardWidth: width, boardHeight: height)
        }.value
        try await Self.applyTopTexture(top, to: board)

        boardModel?.removeFromParent()
        boardModel = board
        boardRoot.addChild(board)

        // Normalize whatever transform the USDZ loader produced back to the
        // asset contract (footprint center at the origin, feet on y=0), so
        // computed intersection coordinates land exactly on the drawn grid.
        let local = board.visualBounds(relativeTo: boardRoot)
        board.position -= SIMD3<Float>(local.center.x, local.min.y, local.center.z)
        #if DEBUG
        NSLog("VisionScene normalize localBounds center=(%.3f, %.3f, %.3f) min.y=%.3f -> boardPos=(%.3f, %.3f, %.3f)",
              local.center.x, local.center.y, local.center.z, local.min.y,
              board.position.x, board.position.y, board.position.z)
        #endif

        geometry = BoardSceneGeometry(width: width, height: height)
        boardWidth = width
        boardHeight = height

        #if DEBUG
        let bounds = board.visualBounds(relativeTo: nil)
        NSLog("VisionScene loadBoard %dx%d file=%@ extents=(%.3f, %.3f, %.3f) center=(%.3f, %.3f, %.3f)",
              width, height, fileName,
              bounds.extents.x, bounds.extents.y, bounds.extents.z,
              bounds.center.x, bounds.center.y, bounds.center.z)
        #endif

        placed.values.forEach { $0.entity.removeFromParent() }
        placed.removeAll()
        setGhost(point: nil, color: .unknown)
        analysisRoot.children.forEach { $0.removeFromParent() }
        // The caches must empty with the entity tree, or the next sync
        // "updates" detached entities that never re-mount.
        markerEntities.removeAll()
        ownershipEntities.removeAll()
    }

    /// Depth-stretches the width-matched square asset into a W x H rectangle,
    /// reproducing the pipeline's parametric rules. The USDZ's `root` prim
    /// carries Blender's -90° X rotation, so its children work in Blender
    /// coordinates: local Y is the slab DEPTH and local Z is UP. The slab
    /// Xform scales along local Y; the leg Xforms (bun feet, lathe-built
    /// around local Z) move to the rectangle's inset corners and rescale
    /// radially (local X/Y only — leg height and the board top stay put).
    private static func applyRectangularShape(to board: Entity,
                                              width: Int, height: Int) throws {
        guard let root = board.findEntity(named: "root") else {
            throw LoadError.missingAsset("root prim in go_board_\(width)x\(width).usdz")
        }
        let rect = BoardGeometryRules.dimensions(width: width, height: height)
        let square = BoardGeometryRules.dimensions(width: width, height: width)
        let depthRatio = Float(rect.boardZMM / square.boardZMM)
        let radialRatio = Float(rect.kr / square.kr)

        var slabFound = false
        var legCount = 0
        for child in root.children {
            if child.name == "BoardSlab" {
                child.scale.y *= depthRatio
                slabFound = true
            } else if child.name.hasPrefix("Leg") {
                child.position.x = (child.position.x < 0 ? -1 : 1)
                    * Float(rect.boardXMM / 2000 - rect.inset)
                child.position.y = (child.position.y < 0 ? -1 : 1)
                    * Float(rect.boardZMM / 2000 - rect.inset)
                child.scale.x *= radialRatio
                child.scale.y *= radialRatio
                legCount += 1
            }
        }
        guard slabFound, legCount == 4 else {
            throw LoadError.missingAsset(
                "BoardSlab/Leg prims in go_board_\(width)x\(width).usdz")
        }
    }

    /// Swaps the generated board-top image over the 4x4 placeholder texture.
    /// The top material is identified by that placeholder size — never by
    /// name or subset order.
    private static func applyTopTexture(_ top: BoardTopTexture, to board: Entity) async throws {
        guard let cgImage = top.cgImage else {
            throw LoadError.missingAsset("board top texture bitmap")
        }
        let resource = try await TextureResource(
            image: cgImage, options: .init(semantic: .color))

        func swapPlaceholder(in entity: Entity) -> Int {
            var swapped = 0
            if var model = entity.components[ModelComponent.self] {
                model.materials = model.materials.map { material in
                    guard var pbr = material as? PhysicallyBasedMaterial,
                          let texture = pbr.baseColor.texture,
                          texture.resource.width == 4, texture.resource.height == 4
                    else { return material }
                    pbr.baseColor = .init(tint: .white,
                                          texture: .init(resource))
                    swapped += 1
                    return pbr
                }
                entity.components.set(model)
            }
            return swapped + entity.children.reduce(0) { $0 + swapPlaceholder(in: $1) }
        }

        guard swapPlaceholder(in: board) > 0 else {
            throw LoadError.missingAsset("4x4 placeholder top material")
        }
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

    /// View-model for one candidate move's flat marker attachment. The
    /// SwiftUI side renders the whole 2D-parity circle (fill, ring, text)
    /// from `mark`; the scene model only lays the attachment flat on the
    /// board.
    struct CandidateMarker: Equatable, Identifiable {
        let point: BoardPoint
        let vertex: String
        let mark: VisionCandidateMark
        var id: String { vertex }
    }

    /// Marker attachment entities keyed by vertex (the attachment id).
    private var markerEntities: [String: Entity] = [:]
    /// Above the ownership quads (+0.0002), below the stones and ghost —
    /// the 2D overlay's draw order.
    private static let markerLift: Float = 0.0008

    /// One list length drives both the markers and L1/R1 cycling, so the
    /// ghost only ever lands on marked points.
    static let candidateMoveLimit = 10

    /// Anisotropic cell spacing (22 x 23.7 mm, a physical constant of the
    /// board family) for sizing the flat markers and ownership quads.
    var cellSpacing: (x: Float, z: Float) {
        (Float(BoardGeometryRules.spacingX), Float(BoardGeometryRules.spacingZ))
    }

    /// Lays the marker attachment flat on the board: -π/2 about X maps the
    /// attachment's normal (+Z) onto +Y and its view-up onto -Z, so tabletop
    /// text reads upright from the front — and composed with the standing
    /// +π/2 X rotation it cancels, facing the viewer with text-up = up.
    /// No BillboardComponent (it would override the flat orientation).
    func mountMarker(_ entity: Entity, marker: CandidateMarker) {
        guard let geometry, let position = geometry.position(of: marker.point) else { return }
        entity.position = position + SIMD3<Float>(0, Self.markerLift, 0)
        entity.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        entity.scale = SIMD3<Float>(repeating: marker.mark.entityScale)
        if entity.parent !== analysisRoot {
            analysisRoot.addChild(entity)
            #if DEBUG
            let measured = entity.visualBounds(relativeTo: analysisRoot).extents.x
            NSLog("VisionScene marker %@ width measured=%.4f expected=%.4f",
                  marker.vertex, measured, marker.mark.diameterMeters)
            #endif
        }
        markerEntities[marker.vertex] = entity
    }

    func removeStaleMarkers(current: Set<String>) {
        for (vertex, entity) in markerEntities where !current.contains(vertex) {
            entity.removeFromParent()
            markerEntities.removeValue(forKey: vertex)
        }
    }

    // MARK: - Ownership overlay

    private var ownershipEntities: [BoardPoint: (entity: ModelEntity, materialKey: Int)] = [:]
    private var ownershipMesh: MeshResource?
    /// Whiteness/opacity arrive digitized (5ths), so this stays tiny.
    private var ownershipMaterials: [Int: UnlitMaterial] = [:]
    /// Above the board top, below the best-move backing disc (its bottom
    /// face sits at +0.0003) and the markers (+0.0015).
    private static let ownershipLift: Float = 0.0002

    /// Diffs the full-board ownership units into flat gray quads hugging the
    /// board — the 3D mirror of AnalysisView.ownerships. Parented under
    /// analysisRoot, so the B-button eye gate covers them; the caller passes
    /// [] when Show ownership is off.
    func applyOwnership(_ units: [OwnershipUnit]) {
        guard let geometry else { return }

        let desired = Set(units.map(\.point))
        for (point, entry) in ownershipEntities where !desired.contains(point) {
            entry.entity.removeFromParent()
            ownershipEntities.removeValue(forKey: point)
        }

        if ownershipMesh == nil {
            ownershipMesh = MeshResource.generatePlane(width: 1, depth: 1)
        }

        let spacing = cellSpacing
        for unit in units {
            guard let position = geometry.position(of: unit.point) else { continue }
            let mark = VisionOwnershipMark.make(unit: unit,
                                                cellSpacingX: spacing.x,
                                                cellSpacingZ: spacing.z)
            let scale = SIMD3<Float>(mark.width, 1, mark.depth)
            if let existing = ownershipEntities[unit.point] {
                existing.entity.scale = scale
                if existing.materialKey != mark.materialKey {
                    existing.entity.model?.materials = [ownershipMaterial(for: mark)]
                    ownershipEntities[unit.point] = (existing.entity, mark.materialKey)
                }
            } else {
                let entity = ModelEntity(mesh: ownershipMesh!,
                                         materials: [ownershipMaterial(for: mark)])
                entity.position = position + SIMD3<Float>(0, Self.ownershipLift, 0)
                entity.scale = scale
                analysisRoot.addChild(entity)
                ownershipEntities[unit.point] = (entity, mark.materialKey)
            }
        }
    }

    private func ownershipMaterial(for mark: VisionOwnershipMark) -> UnlitMaterial {
        if let cached = ownershipMaterials[mark.materialKey] { return cached }
        var material = UnlitMaterial(color: UIColor(white: CGFloat(mark.whiteness), alpha: 1))
        material.faceCulling = .none
        // Color alpha alone is ignored unless blending is transparent.
        material.blending = .transparent(opacity: .init(floatLiteral: mark.opacity))
        ownershipMaterials[mark.materialKey] = material
        return material
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
