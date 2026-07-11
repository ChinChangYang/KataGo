//
//  CameraCaptureController.swift
//  KataGo iOS
//
//  Owns the AVFoundation capture stack for the manual board-photo camera
//  (Import ▸ Camera). iOS/iPadOS only — the app target also compiles for
//  visionOS, where rear-camera AVCaptureSession capture is unavailable, so the
//  whole file is gated behind `#if os(iOS)` to keep the visionOS build green.
//
//  Concurrency: the class is `@MainActor` (so its `@Observable` state and the
//  notification/KVO/delegate callbacks that touch it are Sendable-clean), while
//  every AVCaptureSession operation runs on a private serial queue — never the
//  main thread. Non-Sendable AVFoundation objects are handed across the queue
//  boundary through reasoned `nonisolated(unsafe)` locals (each is only ever
//  touched on the session queue after the hand-off).
//

#if os(iOS)

import AVFoundation
import Observation
import UIKit
import os

private let cameraLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "chinchangyang.KataGo-iOS",
    category: "camera"
)

/// Errors surfaced by the manual capture path.
enum CameraCaptureError: Error {
    /// The photo finished processing but produced no file data representation.
    case noPhotoData
}

@MainActor
@Observable
final class CameraCaptureController {

    // MARK: Observable UI state (main-actor updated)

    /// True once the back camera is known to have a torch (LED flash). Drives
    /// the torch toggle's visibility in `BoardCameraView`.
    private(set) var isTorchAvailable = false

    /// Non-nil while the session is interrupted or has errored; `BoardCameraView`
    /// shows it as an overlay. Cleared when the interruption ends.
    private(set) var interruptionMessage: String?

    // MARK: Capture stack

    /// The capture session, exposed to `CameraPreviewView` so its preview layer
    /// can bind to it. Read on the main actor; its AVFoundation operations run
    /// on `sessionQueue`.
    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()

    /// Live-guidance frame tap. Frames are delivered to `guidanceCoordinator` on
    /// `guidanceQueue`; toggling this output's connection suspends/resumes
    /// guidance without touching the always-enabled shutter.
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let guidanceQueue = DispatchQueue(label: "chinchangyang.KataGo-iOS.camera.guidance")

    /// Retains the live-guidance coordinator: `AVCaptureVideoDataOutput` holds its
    /// sample-buffer delegate weakly, so the controller must keep it alive.
    private var guidanceCoordinator: CameraGuidanceCoordinator?

    private var videoDevice: AVCaptureDevice?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []

    /// Tokens for the block-based NotificationCenter observers registered in
    /// `setUpNotificationsIfNeeded()`. Unlike selector-based observers, tokens
    /// from `addObserver(forName:object:queue:using:)` are strongly retained
    /// by NotificationCenter until `removeObserver` is called explicitly —
    /// they are NOT auto-removed on deallocation. `deinit` removes them.
    /// `nonisolated(unsafe)` because `deinit` is nonisolated and cannot read
    /// a main-actor-isolated stored property: this array is written once
    /// during registration on the main actor and read exactly once, in
    /// `deinit`, after every other reference to `self` is already gone — so
    /// there is no concurrent access to race.
    @ObservationIgnored nonisolated(unsafe) private var notificationTokens: [NSObjectProtocol] = []

    /// Retains the in-flight photo delegate for the duration of a capture. A
    /// local would be released before the delegate callback fires.
    private var activeCaptureDelegate: PhotoCaptureDelegate?

    private let sessionQueue = DispatchQueue(label: "chinchangyang.KataGo-iOS.camera.session")

    /// Guards one-time session configuration. Not UI state, and only ever
    /// touched on `sessionQueue` — so it is excluded from observation and opts
    /// out of the class's main-actor isolation.
    @ObservationIgnored nonisolated(unsafe) private var sessionConfigured = false

    // MARK: Availability

    /// True iff a back wide-angle video camera exists (false on Simulator).
    static var isCameraAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    // MARK: Lifecycle

