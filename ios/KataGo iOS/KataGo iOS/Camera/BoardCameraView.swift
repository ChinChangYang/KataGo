//
//  BoardCameraView.swift
//  KataGo iOS
//
//  Full-screen manual board-photo camera (Import ▸ Camera). Frames the board,
//  taps the shutter, and hands the captured JPEG back to the host, which routes
//  it into the existing photo-import funnel. iOS/iPadOS only (see
//  `CameraCaptureController`). No live guidance yet — that is a later task.
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
        ZStack {
            CameraPreviewView(controller: controller)
                .ignoresSafeArea()

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

                controlBar
            }
        }
        .background(Color.black)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
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
                Button("Cancel", role: .cancel, action: onCancel)
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
                Button("Cancel", action: onCancel)
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

    private func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        captureError = nil
        Task {
            defer { isCapturing = false }
            do {
                let data = try await controller.capturePhoto()
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
