//
//  VisionTestFixtures.swift
//  KataGo AnytimeTests
//
//  Fixture builder mirroring the real BoardAssets/boards_manifest.json
//  convention: intersections[j][i], i toward +X, j toward -Z, y = board top.
//

import Foundation

enum VisionTestFixtures {
    /// 9x9 fixture matching the shipped manifest exactly:
    /// spacing 0.022 x 0.0237, top_y 0.062, A1 = intersections[0][0] = (-0.088, 0.062, +0.0948).
    static func manifest9x9JSON(truncateLastRow: Bool = false) -> Data {
        var intersections: [[[Double]]] = []
        for j in 0..<9 {
            var row: [[Double]] = []
            for i in 0..<9 {
                let x: Double = Double(i - 4) * 0.022
                let z: Double = Double(4 - j) * 0.0237
                row.append([x, 0.062, z])
            }
            intersections.append(row)
        }
        if truncateLastRow {
            intersections[8].removeLast()
        }

        let manifest: [String: Any] = [
            "schema_version": 1,
            "units": "meters",
            "coordinate_frame": [
                "up_axis": "Y",
                "origin": "board footprint center; feet rest on y=0",
                "grid_convention": "i in 0..N-1 increases toward +X; j in 0..N-1 increases toward -Z; intersections[j][i]",
            ],
            "spacing": ["x": 0.022, "z": 0.0237],
            "line_width": 0.0008,
            "stone_ref": ["diameter": 0.0224, "thickness": 0.0096],
            "boards": [
                "9": [
                    "n": 9,
                    "file_usdz": "go_board_9x9.usdz",
                    "bbox_size": [0.203, 0.062, 0.2196],
                    "top_y": 0.062,
                    "slab_thickness": 0.02,
                    "leg_height": 0.042,
                    "hoshi": [[2, 2], [2, 6], [4, 4], [6, 2], [6, 6]],
                    "intersections": intersections,
                ] as [String: Any],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: manifest)
    }
}
