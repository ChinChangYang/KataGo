//
//  VisionGhostAppearanceTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure resolver behind the visionOS controller cursor: an empty
//  intersection shows the aiming ghost stone in the to-move color, an
//  occupied intersection hides the ghost and shows the focus ring hugging
//  the occupant instead, and no cursor shows nothing. The occupied branch
//  is the fix for the ghost rendering on top of a concrete stone.
//

import Testing
@testable import KataGoUICore

struct VisionGhostAppearanceTests {
    private let cursor = BoardPoint(x: 3, y: 3)

    @Test func noCursorIsHidden() {
        let appearance = VisionGhostAppearance.resolve(cursor: nil,
                                                       black: [cursor],
                                                       white: [],
                                                       nextColor: .black)
        #expect(appearance == .hidden)
    }

    @Test func emptyPointShowsGhostInNextColor() {
        let black = VisionGhostAppearance.resolve(cursor: cursor,
                                                  black: [],
                                                  white: [],
                                                  nextColor: .black)
        #expect(black == .ghost(color: .black, point: cursor))
        let white = VisionGhostAppearance.resolve(cursor: cursor,
                                                  black: [],
                                                  white: [],
                                                  nextColor: .white)
        #expect(white == .ghost(color: .white, point: cursor))
    }

    @Test func unknownNextColorNormalizesToBlackGhost() {
        // Pins the unknown -> black fallback that previously lived in
        // VisionBoardSceneModel.setGhost's prototype lookup.
        let appearance = VisionGhostAppearance.resolve(cursor: cursor,
                                                       black: [],
                                                       white: [],
                                                       nextColor: .unknown)
        #expect(appearance == .ghost(color: .black, point: cursor))
    }

    @Test func occupiedPointShowsFocusRingForOccupant() {
        let onBlack = VisionGhostAppearance.resolve(cursor: cursor,
                                                    black: [cursor],
                                                    white: [],
                                                    nextColor: .white)
        #expect(onBlack == .focusRing(occupant: .black, point: cursor))
        let onWhite = VisionGhostAppearance.resolve(cursor: cursor,
                                                    black: [],
                                                    white: [cursor],
                                                    nextColor: .white)
        #expect(onWhite == .focusRing(occupant: .white, point: cursor))
    }

    @Test func occupantWinsRegardlessOfNextColor() {
        for nextColor in [PlayerColor.black, .white, .unknown] {
            let appearance = VisionGhostAppearance.resolve(cursor: cursor,
                                                           black: [cursor],
                                                           white: [],
                                                           nextColor: nextColor)
            #expect(appearance == .focusRing(occupant: .black, point: cursor))
        }
    }

    @Test func captureUnderCursorSwapsRingToGhost() {
        // The cursor parks on a stone; the capturing move removes it from
        // the stone list between two resolves. The ring must yield to the
        // ghost the tick the occupant vanishes.
        let before = VisionGhostAppearance.resolve(cursor: cursor,
                                                   black: [],
                                                   white: [cursor],
                                                   nextColor: .white)
        #expect(before == .focusRing(occupant: .white, point: cursor))
        let after = VisionGhostAppearance.resolve(cursor: cursor,
                                                  black: [],
                                                  white: [],
                                                  nextColor: .white)
        #expect(after == .ghost(color: .white, point: cursor))
    }

    @Test func unrelatedStonesDoNotRingTheCursor() {
        let appearance = VisionGhostAppearance.resolve(
            cursor: cursor,
            black: [BoardPoint(x: 2, y: 3), BoardPoint(x: 3, y: 2)],
            white: [BoardPoint.pass(width: 19, height: 19)],
            nextColor: .black)
        #expect(appearance == .ghost(color: .black, point: cursor))
    }
}
