//
//  CropGeometry.swift
//  GobanRecogKit
//
//  Aspect-fitting the photo into the available container, and mapping a
//  rectangle between normalized image space ([0,1]², top-left origin — the
//  BoardImageIngestion crop contract) and view points.
//
//  Was CropRectEditor.swift, whose draggable-rect half retired with
//  BoardCropView when the grid quad replaced the crop phase. What survives is
//  the coordinate plumbing, still used by BoardQuadView for the fitted image
//  frame and by the automatic-detection fallback, which crops to a user quad's
//  bounding box.
//

import CoreGraphics

public enum CropGeometry {

    /// The aspect-fit frame of `imageSize` centered in `container` (view
    /// points). Zero or negative inputs produce `.zero`.
    public static func fittedFrame(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width,
                        container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Normalized (top-left-origin, [0,1]²) → view points inside `frame`.
    public static func viewRect(fromNormalized rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX * frame.width,
               y: frame.minY + rect.minY * frame.height,
               width: rect.width * frame.width,
               height: rect.height * frame.height)
    }

    /// View points inside `frame` → normalized (top-left-origin, [0,1]²).
    /// A degenerate frame yields the full-frame rect (safe fallback while
    /// layout is settling).
    public static func normalizedRect(fromView rect: CGRect, in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(x: (rect.minX - frame.minX) / frame.width,
                      y: (rect.minY - frame.minY) / frame.height,
                      width: rect.width / frame.width,
                      height: rect.height / frame.height)
    }
}
