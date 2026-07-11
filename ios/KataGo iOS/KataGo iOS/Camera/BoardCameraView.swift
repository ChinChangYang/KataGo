//
//  BoardCameraView.swift
//  KataGo iOS
//
//  Full-screen manual board-photo camera (Import ▸ Camera). Frames the board,
//  taps the shutter, and hands the captured JPEG back to the host, which routes
//  it into the existing photo-import funnel. iOS/iPadOS only (see
//  `CameraCaptureController`). Overlays live board-framing guidance: a quad
//  outline plus one prioritized message chip. Guidance never gates the shutter.
//

#if os(iOS)

import AVFoundation
import SwiftUI
import UIKit

struct BoardCameraView: View {
    /// Called with the captured JPEG bytes; the host dismisses this cover and
    /// forwards the data into the photo-import funnel.
    let onCapture: (Data) -> Void
    /// Called when the user cancels; the host dismisses this cover.
    let onCancel: () -> Void

    @State private var controller = CameraCaptureController()
    @State private var permission: Permission = .checking
    @State private var isCapturing = false
    @State private var captureError: String?
    @State private var torchOn = false
    /// Set once the cover is being dismissed (Cancel tapped or `.onDisappear`).
    /// A capture already in AVFoundation's pipeline can still resolve after
    /// this; when it does, its result is dropped so a late `onCapture` can't
    /// leak a stale stash or force-dismiss a freshly reopened cover.
    @State private var isDismissed = false

    /// Main-actor view model fed by the live-guidance coordinator. Holds the
    /// hysteresis-smoothed message and the per-frame overlay quad.
    @State private var presenter = GuidancePresenter()
    /// Retained so the video-output delegate stays alive; wired once in `camera`.
    @State private var guidanceCoordinator: CameraGuidanceCoordinator?

    @Environment(\.scenePhase) private var scenePhase

    private enum Permission {
        case checking
        case authorized
        case denied
    }

