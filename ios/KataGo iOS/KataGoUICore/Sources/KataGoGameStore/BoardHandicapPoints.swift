//
//  BoardHandicapPoints.swift
//  KataGoGameStore
//
//  Conventional handicap-stone placement, derived from `BoardStarPoints`
//  (the star-point rule it lives beside). Top-left origin, matching
//  BoardStarPoints and the SGF coordinate system. The single source of
//  truth: `GoGame.handicapPoints` (GoRulesKit) and `GameRecord.makeSgf`'s
//  handicap overload both delegate here.
//

import Foundation

public enum BoardHandicapPoints {
    private struct P: Equatable { let x: Int; let y: Int }

    public static func points(width: Int, height: Int, count: Int) -> [(x: Int, y: Int)] {
        let stars = BoardStarPoints.points(width: width, height: height).map { P(x: $0.x, y: $0.y) }
        guard count >= 2 else { return [] }
        let xs = Set(stars.map(\.x)).sorted()
        let ys = Set(stars.map(\.y)).sorted()
        guard xs.count >= 2, ys.count >= 2 else { return [] }
        let (left, right) = (xs.first!, xs.last!)
        let (top, bottom) = (ys.first!, ys.last!)
        func star(_ x: Int, _ y: Int) -> P? { stars.first { $0.x == x && $0.y == y } }
        // Black's first stone top-right, then diagonal, per convention.
        let corners = [star(right, top), star(left, bottom), star(right, bottom), star(left, top)]
            .compactMap { $0 }
        let center = stars.first { xs.count == 3 && ys.count == 3 && $0.x == xs[1] && $0.y == ys[1] }
        // Traditional order: the left/right middle points come before the
        // top/bottom middle points (6-stone handicap = corners + both sides).
        let sides = stars.filter { p in !corners.contains(p) && center != p }
            .sorted { a, b in
                let aIsLeftRight = center.map { a.y == $0.y } ?? false
                let bIsLeftRight = center.map { b.y == $0.y } ?? false
                if aIsLeftRight != bIsLeftRight { return aIsLeftRight }
                return a.x != b.x ? a.x < b.x : a.y < b.y
            }
        var order: [P] = []
        switch count {
        case 2, 3, 4:
            order = Array(corners.prefix(count))
        case 5, 7, 9:
            guard let center else { return [] }
            order = Array(corners.prefix(4)) + sides.prefix(count - 5) + [center]
        case 6, 8:
            order = Array(corners.prefix(4)) + sides.prefix(count - 4)
        default:
            return []
        }
        guard order.count == count else { return [] }
        return order.map { (x: $0.x, y: $0.y) }
    }

    public static func maxCount(width: Int, height: Int) -> Int {
        for n in stride(from: 9, through: 2, by: -1)
        where points(width: width, height: height, count: n).count == n {
            return n
        }
        return 0
    }

    /// SGF point letters: a-z for 0-25, A-Z for 26-51, nil beyond (the SGF
    /// coordinate alphabet ends at 52; this app caps boards at 37 anyway).
    public static func sgfCoordinate(x: Int, y: Int) -> String? {
        func letter(_ v: Int) -> Character? {
            if (0..<26).contains(v) { return Character(UnicodeScalar(UInt8(97 + v))) }
            if (26..<52).contains(v) { return Character(UnicodeScalar(UInt8(65 + v - 26))) }
            return nil
        }
        guard let cx = letter(x), let cy = letter(y) else { return nil }
        return "\(cx)\(cy)"
    }
}
