//
//  CropRectEditor.swift
//  GobanRecogKit
//
//  Pure geometry for the crop UI: aspect-fitting the photo into the
//  available container, mapping the crop rect between normalized image space
//  ([0,1]², top-left origin — the BoardImageIngestion crop contract) and view
//  points, classifying where a drag starts (corner / edge / interior), and
//  applying drag translations with bounds- and minimum-size clamping.
//  UI-independent so the whole interaction model is unit-testable;
//  `BoardCropView` is a thin gesture/rendering shell over this.
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

/// Which sides of the crop rect a drag moves: a corner is two sides, an edge
/// is one, and interior "move" is all four (pure translation).
public struct CropHandles: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let minX = CropHandles(rawValue: 1 << 0)
    public static let maxX = CropHandles(rawValue: 1 << 1)
    public static let minY = CropHandles(rawValue: 1 << 2)
    public static let maxY = CropHandles(rawValue: 1 << 3)
    public static let move: CropHandles = [.minX, .maxX, .minY, .maxY]
}

public struct CropRectEditor: Sendable {

    /// The fitted image frame the crop rect lives in (view points).
    public let bounds: CGRect
    /// Minimum crop size as a fraction of each bounds dimension.
    public let minFraction: CGFloat
    /// Grab radius for corners; edge strips use the same distance.
    public let grabRadius: CGFloat

    public init(bounds: CGRect, minFraction: CGFloat = 0.15, grabRadius: CGFloat = 24) {
        self.bounds = bounds
        self.minFraction = minFraction
        self.grabRadius = grabRadius
    }

    /// Classifies a drag that starts at `point` against `rect` (both in view
    /// points): the nearest corner within the grab radius wins, then the
    /// nearest edge strip, then interior move; a start outside every zone is
    /// ignored (empty set).
    public func handles(at point: CGPoint, in rect: CGRect) -> CropHandles {
        let corners: [(CGPoint, CropHandles)] = [
            (CGPoint(x: rect.minX, y: rect.minY), [.minX, .minY]),
            (CGPoint(x: rect.maxX, y: rect.minY), [.maxX, .minY]),
            (CGPoint(x: rect.minX, y: rect.maxY), [.minX, .maxY]),
            (CGPoint(x: rect.maxX, y: rect.maxY), [.maxX, .maxY]),
        ]
        var bestCorner: (distance: CGFloat, handles: CropHandles)?
        for (corner, handles) in corners {
            let d = hypot(point.x - corner.x, point.y - corner.y)
            if d <= grabRadius, d < (bestCorner?.distance ?? .infinity) {
                bestCorner = (d, handles)
            }
        }
        if let bestCorner { return bestCorner.handles }

        // Edge strips: within the grab radius of one side, inside that side's
        // span (extended by the radius so strips reach the corners).
        let withinX = point.x >= rect.minX - grabRadius && point.x <= rect.maxX + grabRadius
        let withinY = point.y >= rect.minY - grabRadius && point.y <= rect.maxY + grabRadius
        var edges: [(distance: CGFloat, handles: CropHandles)] = []
        if withinY {
            edges.append((abs(point.x - rect.minX), .minX))
            edges.append((abs(point.x - rect.maxX), .maxX))
        }
        if withinX {
            edges.append((abs(point.y - rect.minY), .minY))
            edges.append((abs(point.y - rect.maxY), .maxY))
        }
        if let nearest = edges.filter({ $0.distance <= grabRadius })
            .min(by: { $0.distance < $1.distance }) {
            return nearest.handles
        }

        return rect.contains(point) ? .move : []
    }

    /// Applies a drag `translation` to `startRect` for the given handles,
    /// clamping to `bounds` and the minimum size. `startRect` must be the
    /// rect at DRAG START (the same rect for every update of one gesture),
    /// so translations never compound.
    public func apply(translation: CGSize, handles: CropHandles, to startRect: CGRect) -> CGRect {
        guard !handles.isEmpty else { return startRect }
        let minW = bounds.width * minFraction
        let minH = bounds.height * minFraction

        if handles == .move {
            let x = min(max(startRect.minX + translation.width, bounds.minX),
                        bounds.maxX - startRect.width)
            let y = min(max(startRect.minY + translation.height, bounds.minY),
                        bounds.maxY - startRect.height)
            return CGRect(x: x, y: y, width: startRect.width, height: startRect.height)
        }

        var minXv = startRect.minX
        var maxXv = startRect.maxX
        var minYv = startRect.minY
        var maxYv = startRect.maxY
        if handles.contains(.minX) {
            minXv = min(max(minXv + translation.width, bounds.minX), maxXv - minW)
        }
        if handles.contains(.maxX) {
            maxXv = max(min(maxXv + translation.width, bounds.maxX), minXv + minW)
        }
        if handles.contains(.minY) {
            minYv = min(max(minYv + translation.height, bounds.minY), maxYv - minH)
        }
        if handles.contains(.maxY) {
            maxYv = max(min(maxYv + translation.height, bounds.maxY), minYv + minH)
        }
        return CGRect(x: minXv, y: minYv, width: maxXv - minXv, height: maxYv - minYv)
    }
}