    /// Configures (once) and starts the session on the private queue. Safe to
    /// call repeatedly (e.g. on re-appear); a running session is left alone.
    func start() {
        setUpNotificationsIfNeeded()

        nonisolated(unsafe) let session = self.session
        nonisolated(unsafe) let photoOutput = self.photoOutput
        nonisolated(unsafe) let videoDataOutput = self.videoDataOutput
        sessionQueue.async { [weak self] in
            self?.configureSessionIfNeeded(session: session,
                                           photoOutput: photoOutput,
                                           videoDataOutput: videoDataOutput)
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    /// Stops the running session on the private queue. Observers are left in
    /// place so a later `start()` resumes without re-registering; they are
    /// removed explicitly in `deinit`, not auto-removed on deallocation.
    func stop() {
        nonisolated(unsafe) let session = self.session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    /// Removes the block-based NotificationCenter observers registered in
    /// `setUpNotificationsIfNeeded()`. Required because those tokens are
    /// strongly held by NotificationCenter and are not auto-removed on
    /// deallocation (that only applies to selector-based observers).
    deinit {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Preview wiring

    /// Called from `CameraPreviewView.makeUIView` with the hosting layer so the
    /// rotation coordinator can be created and preview rotation applied.
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        setUpRotationCoordinatorIfPossible()
    }

    /// Converts a device-space board quad (top-left origin, normalized, TL, TR,
    /// BR, BL — Vision's coords after the buffer y-flip) into the preview layer's
    /// coordinate space for the on-screen overlay, letting AVFoundation account
    /// for rotation, mirroring and `.resizeAspectFill` gravity. Returns `nil`
    /// until the preview layer exists. Main-actor only: the layer lives here.
    func layerPoints(for deviceQuad: [CGPoint]) -> [CGPoint]? {
        guard let previewLayer else { return nil }
        return deviceQuad.map { previewLayer.layerPointConverted(fromCaptureDevicePoint: $0) }
    }

    // MARK: Live guidance

    /// Registers the live-guidance coordinator as the video-data-output delegate,
    /// retaining it (AVFoundation holds delegates weakly). Idempotent-safe to
    /// call once after `start()`.
    func attachGuidanceCoordinator(_ coordinator: CameraGuidanceCoordinator) {
        guidanceCoordinator = coordinator
        nonisolated(unsafe) let output = self.videoDataOutput
        nonisolated(unsafe) let delegate = coordinator
        let queue = guidanceQueue
        sessionQueue.async {
            output.setSampleBufferDelegate(delegate, queue: queue)
        }
    }

    /// Suspends or resumes live-guidance frame delivery by toggling the video
    /// output's connection. Called around photo capture and session
    /// interruptions so no analysis competes with a capture or runs while the
    /// camera is unavailable. The shutter is never gated on this.
    func setGuidancePaused(_ paused: Bool) {
        nonisolated(unsafe) let output = self.videoDataOutput
        sessionQueue.async {
            output.connection(with: .video)?.isEnabled = !paused
        }
    }

    // MARK: Torch

    /// Turns the torch on/off. Failures are swallowed (logged) — torch is a
    /// best-effort convenience, not a capture requirement.
    func setTorch(_ on: Bool) {
        guard let device = videoDevice, device.hasTorch else { return }
        nonisolated(unsafe) let torchDevice = device
        sessionQueue.async {
            do {
                try torchDevice.lockForConfiguration()
                defer { torchDevice.unlockForConfiguration() }
                torchDevice.torchMode = on ? .on : .off
            } catch {
                cameraLogger.error("Torch toggle failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Capture

    /// Captures a single JPEG frame and returns its encoded bytes. Explicitly
    /// requests the JPEG codec (never HEVC/HEIC) so the bytes flow straight into
    /// the existing photo-import funnel.
    func capturePhoto() async throws -> Data {
        // Free the ANE/CPU from live guidance for the duration of the capture.
        setGuidancePaused(true)
        let captureAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        nonisolated(unsafe) let photoOutput = self.photoOutput

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoCaptureDelegate { [weak self] result in
                continuation.resume(with: result)
                Task { @MainActor in
                    self?.activeCaptureDelegate = nil
                    // Resume guidance unless the session is interrupted.
                    if self?.interruptionMessage == nil {
                        self?.setGuidancePaused(false)
                    }
                }
            }
            activeCaptureDelegate = delegate

            nonisolated(unsafe) let capturingDelegate = delegate
            sessionQueue.async {
                let settings = AVCapturePhotoSettings(
                    format: [AVVideoCodecKey: AVVideoCodecType.jpeg]
                )
                if let captureAngle,
                   let connection = photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(captureAngle) {
                    connection.videoRotationAngle = captureAngle
                }
                photoOutput.capturePhoto(with: settings, delegate: capturingDelegate)
            }
        }
    }

    // MARK: Session configuration (session queue)

    nonisolated private func configureSessionIfNeeded(session: AVCaptureSession,
                                                      photoOutput: AVCapturePhotoOutput,
                                                      videoDataOutput: AVCaptureVideoDataOutput) {
        guard !sessionConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            cameraLogger.error("Camera session configuration failed: no usable back camera input")
            return
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            cameraLogger.error("Camera session configuration failed: cannot add photo output")
            return
        }
        session.addOutput(photoOutput)

        // Live-guidance frame tap: 420f biplanar full-range luma, dropping late
        // frames so guidance never backs up. Best-effort — capture works without it.
        if session.canAddOutput(videoDataOutput) {
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            session.addOutput(videoDataOutput)
        }

        configureDevice(device)

        session.commitConfiguration()
        sessionConfigured = true

        let torchAvailable = device.hasTorch
        nonisolated(unsafe) let deviceRef = device
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.videoDevice = deviceRef
            self.isTorchAvailable = torchAvailable
            self.setUpRotationCoordinatorIfPossible()
        }
    }

    /// Continuous autofocus/auto-exposure, applied only when supported and only
    /// while the device is locked for configuration.
    nonisolated private func configureDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        } catch {
            cameraLogger.error("Camera device configuration failed: \(error.localizedDescription)")
        }
    }

    // MARK: Rotation

    /// Creates the rotation coordinator once both the device and preview layer
    /// exist (they arrive from independent code paths), and starts tracking the
    /// horizon-level preview angle.
    private func setUpRotationCoordinatorIfPossible() {
        guard rotationCoordinator == nil,
              let device = videoDevice,
              let previewLayer else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device,
                                                              previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation()

        let observation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyPreviewRotation()
            }
        }
        rotationObservations = [observation]
    }