    init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onCancel = onCancel
    }

    var body: some View {
        Group {
            switch permission {
            case .checking:
                checking
            case .authorized:
                camera
            case .denied:
                denied
            }
        }
        .task { await resolvePermission() }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                controller.stop()
                // The system turns the torch off when the session stops; reset
                // the icon so it doesn't keep showing bolt.fill.
                torchOn = false
            case .active:
                if permission == .authorized {
                    controller.start()
                }
            default:
                break
            }
        }
    }

    // MARK: - Phases

    private var checking: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }

    private var camera: some View {
        // While the session is interrupted, guidance frames stop, so the chip and
        // quad overlay would freeze on their last value — a stale green "Looks
        // good" could sit under the interruption banner. Hide both for the
        // duration of the interruption; the presenter is reset when it ends so
        // guidance re-establishes from a clean streak.
        let interrupted = controller.interruptionMessage != nil
        return ZStack {
            CameraPreviewView(controller: controller)
                .ignoresSafeArea()

            if !interrupted {
                guidanceOverlay
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                if let message = controller.interruptionMessage {
                    interruptionBanner(message)
                }

                Spacer()

                if let captureError {
                    Text(captureError)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.85), in: Capsule())
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("BoardCamera.captureError")
                }

                if !interrupted {
                    guidanceChip
                }

                controlBar
            }
        }
        .background(Color.black)
        .onAppear {
            controller.start()
            setUpGuidance()
        }
        .onDisappear {
            isDismissed = true
            controller.stop()
        }
        .onChange(of: controller.interruptionMessage) { _, message in
            if message == nil {
                // When the interruption clears, rewind guidance so a stale
                // overlay can't reappear before fresh frames arrive.
                presenter.reset()
            } else {
                // The system turns the torch off during an interruption; reset
                // the icon so it doesn't keep showing bolt.fill.
                torchOn = false
            }
        }
    }

    /// Strokes the detected board quad, converting the device-space corners to
    /// the preview layer's coordinates on the main actor (where the layer lives)
    /// before handing static points to the draw closure. Green when the framing
    /// looks good, orange while there is still something to fix. Updates every
    /// frame — no hysteresis on geometry.
    private var guidanceOverlay: some View {
        let points: [CGPoint]? = presenter.deviceQuad.flatMap { controller.layerPoints(for: $0) }
        let strokeColor: Color = presenter.looksGood ? .green : .orange
        return Canvas { context, _ in
            guard let points, points.count == 4 else { return }
            var path = Path()
            path.move(to: points[0])
            path.addLine(to: points[1])
            path.addLine(to: points[2])
            path.addLine(to: points[3])
            path.closeSubpath()
            context.stroke(path,
                           with: .color(strokeColor),
                           style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        }
    }

    /// One prioritized, hysteresis-smoothed guidance message. Shown from the
    /// first frame on (initial state = "Point the camera at the board"). Never
    /// gates the shutter.
    private var guidanceChip: some View {
        let issue = presenter.displayedIssue
        let message = GuidanceMessages.text(for: issue)
        return HStack(spacing: 6) {
            Image(systemName: GuidanceMessages.symbolName(for: issue))
                .foregroundStyle(presenter.looksGood ? .green : .orange)
            Text(message)
                .foregroundStyle(.white)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("BoardCamera.guidance")
        .accessibilityLabel(message)
    }

    /// Creates and attaches the live-guidance coordinator exactly once. The
    /// coordinator republishes each analysis onto the main actor via the presenter.
    private func setUpGuidance() {
        guard guidanceCoordinator == nil else { return }
        let presenter = self.presenter
        let coordinator = CameraGuidanceCoordinator { guidance, quad in
            presenter.ingest(guidance, quad: quad)
        }
        guidanceCoordinator = coordinator
        controller.attachGuidanceCoordinator(coordinator)
    }

    private var denied: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "camera.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Camera access is needed to photograph your board.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                    .accessibilityIdentifier("BoardCamera.cancel")
                Spacer()
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Controls

    private var controlBar: some View {
        ZStack {
            shutterButton

            HStack {
                Button("Cancel", action: cancel)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("BoardCamera.cancel")
                    .accessibilityLabel("Cancel")

                Spacer()

                torchButton
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
        .padding(.top, 12)
    }

    private var shutterButton: some View {
        Button(action: capture) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                Circle()
                    .fill(.white)
                    .frame(width: 60, height: 60)
            }
        }
        .disabled(isCapturing)
        .opacity(isCapturing ? 0.5 : 1)
        .accessibilityIdentifier("BoardCamera.shutter")
        .accessibilityLabel("Capture photo")
    }

    @ViewBuilder
    private var torchButton: some View {
        if controller.isTorchAvailable {
            Button(action: toggleTorch) {
                Image(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("BoardCamera.torch")
            .accessibilityLabel(torchOn ? "Turn off torch" : "Turn on torch")
        } else {
            // Balance the leading Cancel so the shutter stays centered.
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private func interruptionBanner(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.6))
            .accessibilityIdentifier("BoardCamera.interruption")
    }

    // MARK: - Actions

    private func resolvePermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permission = granted ? .authorized : .denied
        case .denied, .restricted:
            permission = .denied
        @unknown default:
            permission = .denied
        }
    }

    /// Latches the dismissal before dismissing the cover, so a still-in-flight
    /// capture that resolves after this drops its result instead of leaking a
    /// stale stash back to the host.
    private func cancel() {
        isDismissed = true
        onCancel()
    }

    private func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        captureError = nil
        Task {
            defer { isCapturing = false }
            do {
                let data = try await controller.capturePhoto()
                // The cover may have been dismissed (Cancel) while the photo was
                // in AVFoundation's pipeline; if so, drop the late result.
                guard !isDismissed else { return }
                onCapture(data)
            } catch {
                captureError = "Couldn't capture the photo. Try again."
            }
        }
    }

    private func toggleTorch() {
        torchOn.toggle()
        controller.setTorch(torchOn)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#endif
