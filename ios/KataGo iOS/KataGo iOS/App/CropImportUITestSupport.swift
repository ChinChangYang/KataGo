//
//  CropImportUITestSupport.swift
//  KataGo iOS
//
//  DEBUG-only seam for the crop-recovery UI test. Feeds the photo-import
//  funnel an image the recognizer cannot read full-frame but can read once
//  cropped: the bundled wide-margin 9x9 board (PhotoImportUITestSupport's
//  blob, 1280×960) drawn at 50% linear scale in the center of a 2560×1920
//  canvas whose border carries frame-scale distractor edges (a competing
//  coarse grid and thick frame bars), which defeat full-frame board
//  detection. The UI test drives: full-frame failure → crop phase → corner
//  drags → Recognize → preview → Import. PNG output keeps the composition
//  lossless and pixel-deterministic. Mirrors the other import seams;
//  compiled out of Release entirely.
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

    /// The board blob at 50% linear scale centered in a 2× canvas — the board
    /// is exactly the central [0.25,0.75]² of the frame — surrounded by
    /// distractors: a wood-toned base, a competing coarse dark grid across
    /// the whole canvas, and thick dark bars hugging the frame (fake table
    /// edges). The grid is drawn first so the board covers its center.
    static func composedCanvasPNG() -> Data? {
        guard let boardData = PhotoImportUITestSupport.boardImageData,
              let board = UIImage(data: boardData)?.cgImage else { return nil }
        let size = CGSize(width: board.width * 2, height: board.height * 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            // Wood-toned base.
            cg.setFillColor(UIColor(red: 0.72, green: 0.55, blue: 0.35, alpha: 1).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            // Competing coarse dark grid across the whole canvas.
            cg.setStrokeColor(UIColor(white: 0.12, alpha: 1).cgColor)
            cg.setLineWidth(10)
            let step = size.width / 7
            for i in 0...7 {
                let p = CGFloat(i) * step
                cg.move(to: CGPoint(x: p, y: 0))
                cg.addLine(to: CGPoint(x: p, y: size.height))
                cg.move(to: CGPoint(x: 0, y: p))
                cg.addLine(to: CGPoint(x: size.width, y: p))
            }
            cg.strokePath()
            // Thick dark bars hugging the frame (fake table edges).
            cg.setFillColor(UIColor(white: 0.08, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 24))
            cg.fill(CGRect(x: 0, y: size.height - 24, width: size.width, height: 24))
            cg.fill(CGRect(x: 0, y: 0, width: 24, height: size.height))
            cg.fill(CGRect(x: size.width - 24, y: 0, width: 24, height: size.height))
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
