//
//  BoardAssetManifest.swift
//  KataGoUICore
//
//  Decodes the trimmed BoardAssets/boards_manifest.json shipped with the
//  visionOS app. Coordinate contract (from the asset pipeline): Y-up, meters,
//  board footprint centered at the origin with feet on y=0;
//  intersections[j][i] where i (0..n-1) increases toward +X and j (0..n-1)
//  increases toward -Z; each coordinate's y is the board-top height, so a
//  bottom-origin stone placed at an intersection sits exactly on the board.
//

import Foundation

public struct BoardAssetManifest: Decodable, Sendable {
    public struct Spacing: Decodable, Sendable {
        public let x: Double
        public let z: Double
    }

    public struct StoneRef: Decodable, Sendable {
        public let diameter: Double
        public let thickness: Double
    }

    public struct BoardEntry: Decodable, Sendable {
        public let n: Int
        public let fileUSDZ: String
        public let topY: Double
        public let hoshi: [[Int]]
        public let intersections: [[[Double]]]

        enum CodingKeys: String, CodingKey {
            case n
            case fileUSDZ = "file_usdz"
            case topY = "top_y"
            case hoshi
            case intersections
        }
    }

    public enum ParseError: Error {
        case malformedIntersections(size: Int)
    }

    public let schemaVersion: Int
    public let spacing: Spacing
    public let stoneRef: StoneRef
    public let boards: [String: BoardEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case spacing
        case stoneRef = "stone_ref"
        case boards
    }

    public static func parse(_ data: Data) throws -> BoardAssetManifest {
        let manifest = try JSONDecoder().decode(BoardAssetManifest.self, from: data)
        for entry in manifest.boards.values {
            let isWellFormed = entry.intersections.count == entry.n
                && entry.intersections.allSatisfy { row in
                    row.count == entry.n && row.allSatisfy { $0.count == 3 }
                }
            guard isWellFormed else {
                throw ParseError.malformedIntersections(size: entry.n)
            }
        }
        return manifest
    }

    public func entry(forSquareSize n: Int) -> BoardEntry? {
        boards["\(n)"]
    }
}
