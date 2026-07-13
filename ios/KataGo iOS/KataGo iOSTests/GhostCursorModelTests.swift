//
//  GhostCursorModelTests.swift
//  KataGo AnytimeTests
//

import Foundation
import Testing
@testable import KataGoUICore

@MainActor
struct GhostCursorModelTests {
    @Test func startsHiddenAndActivatesAtCenter() {
        let ghost = GhostCursorModel()
        #expect(ghost.point == nil)

        ghost.activate(width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 4, y: 4))

        // Activating again while visible is a no-op.
        ghost.step(.right, width: 9, height: 9)
        ghost.activate(width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 5, y: 4))
    }

    @Test func activateCentersLargerBoards() {
        let ghost = GhostCursorModel()
        ghost.activate(width: 19, height: 19)
        #expect(ghost.point == BoardPoint(x: 9, y: 9))
    }

    @Test func stepMovesOneIntersectionWithClamping() {
        let ghost = GhostCursorModel()
        ghost.activate(width: 9, height: 9)

        ghost.step(.up, width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 4, y: 5))
        ghost.step(.down, width: 9, height: 9)
        ghost.step(.down, width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 4, y: 3))
        ghost.step(.left, width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 3, y: 3))
        ghost.step(.right, width: 9, height: 9)
        ghost.step(.right, width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 5, y: 3))

        // Clamp at edges.
        for _ in 0..<20 { ghost.step(.left, width: 9, height: 9) }
        #expect(ghost.point?.x == 0)
        for _ in 0..<20 { ghost.step(.up, width: 9, height: 9) }
        #expect(ghost.point?.y == 8)
    }

    @Test func stepWhileHiddenOnlyActivates() {
        let ghost = GhostCursorModel()
        ghost.step(.up, width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 4, y: 4))
    }

    @Test func glideAccumulatesFractionsAndSnaps() {
        let ghost = GhostCursorModel()
        ghost.activate(width: 9, height: 9)

        ghost.glide(dColumn: 0.4, dRow: 0, width: 9, height: 9)
        ghost.glide(dColumn: 0.4, dRow: 0, width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 4, y: 4))

        ghost.glide(dColumn: 0.4, dRow: 0, width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 5, y: 4))

        // Multi-step in one call, negative direction.
        ghost.glide(dColumn: -2.5, dRow: 0, width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 3, y: 4))

        // Row axis: positive dRow moves away from the viewer (+BoardPoint.y).
        ghost.glide(dColumn: 0, dRow: 1.2, width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 3, y: 5))
    }

    @Test func glideWhileHiddenActivatesWithoutStepping() {
        let ghost = GhostCursorModel()
        ghost.glide(dColumn: 0.7, dRow: 0, width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 4, y: 4))
    }

    @Test func glideClampsAtEdges() {
        let ghost = GhostCursorModel()
        ghost.activate(width: 9, height: 9)
        ghost.glide(dColumn: 50, dRow: -50, width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 8, y: 0))
    }

    @Test func resetHidesAndClearsAccumulators() {
        let ghost = GhostCursorModel()
        ghost.glide(dColumn: 0.7, dRow: 0.7, width: 9, height: 9)
        ghost.reset()
        #expect(ghost.point == nil)

        // If accumulators survived reset, this 0.7 would combine to a step.
        ghost.glide(dColumn: 0.7, dRow: 0, width: 9, height: 9)
        #expect(ghost.point == BoardPoint(x: 4, y: 4))
    }

    @Test func cycleJumpsToFirstWhenOffList() {
        let ghost = GhostCursorModel()
        let candidates = [BoardPoint(x: 2, y: 2), BoardPoint(x: 6, y: 6), BoardPoint(x: 4, y: 4)]

        ghost.cycle(through: candidates, forward: true)
        #expect(ghost.point == BoardPoint(x: 2, y: 2))
    }

    @Test func cycleAdvancesAndWraps() {
        let ghost = GhostCursorModel()
        let candidates = [BoardPoint(x: 2, y: 2), BoardPoint(x: 6, y: 6), BoardPoint(x: 4, y: 4)]

        ghost.cycle(through: candidates, forward: true)
        ghost.cycle(through: candidates, forward: true)
        #expect(ghost.point == BoardPoint(x: 6, y: 6))
        ghost.cycle(through: candidates, forward: true)
        #expect(ghost.point == BoardPoint(x: 4, y: 4))
        // Wrap forward from the last element.
        ghost.cycle(through: candidates, forward: true)
        #expect(ghost.point == BoardPoint(x: 2, y: 2))
        // Wrap backward from the first element.
        ghost.cycle(through: candidates, forward: false)
        #expect(ghost.point == BoardPoint(x: 4, y: 4))
    }

    @Test func cycleWithNoCandidatesIsNoOp() {
        let ghost = GhostCursorModel()
        ghost.cycle(through: [], forward: true)
        #expect(ghost.point == nil)

        ghost.activate(width: 9, height: 9)
        ghost.cycle(through: [], forward: true)
        #expect(ghost.point == BoardPoint(x: 4, y: 4))
    }
}
