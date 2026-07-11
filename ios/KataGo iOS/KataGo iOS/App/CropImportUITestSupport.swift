//
//  CropImportUITestSupport.swift
//  KataGo iOS
//
//  DEBUG-only seam for the crop-recovery UI test. Feeds the photo-import
//  funnel an image the recognizer cannot read full-frame but can read once
//  cropped: the bundled wide-margin 9x9 board (PhotoImportUITestSupport's
//  blob, 1280×960) drawn at 50% linear scale in the center of a 2560×1920
//  canvas whose border carries frame-scale distractors — IRREGULARLY spaced
//  dark lines kept out of a central hole, plus thick frame bars — which
//  defeat full-frame board detection (headless-verified abstention,
//  failed:ambiguous-board-size) while the test's central ≈[0.20,0.80]² crop
//  recognizes the board at high confidence. A UNIFORM competing grid does
//  NOT work here: the recognizer locks onto the uniform lattice as a board
//  of its own and returns a weak "ok" (phantom stones) instead of
//  abstaining; uneven line spacing defeats any grid fit. The UI test
//  drives: full-frame failure → crop phase → corner drags → Recognize →
//  preview → Import. PNG output keeps the composition lossless and
//  pixel-deterministic. Mirrors the other import seams; compiled out of
//  Release entirely.
//

#if DEBUG
import CoreGraphics
import Foundation
import KataGoUICore
import UIKit

enum CropImportUITestSupport {
    /// Pass in `XCUIApplication.launchArguments` to auto-present the
    /// photo-import sheet with the composed crop-recovery canvas.
    static let launchArg = "--uitest-crop-import"

    /// Fixed name so the UI test can find the imported game in the library.
    static let importedGameName = "UITest Crop Board"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArg)
    }

    /// Idempotently presents the photo-import sheet with the composed canvas.
    /// No-op unless the launch argument is present and nothing is pending yet.
    @MainActor
    static func presentIfNeeded(into topUIState: TopUIState) {
        guard isActive else { return }
        guard topUIState.pendingPhotoImport == nil else { return }
        guard let data = composedCanvasPNG() else { return }
        topUIState.pendingPhotoImport = PendingPhotoImport(
            imageData: data,
            suggestedName: importedGameName,
            source: .fileOrLibrary
        )
    }

    /// Fractions of the canvas where the irregular distractor lines sit —
    /// deliberately UNEVENLY spaced (clustered pairs, varying gaps) so that
    /// no uniform board grid fits them. Verticals go at `f * width`,
    /// horizontals at `f * height`.
    private static let distractorLineFractions: [CGFloat] = [
        0.03, 0.07, 0.16, 0.21, 0.36, 0.44, 0.58, 0.71, 0.77, 0.9, 0.96,
    ]

    /// The board blob at 50% linear scale centered in a 2× canvas — the board
    /// is exactly the central [0.25,0.75]² of the frame — surrounded by
    /// distractors: a wood-toned base, irregularly spaced dark lines that
    /// stop at a central hole (a square of side width × 0.57, spanning
    /// [0.215,0.785] of the width — comfortably clear of both the board and
    /// the 0.21/0.77 line fractions), and thick dark bars hugging the frame
    /// (fake table edges). The two full-length lines that skirt the crop's
    /// rim (fractions 0.21 and 0.77) are load-bearing: headless-verified,
    /// they help the crop's texture-based quad detection lock onto the real
    /// board — a fully clean flat ring misleads it into a shifted grid.
    /// Hole sizing is a measured speed/robustness trade: 0.5 abstains too
    /// slowly for the test's crop-phase wait (~9 s optimized, 100+ s under
    /// the Debug-built recognizer), 0.62 breaks the crop's recognition;
    /// 0.57 abstains in ~7 s optimized (~71 s Debug) and recognizes the
    /// correct board for every crop rect from [0.17,0.83]² down to the
    /// exact board edge [0.25,0.75]².
    static func composedCanvasPNG() -> Data? {
        guard let boardData = PhotoImportUITestSupport.boardImageData,
              let board = UIImage(data: boardData)?.cgImage else { return nil }
        let size = CGSize(width: board.width * 2, height: board.height * 2)
        let holeSide = size.width * 0.57
        let hole = CGRect(x: (size.width - holeSide) / 2,
                          y: (size.height - holeSide) / 2,
                          width: holeSide,
                          height: holeSide)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            // Wood-toned base.
            cg.setFillColor(UIColor(red: 0.72, green: 0.55, blue: 0.35, alpha: 1).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            // Irregularly spaced dark lines, broken around the central hole.
            cg.setStrokeColor(UIColor(white: 0.12, alpha: 1).cgColor)
            cg.setLineWidth(16)
            for f in distractorLineFractions {
                let x = f * size.width
                if x > hole.minX && x < hole.maxX {
                    cg.move(to: CGPoint(x: x, y: 0))
                    cg.addLine(to: CGPoint(x: x, y: hole.minY))
                    cg.move(to: CGPoint(x: x, y: hole.maxY))
                    cg.addLine(to: CGPoint(x: x, y: size.height))
                } else {
                    cg.move(to: CGPoint(x: x, y: 0))
                    cg.addLine(to: CGPoint(x: x, y: size.height))
                }
                let y = f * size.height
                if y > hole.minY && y < hole.maxY {
                    cg.move(to: CGPoint(x: 0, y: y))
                    cg.addLine(to: CGPoint(x: hole.minX, y: y))
                    cg.move(to: CGPoint(x: hole.maxX, y: y))
                    cg.addLine(to: CGPoint(x: size.width, y: y))
                } else {
                    cg.move(to: CGPoint(x: 0, y: y))
                    cg.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            cg.strokePath()
            // Thick dark bars hugging the frame (fake table edges).
            cg.setFillColor(UIColor(white: 0.08, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 48))
            cg.fill(CGRect(x: 0, y: size.height - 48, width: size.width, height: 48))
            cg.fill(CGRect(x: 0, y: 0, width: 48, height: size.height))
            cg.fill(CGRect(x: size.width - 48, y: 0, width: 48, height: size.height))
            // The real board, centered at half scale.
            UIImage(cgImage: board).draw(in: CGRect(x: size.width / 4,
                                                    y: size.height / 4,
                                                    width: size.width / 2,
                                                    height: size.height / 2))
        }
        return image.pngData()
    }
}
#endif
