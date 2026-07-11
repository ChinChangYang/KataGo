//
//  CameraPreviewView.swift
//  KataGo iOS
//
//  SwiftUI bridge that hosts an `AVCaptureVideoPreviewLayer` for the manual
//  board-photo camera. iOS/iPadOS only (see `CameraCaptureController`). The
//  hosting layer is handed to the controller via `attachPreviewLayer(_:)`; the
//  controller reuses it for the live-guidance overlay's device-point conversion
//  (`CameraCaptureController.layerPoints(for:)`), so this bridge needs no changes
//  to support guidance — the overlay is drawn by `BoardCameraView`.
//

#if os(iOS)

import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let controller: CameraCaptureController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = controller.session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        controller.attachPreviewLayer(view.videoPreviewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    /// A `UIView` backed directly by an `AVCaptureVideoPreviewLayer`, so the
    /// preview always tracks the view's bounds without manual layout.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // Safe: `layerClass` guarantees the backing layer's type.
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

#endif
