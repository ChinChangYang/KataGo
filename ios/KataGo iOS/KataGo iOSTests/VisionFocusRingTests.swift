//
//  VisionFocusRingTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure geometry and palette behind the visionOS focus ring — the
//  flat opaque annulus shown on the board top when the controller cursor
//  sits on an occupied intersection (the ghost stone hides there instead
//  of overlapping the concrete stone). The radii are an asset contract:
//  the inner edge must clear the stone's widest silhouette (measured from
//  stone_black/white.usdz) and the outer edge must stay inside the grid
//  pitch; the lift slots between the ownership quads and the marker
//  attachments.
//

import Foundation
import ModelIO
import Testing
import simd
@testable import KataGoUICore

struct VisionFocusRingTests {
    private let epsilon: Float = 1e-6

    @Test func radiiClearTheStoneAndStayInsideThePitch() {
        #expect(VisionFocusRing.innerRadius > 0)
        #expect(VisionFocusRing.innerRadius < VisionFocusRing.outerRadius)
        #expect(VisionFocusRing.innerRadius > VisionFocusRing.stoneEquatorRadius)
        #expect(VisionFocusRing.outerRadius < Float(BoardGeometryRules.spacingX))
    }

    @Test func stoneEquatorRadiusMatchesTheBundledStoneAssets() throws {
        // The clearance contract is only as good as the measured constant:
        // stones render at raw asset scale, so a re-exported USDZ would
        // silently swallow the ring. Measure the committed assets.
        let assetsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // KataGo iOSTests
            .deletingLastPathComponent()  // KataGo iOS (project dir)
            .appendingPathComponent("KataGo Anytime Vision/Resources/BoardAssets")
        for stone in ["stone_black", "stone_white"] {
            let url = assetsDirectory.appendingPathComponent("\(stone).usdz")
            #expect(FileManager.default.fileExists(atPath: url.path))
            let bounds = MDLAsset(url: url).boundingBox
            let equatorRadius = max(bounds.maxBounds.x, bounds.maxBounds.y,
                                    bounds.maxBounds.z)
            #expect(abs(equatorRadius - VisionFocusRing.stoneEquatorRadius) < 1e-4)
        }
    }

    @Test func liftSlotsBetweenOwnershipQuadsAndMarkerAttachments() {
        // By reference to the shared z-ladder the scene model consumes —
        // literals here could drift from the rendered ordering silently.
        #expect(VisionFocusRing.lift == VisionOverlayLift.focusRing)
        #expect(VisionOverlayLift.focusRing > VisionOverlayLift.ownershipQuad)
        #expect(VisionOverlayLift.focusRing < VisionOverlayLift.markerAttachment)
    }

    @Test func whitenessContrastsWithTheOccupant() {
        #expect(VisionFocusRing.whiteness(occupant: .black) > 0.8)
        #expect(VisionFocusRing.whiteness(occupant: .white) < 0.2)
        // Unknown occupants (never produced by the resolver) read light.
        #expect(VisionFocusRing.whiteness(occupant: .unknown)
                == VisionFocusRing.whiteness(occupant: .black))
    }

    @Test func threeSegmentGeometryMatchesTheGoldenTriangulation() {
        // Pins strip topology, not just index coverage: a double-wrapped
        // ring (j = i+2) passes every count/range/winding assertion below.
        let geometry = VisionFocusRing.makeGeometry(segments: 3)
        #expect(geometry.triangleIndices == [0, 3, 1, 0, 2, 3,
                                             2, 5, 3, 2, 4, 5,
                                             4, 1, 5, 4, 0, 1])
    }

    @Test func geometryHasInterleavedRimsAndFullIndexCoverage() {
        for segments in [3, VisionFocusRing.segmentCount] {
            let geometry = VisionFocusRing.makeGeometry(segments: segments)
            #expect(geometry.positions.count == 2 * segments)
            #expect(geometry.triangleIndices.count == 6 * segments)
            #expect(geometry.triangleIndices.allSatisfy { $0 < UInt32(2 * segments) })
            #expect(Set(geometry.triangleIndices).count == 2 * segments)
        }
    }

    @Test func verticesLieFlatOnTheRimRadii() {
        let geometry = VisionFocusRing.makeGeometry()
        for (index, position) in geometry.positions.enumerated() {
            #expect(abs(position.y) < epsilon)
            let radius = simd_length(SIMD2<Float>(position.x, position.z))
            let expected = index.isMultiple(of: 2)
                ? VisionFocusRing.innerRadius
                : VisionFocusRing.outerRadius
            #expect(abs(radius - expected) < epsilon)
        }
    }

    @Test func trianglesWindCounterClockwiseSeenFromAbove() {
        let geometry = VisionFocusRing.makeGeometry()
        for triangle in stride(from: 0, to: geometry.triangleIndices.count, by: 3) {
            let a = geometry.positions[Int(geometry.triangleIndices[triangle])]
            let b = geometry.positions[Int(geometry.triangleIndices[triangle + 1])]
            let c = geometry.positions[Int(geometry.triangleIndices[triangle + 2])]
            #expect(cross(b - a, c - a).y > 0)
        }
    }
}
