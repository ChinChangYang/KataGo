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
//        ├── ghostRoot         (aiming ghost stone / occupied-point focus ring)
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
    /// Red branch-frame layer. A boardRoot child (NOT analysisRoot): the
    /// branch cue must survive the B-button eye gate — hiding analysis
    /// must not hide "you are on a temporary line".
    private let branchRoot = Entity()

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

    /// FIFO of what the command sites are about to do to the board; each
    /// stone diff resolves against it to pick the one stone that animates.
    private var planner = StoneAnimationPlanner()
    /// Undone stones still lifting off the board, keyed by point so a stone
    /// re-mounting there can replace the in-flight entity.
    private var flyingAway: [BoardPoint: Entity] = [:]
    /// Plays the stone placement click; the root wires it to the AudioModel.
    /// Sound is scene-driven on this platform (it fires when the cue says a
    /// stone lands), replacing GobanState's commit-time sound.
    var playStoneSound: (() -> Void)?
    /// Plays the capture rattle; the root wires it to the AudioModel. Cued
    /// here for the same reason as playStoneSound: showboard reports the new
    /// capture count while the capturing stone is still in the air, so a
    /// rattle fired when the counter moves is heard a whole flight before
    /// the stone that caused it lands.
    var playCaptureSound: (() -> Void)?
    /// True until the first non-empty stone diff after boot, a board
    /// rebuild, or a game switch — that remount batch must stay silent.
    private var isInitialStoneSync = true
    /// How the next reported capture should sound, set by the last non-empty
    /// stone diff. Nothing is in the air before the first diff, so a rattle
    /// arriving that early is due at once.
    private var captureCue: StoneAnimationPlanner.CaptureCue = .immediately
    /// When the stone currently flying in touches down — the instant its
    /// landing click fires. A capture reported mid-flight rides it.
    private var landingDeadline: ContinuousClock.Instant?
    /// Bumped by every switch/rebuild so an already-scheduled landing click
    /// (a 0.25 s Task) can tell its stone's world was torn down and stay
    /// quiet.
    private var stoneSyncEpoch = 0

    init() {
        volumeRoot.addChild(boardRoot)
        boardRoot.addChild(stonesRoot)
        boardRoot.addChild(ghostRoot)
        boardRoot.addChild(analysisRoot)
        boardRoot.addChild(branchRoot)
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

    /// Placed stones cast a grounding shadow onto the board so they read as
    /// seated rather than floating. Applied to every model-bearing
    /// descendant of the stone prototypes so clones inherit it (the ghost
    /// clone strips it again — an aiming cursor floats by design).
    private static func applyGroundingShadow(in entity: Entity) {
        if entity.components[ModelComponent.self] != nil {
            entity.components.set(GroundingShadowComponent(castsShadow: true))
        }
        entity.children.forEach { applyGroundingShadow(in: $0) }
    }

    private static func removeGroundingShadow(in entity: Entity) {
        entity.components.remove(GroundingShadowComponent.self)
        entity.children.forEach { removeGroundingShadow(in: $0) }
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
            Self.applyGroundingShadow(in: black)
            Self.applyGroundingShadow(in: white)
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
        // A board swap must also kill in-flight fly-away entities and any
        // stale animation intents, or detached stones linger mid-air.
        flyingAway.values.forEach { $0.removeFromParent() }
        flyingAway.removeAll()
        planner.clear()
        // The rebuilt board's first stone batch is a remount, not a move.
        isInitialStoneSync = true
        stoneSyncEpoch += 1
        setGhost(.hidden)
        analysisRoot.children.forEach { $0.removeFromParent() }
        // The caches must empty with the entity tree, or the next sync
        // "updates" detached entities that never re-mount.
        markerEntities.removeAll()
        ownershipEntities.removeAll()
        // The frame is sized to the slab; a still-active branch rebuilds it
        // for the new board on the next sync.
        branchRoot.children.forEach { $0.removeFromParent() }
        branchFrameBoard = nil
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

    /// Flight height above the rest position, along board-local +Y — the
    /// board normal in both orientations, since stones are stonesRoot
    /// children under the (possibly rotated) boardRoot.
    private static let flightHeight: Float = 0.06
    private static let flyInDuration: TimeInterval = 0.25
    private static let flyAwayDuration: TimeInterval = 0.25

    /// Registers what a command site is about to do so the next stone diff
    /// animates the right stone (see StoneAnimationPlanner for why this is
    /// provenance-based, not an index-delta heuristic).
    func expectStoneAnimation(_ intent: StoneAnimationPlanner.Intent) {
        planner.expect(intent)
    }

    /// Drops outstanding animation intents ahead of a user-initiated batch
    /// update (jump to start/end) so the mass diff mounts instantly. Also
    /// ends any initial-sync window: a same-position reload can leave the
    /// mount flag armed (its diff is empty), and the jump the user just
    /// pressed must click once, not consume the flag silently.
    func clearStoneAnimationIntents() {
        planner.clear()
        isInitialStoneSync = false
    }

    /// Game-switch reset: drops outstanding intents AND silences the next
    /// stone sync — the remount batch is not a played move. L2/R2 jumps use
    /// clearStoneAnimationIntents instead: their batch diff still clicks
    /// once.
    func prepareForGameSwitch() {
        planner.clear()
        isInitialStoneSync = true
        stoneSyncEpoch += 1
        // The remount batch mounts instantly, so the rattle the new game's
        // showboard triggers has no landing to wait for. (That the remount
        // rattles at all is the user's standing decision, not an oversight.)
        captureCue = .immediately
        landingDeadline = nil
    }

    /// The engine just reported a capture (a showboard capture counter rose).
    /// The rattle is deferred by one main-actor turn so it reads the cue that
    /// THIS update pass's stone diff set: the counter observer and the diff
    /// run in the same SwiftUI pass, in an order SwiftUI does not define, and
    /// showboard can also deliver the counter on a later, empty sync of the
    /// same block. One turn's wait is imperceptible and settles both.
    func noteCapture() {
        let epoch = stoneSyncEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch self.captureCue {
            case .immediately:
                break
            case .atLanding:
                // No deadline means the flight already finished (its click
                // has played), so the rattle is due now rather than never.
                if let deadline = self.landingDeadline {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                }
            }
            // A game switch or board rebuild during the flight tore down the
            // world the capture belonged to — same guard as the landing click.
            guard self.stoneSyncEpoch == epoch else { return }
            self.playCaptureSound?()
        }
    }

    /// Withdraws an intent whose command the engine rejected (illegal move)
    /// so it can never satisfy a later, unrelated diff.
    func retractStoneAnimation(_ intent: StoneAnimationPlanner.Intent) {
        planner.retract(intent)
    }

    /// Diffs the engine's stone lists against the mounted entities —
    /// O(changed), not O(board). At most one stone of the diff animates
    /// (the one a queued intent accounts for); everything else — captures,
    /// restores, batch remounts — mounts and unmounts instantly.
    func applyStones(black: [BoardPoint], white: [BoardPoint]) {
        guard let geometry else { return }

        var desired: [BoardPoint: PlayerColor] = [:]
        black.forEach { desired[$0] = .black }
        white.forEach { desired[$0] = .white }
        // A pass is encoded as an off-board sentinel point — never mount it.
        desired = desired.filter { geometry.position(of: $0.key) != nil }

        // Resolve the diff against the intent queue BEFORE mutating `placed`.
        let removedPoints = Set(placed.keys.filter { desired[$0] != placed[$0]?.color })
        let addedPoints = Set(desired.keys.filter { placed[$0] == nil })
        let effect = planner.resolve(additions: addedPoints, removals: removedPoints)
        let cue = StoneAnimationPlanner.soundCue(effect: effect,
                                                 additions: addedPoints.count,
                                                 removals: removedPoints.count,
                                                 isInitialSync: isInitialStoneSync)
        // Only a non-empty diff re-cues the rattle: showboard writes the
        // stone lists before its capture counters, so the counter can land on
        // a later, empty sync that must not overwrite this diff's cue.
        if let capture = StoneAnimationPlanner.captureCue(effect: effect,
                                                          additions: addedPoints.count,
                                                          removals: removedPoints.count) {
            captureCue = capture
        }
        // A batch click plays now (fly-aways are silent); the fly-in landing
        // click is scheduled at the mount site below, where the entity is in
        // hand.
        if cue == .playImmediately {
            playStoneSound?()
        }
        // Only a non-empty diff consumes the mount flag: the flag must
        // survive the empty re-syncs between a switch and its showboard.
        if !addedPoints.isEmpty || !removedPoints.isEmpty {
            isInitialStoneSync = false
        }

        for (point, current) in placed where desired[point] != current.color {
            if effect == .flyAway(point) {
                flyAway(current.entity, from: point)
            } else {
                current.entity.removeFromParent()
            }
            placed.removeValue(forKey: point)
        }

        for (point, color) in desired where placed[point] == nil {
            guard let prototype = stonePrototypes[color],
                  let position = geometry.position(of: point) else { continue }
            // A stone mounting where an undone one is still lifting off
            // replaces the in-flight entity.
            flyingAway.removeValue(forKey: point)?.removeFromParent()
            let stone = prototype.clone(recursive: true)
            stone.position = position
            stone.transform.rotation = simd_quatf(angle: Self.grainAngle(for: point),
                                                  axis: [0, 1, 0])
            if effect == .flyIn(point) {
                let rest = stone.transform
                stone.position.y += Self.flightHeight
                stonesRoot.addChild(stone)
                stone.move(to: rest, relativeTo: stonesRoot,
                           duration: Self.flyInDuration, timingFunction: .easeOut)
                // The landing click, guarded like the flyAway cleanup: an
                // undo can pull the stone back mid-flight and a switch or
                // rebuild can tear its world down — a stone that never
                // seated must not click.
                let epoch = stoneSyncEpoch
                // Published so a capture reported while this stone is still
                // in the air rattles at touchdown instead of at parse time.
                let deadline = ContinuousClock.now.advanced(by: .seconds(Self.flyInDuration))
                landingDeadline = deadline
                Task { @MainActor [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    guard let self, self.stoneSyncEpoch == epoch else { return }
                    if self.landingDeadline == deadline { self.landingDeadline = nil }
                    guard self.placed[point]?.entity === stone else { return }
                    self.playStoneSound?()
                }
            } else {
                stonesRoot.addChild(stone)
            }
            placed[point] = (color, stone)
            #if DEBUG
            NSLog("VisionScene stone %@ at (%d,%d) pos=(%.4f, %.4f, %.4f)",
                  color == .black ? "black" : "white", point.x, point.y,
                  position.x, position.y, position.z)
            #endif
        }
    }

    /// Lifts an undone stone off the board and removes it when the flight
    /// ends. The stone leaves `placed` at the call site; `flyingAway` tracks
    /// the entity so a re-mount at the same point can replace it mid-flight.
    /// Cleanup is a Task.sleep rather than an AnimationEvents subscription:
    /// the scene model has no RealityViewContent to subscribe from, and
    /// removeFromParent() on an already-detached entity is a harmless no-op,
    /// so a late cleanup can never corrupt state.
    private func flyAway(_ entity: Entity, from point: BoardPoint) {
        flyingAway[point]?.removeFromParent()
        flyingAway[point] = entity
        var target = entity.transform
        target.translation.y += Self.flightHeight
        entity.move(to: target, relativeTo: stonesRoot,
                    duration: Self.flyAwayDuration, timingFunction: .easeIn)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.flyAwayDuration))
            entity.removeFromParent()
            if let self, self.flyingAway[point] === entity {
                self.flyingAway.removeValue(forKey: point)
            }
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
            // Vertically centered in the volume (root sits on the floor);
            // the rotated grid spans ±depth/2 about this point, so even a
            // standing 37x37 (0.88 m) stays inside the volume height.
            target.translation = [0, VisionVolumeMetrics.heightMeters / 2, 0]
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
    /// Above the ownership quads and focus ring, below the stones and
    /// ghost — the 2D overlay's draw order (VisionOverlayLift z-ladder).
    private static let markerLift = VisionOverlayLift.markerAttachment

    /// How many candidate-move markers the analysis overlay shows.
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
    /// Above the board top, below the focus ring and marker attachments
    /// (VisionOverlayLift z-ladder).
    /// The quads never share a point with a candidate circle:
    /// RealityKit cannot sort scene transparents behind attachment planar
    /// UI (`ModelSortGroup.planarUIAlwaysBehind` and a shared explicit
    /// sort group were both no-ops against attachments, visionOS 26.5),
    /// so candidate points are filtered out of the quad list and their
    /// ownership renders inside the attachment (VisionCandidateMarkerView).
    private static let ownershipLift = VisionOverlayLift.ownershipQuad

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

    // MARK: - Branch frame

    /// The board size the mounted frame was built for (nil = none built).
    private var branchFrameBoard: SIMD2<Int>?

    /// Shows or hides the red perimeter frame — the 3D stand-in for iOS's
    /// red rectangle around the goban while a branch is active. The bars
    /// are OPAQUE unlit boxes (VisionBranchFrame geometry): opaque
    /// geometry depth-sorts normally, so this layer is immune to the
    /// transparent-vs-attachment ordering gotcha the ownership quads hit.
    func setBranchFrame(active: Bool) {
        guard active else {
            branchRoot.isEnabled = false
            return
        }
        guard boardWidth > 0, boardHeight > 0 else { return }
        let board = SIMD2<Int>(boardWidth, boardHeight)
        if branchFrameBoard != board {
            branchRoot.children.forEach { $0.removeFromParent() }
            var material = UnlitMaterial(color: .systemRed)
            material.faceCulling = .none
            for bar in VisionBranchFrame.make(width: boardWidth,
                                              height: boardHeight).bars {
                let entity = ModelEntity(
                    mesh: .generateBox(width: bar.size.x,
                                       height: bar.size.y,
                                       depth: bar.size.z),
                    materials: [material])
                entity.position = bar.center
                branchRoot.addChild(entity)
            }
            branchFrameBoard = board
        }
        branchRoot.isEnabled = true
    }

    // MARK: - Ghost

    private var focusRingEntity: ModelEntity?
    private var focusRingOccupant: PlayerColor = .unknown
    private var focusRingMesh: MeshResource?
    private var focusRingMaterials: [PlayerColor: UnlitMaterial] = [:]

    /// Renders the controller cursor: the aiming ghost stone on an empty
    /// point, the flat focus ring hugging the occupant on an occupied point
    /// (a translucent stone coinciding with a concrete one reads as a
    /// glitch), or nothing. Ghost and ring are mutually exclusive by
    /// construction of VisionGhostAppearance.
    func setGhost(_ appearance: VisionGhostAppearance) {
        switch appearance {
        case .ghost(let color, let point):
            if let position = geometry?.position(of: point) {
                removeFocusRing()
                mountGhostStone(color: color, at: position)
                return
            }
        case .focusRing(let occupant, let point):
            if let position = geometry?.position(of: point) {
                removeGhostStone()
                mountFocusRing(occupant: occupant, at: position)
                return
            }
        case .hidden:
            break
        }
        removeGhostStone()
        removeFocusRing()
    }

    private func mountGhostStone(color: PlayerColor, at position: SIMD3<Float>) {
        if ghostEntity == nil || ghostColor != color {
            ghostEntity?.removeFromParent()
            guard let prototype = stonePrototypes[color] else { return }
            let ghost = prototype.clone(recursive: true)
            // The prototypes carry the placed-stone grounding shadow; a
            // semi-transparent aiming cursor must not cast one.
            Self.removeGroundingShadow(in: ghost)
            ghost.components.set(OpacityComponent(opacity: 0.45))
            ghostRoot.addChild(ghost)
            ghostEntity = ghost
            ghostColor = color
        }
        ghostEntity?.position = position
    }

    private func removeGhostStone() {
        ghostEntity?.removeFromParent()
        ghostEntity = nil
        ghostColor = .unknown
    }

    private func mountFocusRing(occupant: PlayerColor, at position: SIMD3<Float>) {
        if focusRingEntity == nil || focusRingOccupant != occupant {
            removeFocusRing()
            guard let mesh = focusRingMeshResource() else { return }
            let ring = ModelEntity(mesh: mesh,
                                   materials: [focusRingMaterial(for: occupant)])
            ghostRoot.addChild(ring)
            focusRingEntity = ring
            focusRingOccupant = occupant
        }
        focusRingEntity?.position = position
            + SIMD3<Float>(0, VisionFocusRing.lift, 0)
    }

    private func removeFocusRing() {
        focusRingEntity?.removeFromParent()
        focusRingEntity = nil
        focusRingOccupant = .unknown
    }

    /// Built once and reused: the ring is sized by physical constants
    /// (pitch and stone radius), not by board dimensions.
    private func focusRingMeshResource() -> MeshResource? {
        if let focusRingMesh { return focusRingMesh }
        let geometry = VisionFocusRing.makeGeometry()
        var descriptor = MeshDescriptor(name: "ghostFocusRing")
        descriptor.positions = MeshBuffers.Positions(geometry.positions)
        descriptor.normals = MeshBuffers.Normals(
            Array(repeating: SIMD3<Float>(0, 1, 0),
                  count: geometry.positions.count))
        descriptor.primitives = .triangles(geometry.triangleIndices)
        let mesh = try? MeshResource.generate(from: [descriptor])
        focusRingMesh = mesh
        return mesh
    }

    /// Opaque on purpose — see VisionFocusRing's header.
    private func focusRingMaterial(for occupant: PlayerColor) -> UnlitMaterial {
        if let cached = focusRingMaterials[occupant] { return cached }
        var material = UnlitMaterial(
            color: UIColor(white: CGFloat(VisionFocusRing.whiteness(occupant: occupant)),
                           alpha: 1))
        material.faceCulling = .none
        focusRingMaterials[occupant] = material
        return material
    }
}
