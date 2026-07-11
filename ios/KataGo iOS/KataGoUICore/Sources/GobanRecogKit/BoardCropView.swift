//
//  BoardCropView.swift
//  GobanRecogKit
//
//  The crop control for the photo-import sheet: the photo aspect-fit in the
//  available space with a draggable crop rectangle over it — corner handles,
//  edge drags, and interior move, with classification and clamping in the
//  unit-tested CropRectEditor. Binds a normalized top-left-origin crop rect,
//  the exact convention BoardImageIngestion.bgrImage(from:cropNormalized:)
//  consumes. The view constrains itself to the image's aspect ratio so its
//  bounds ≡ the displayed image; UI tests address corners by normalized
//  offsets on the "BoardCropView.cropArea" element because of this.
//

import SwiftUI

public struct BoardCropView: View {
    private let image: CGImage
    @Binding private var cropRect: CGRect // normalized, top-left origin

    /// The crop rect and handle classification captured at drag start; nil
    /// between drags. Translations always apply to `start`, never to the
    /// live rect, so they cannot compound.
    @State private var drag: (start: CGRect, handles: CropHandles)?

    public init(image: CGImage, cropRect: Binding<CGRect>) {
        self.image = image
        self._cropRect = cropRect
    }

    public var body: some View {
        GeometryReader { geo in
            let frame = CropGeometry.fittedFrame(
                imageSize: CGSize(width: image.width, height: image.height),
                in: geo.size)
            let editor = CropRectEditor(bounds: frame)
            let rect = CropGeometry.viewRect(fromNormalized: cropRect, in: frame)

            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                dimming(around: rect, in: geo.size)
                cropBorder(rect)
            }
            .contentShape(Rectangle())
            .gesture(cropGesture(editor: editor, frame: frame))
        }
        .aspectRatio(CGSize(width: image.width, height: image.height), contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crop area")
        .accessibilityHint("Drag the corners to frame the board")
        .accessibilityIdentifier("BoardCropView.cropArea")
    }

    private func cropGesture(editor: CropRectEditor, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let current = CropGeometry.viewRect(fromNormalized: cropRect, in: frame)
                let active = drag ?? (start: current,
                                      handles: editor.handles(at: value.startLocation, in: current))
                if drag == nil { drag = active }
                guard !active.handles.isEmpty else { return }
                let updated = editor.apply(translation: value.translation,
                                           handles: active.handles,
                                           to: active.start)
                cropRect = CropGeometry.normalizedRect(fromView: updated, in: frame)
            }
            .onEnded { _ in drag = nil }
    }

    /// Dims everything outside the crop rect (even-odd fill punch-out).
    private func dimming(around rect: CGRect, in size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(rect)
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    /// White border + four corner dots. Purely decorative: hit-testing and
    /// grab zones belong to the editor's classification.
    private func cropBorder(_ rect: CGRect) -> some View {
        ZStack {
            Rectangle()
                .path(in: rect)
                .stroke(.white, lineWidth: 2)
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.gray.opacity(0.6), lineWidth: 1))
                    .frame(width: 16, height: 16)
                    .position(x: i % 2 == 0 ? rect.minX : rect.maxX,
                              y: i < 2 ? rect.minY : rect.maxY)
            }
        }
        .allowsHitTesting(false)
    }
}