    private func applyPreviewRotation() {
        guard let coordinator = rotationCoordinator,
              let connection = previewLayer?.connection else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    // MARK: Interruption / error surfacing

    private func setUpNotificationsIfNeeded() {
        guard notificationTokens.isEmpty else { return }
        let center = NotificationCenter.default

        let interrupted = center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            Task { @MainActor in
                self?.handleInterruption(reasonRawValue: reason)
            }
        }

        let ended = center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.interruptionMessage = nil
                self?.setGuidancePaused(false)
            }
        }

        let runtimeError = center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.interruptionMessage = "The camera stopped unexpectedly. Try reopening the camera."
                self?.setGuidancePaused(true)
            }
        }

        notificationTokens = [interrupted, ended, runtimeError]
    }

    private func handleInterruption(reasonRawValue: Int?) {
        if let reasonRawValue,
           let reason = AVCaptureSession.InterruptionReason(rawValue: reasonRawValue),
           reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
            interruptionMessage = "Camera unavailable in Split View. Use full screen to photograph your board."
        } else {
            interruptionMessage = "The camera was interrupted."
        }
        setGuidancePaused(true)
    }
}

/// Bridges the one-shot `AVCapturePhotoCaptureDelegate` callback to a checked
/// continuation. The controller retains it for the capture's duration.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, any Error>) -> Void
    private var didFinish = false

    init(completion: @escaping (Result<Data, any Error>) -> Void) {
        self.completion = completion
        super.init()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: (any Error)?) {
        guard !didFinish else { return }
        didFinish = true
        if let error {
            completion(.failure(error))
        } else if let data = photo.fileDataRepresentation() {
            completion(.success(data))
        } else {
            completion(.failure(CameraCaptureError.noPhotoData))
        }
    }
}

#endif
