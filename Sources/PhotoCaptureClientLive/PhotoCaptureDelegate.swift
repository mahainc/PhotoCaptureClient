@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import HistogramKit
import ImageIO
import PhotoCaptureClient
import os

#if os(iOS)
    import UIKit
    import MetalKit
#endif

// MARK: - Delegate

/// Private delegate class that bridges AVCapturePhotoCaptureDelegate callbacks
/// and session notifications to the actor. Inherits NSObject for delegate
/// protocol conformance and conforms to `@unchecked Sendable` to safely
/// cross isolation boundaries.
final class PhotoCaptureDelegate: NSObject, @unchecked Sendable {
    // Callback closures — actor sets these in init
    var onEvent: (@Sendable (PhotoCaptureClient.Event) -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    // Per-capture continuation — set before each capturePhoto call
    var photoContinuation: CheckedContinuation<PhotoCaptureClient.Photo, any Swift.Error>?

    // Frame delivery properties
    var videoDataOutput: AVCaptureVideoDataOutput?
    private let videoDataQueue = DispatchQueue(label: "PhotoCaptureDelegate.videoDataQueue")

    // Depth delivery properties (depth-capable devices only).
    var depthDataOutput: AVCaptureDepthDataOutput?
    let depthDataQueue = DispatchQueue(label: "PhotoCaptureDelegate.depthDataQueue")
    /// Latest converted depth map (DepthFloat32, metric metres), oriented to match the video buffer.
    /// Written on depthDataQueue, read on videoDataQueue when building a throttled wrapper.
    private struct DepthMapState: @unchecked Sendable { var buffer: CVPixelBuffer? }
    private let _latestDepthMap = OSAllocatedUnfairLock<DepthMapState>(initialState: DepthMapState(buffer: nil))
    var latestDepthMap: CVPixelBuffer? {
        get { _latestDepthMap.withLockUnchecked { $0.buffer } }
        set { _latestDepthMap.withLockUnchecked { $0.buffer = newValue } }
    }
    /// Depth is running only when its connection reports `isActive` for the format in use;
    /// a connection can be enabled and inactive at once, which `addOutput` succeeding hides.
    var hasDepth: Bool = false
    /// The zoom text mode replaced to reach the main lens, put back when the mode ends.
    var zoomBeforeTextMode: CGFloat?
    /// EXIF orientation applied to the depth map in software so it matches the rotated/mirrored video
    /// buffer — `.right` (back, 90° CW) or `.rightMirrored` (front). Set during configuration.
    private let _depthExifOrientation = OSAllocatedUnfairLock<CGImagePropertyOrientation>(
        initialState: .right
    )
    var depthExifOrientation: CGImagePropertyOrientation {
        get { _depthExifOrientation.withLock { $0 } }
        set { _depthExifOrientation.withLock { $0 = newValue } }
    }
    #if DEBUG
        /// One-shot guard so the depth map's orientation/dims are logged once per (re)configuration.
        var didLogDepth = false
    #endif

    // Thread-safe continuation for frame delivery.
    // Written from actor context (observePixelBuffers), read from videoDataQueue (captureOutput).
    private let _pixelBufferContinuation = OSAllocatedUnfairLock<
        AsyncStream<PhotoCaptureClient.PixelBufferWrapper>.Continuation?
    >(initialState: nil)

    var pixelBufferContinuation: AsyncStream<PhotoCaptureClient.PixelBufferWrapper>.Continuation? {
        get { _pixelBufferContinuation.withLock { $0 } }
        set { _pixelBufferContinuation.withLock { $0 = newValue } }
    }

    static let defaultFrameIntervalSeconds: CFTimeInterval = 0.333

    // Written from actor context (setFrameDeliveryInterval), read on videoDataQueue.
    private let _frameIntervalSeconds = OSAllocatedUnfairLock<CFTimeInterval>(
        initialState: PhotoCaptureDelegate.defaultFrameIntervalSeconds
    )

    var frameIntervalSeconds: CFTimeInterval {
        get { _frameIntervalSeconds.withLock { $0 } }
        set { _frameIntervalSeconds.withLock { $0 = newValue } }
    }
    var lastFrameTime: CFTimeInterval = 0

    // Depth keeps the detection cadence even when frame delivery is sped up: its CPU conversion
    // is a measurable share of the thermal load and nothing samples it faster.
    let depthIntervalSeconds: CFTimeInterval = PhotoCaptureDelegate.defaultFrameIntervalSeconds

    // Depth maps are converted to Float32 and reoriented on the CPU in every callback, but the
    // sampler reads depth only when a throttled video frame is delivered. Processing all ~30fps was
    // ~10× the work anything downstream consumed, and a measurable share of the thermal load. Gate
    // depth to the detection cadence; a centre-tie breaker tolerates ≤ one interval of staleness.
    // Written and read only on depthDataQueue (serial), so it needs no lock.
    var lastDepthTime: CFTimeInterval = 0

    // Metal renderer callback — receives every frame at full camera rate (no throttling)
    var onFrame: ((_ pixelBuffer: CVPixelBuffer) -> Void)?

    // Framework objects — owned by the delegate, never by the actor
    var captureSession: AVCaptureSession?
    var photoOutput: AVCapturePhotoOutput?
    var currentDevice: AVCaptureDevice?
    var currentInput: AVCaptureDeviceInput?
    let sessionQueue = DispatchQueue(label: "PhotoCaptureDelegate.sessionQueue")

    var isRunning: Bool {
        captureSession?.isRunning ?? false
    }

    // MARK: - Session Lifecycle

    func configureSession(position: PhotoCaptureClient.CameraPosition) throws {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .photo

        // Find camera device — prefer a depth-capable device for the position so the centre-dot
        // overlay can rank objects by true Z distance; falls back to the wide-angle camera.
        let avPosition: AVCaptureDevice.Position = position == .front ? .front : .back
        guard let device = Self.bestDevice(position: avPosition) else {
            session.commitConfiguration()
            throw PhotoCaptureClient.Error.captureDeviceNotFound(position)
        }

        // Add input
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw PhotoCaptureClient.Error.cannotAddInput
        }
        session.addInput(input)

        // Add output
        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw PhotoCaptureClient.Error.cannotAddOutput
        }
        session.addOutput(output)

        // Add video data output for frame delivery
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: videoDataQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            self.videoDataOutput = videoOutput
        }

        // Add the depth output + select a depth-capable format when available; otherwise just cap the
        // frame rate. Must run before commitConfiguration so the depth connection is wired.
        configureDepth(session: session, device: device)
        onLog?("Depth delivery available: \(hasDepth)")

        session.commitConfiguration()

        self.captureSession = session
        self.photoOutput = output
        self.currentDevice = device
        self.currentInput = input

        // Apply rotation/mirroring AFTER commitConfiguration — connections aren't fully
        // wired before commit on iOS 17+, and unsupported angles silently no-op without
        // the explicit support check.
        applyConnectionOrientation(position: position)
    }

    /// Force every active output connection into portrait + mirror the front camera
    /// so the preview, video frames, and captured photo all share orientation.
    /// Called after `configureSession` and after every `switchCamera` so the input
    /// swap doesn't reset rotation back to the sensor default.
    func applyConnectionOrientation(position: PhotoCaptureClient.CameraPosition) {
        let mirror = position == .front
        // Depth is oriented in SOFTWARE (applyingExifOrientation), not via the connection: depth
        // connections don't reliably rotate depthDataMap (notably with isFilteringEnabled), so the raw
        // map stays sensor-native landscape. Keep one source of truth for depth orientation.
        depthExifOrientation = mirror ? .rightMirrored : .right
        #if DEBUG
            didLogDepth = false
        #endif
        let connections: [AVCaptureConnection?] = [
            videoDataOutput?.connection(with: .video),
            photoOutput?.connection(with: .video),
        ]
        for case let connection? in connections {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirror
            }
        }
    }

    // MARK: - Notification Observers

    func registerNotificationObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(sessionDidStartRunning),
            name: .AVCaptureSessionDidStartRunning,
            object: captureSession
        )
        nc.addObserver(
            self,
            selector: #selector(sessionDidStopRunning),
            name: .AVCaptureSessionDidStopRunning,
            object: captureSession
        )
        nc.addObserver(
            self,
            selector: #selector(sessionRuntimeError),
            name: .AVCaptureSessionRuntimeError,
            object: captureSession
        )
        #if os(iOS)
            nc.addObserver(
                self,
                selector: #selector(sessionWasInterrupted),
                name: .AVCaptureSessionWasInterrupted,
                object: captureSession
            )
            nc.addObserver(
                self,
                selector: #selector(sessionInterruptionEnded),
                name: .AVCaptureSessionInterruptionEnded,
                object: captureSession
            )
        #endif
    }

    func removeNotificationObservers() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func sessionDidStartRunning(_ notification: Notification) {
        onEvent?(.sessionStarted)
    }

    @objc private func sessionDidStopRunning(_ notification: Notification) {
        onEvent?(.sessionStopped)
    }

    #if os(iOS)
        @objc private func sessionWasInterrupted(_ notification: Notification) {
            // Don't sample a frozen depth map while interrupted; it resumes when depth frames flow.
            latestDepthMap = nil
            let reason: PhotoCaptureClient.InterruptionReason
            if let userInfo = notification.userInfo,
                let rawReason = userInfo[AVCaptureSessionInterruptionReasonKey] as? Int,
                let avReason = AVCaptureSession.InterruptionReason(rawValue: rawReason)
            {
                reason = avReason.domainReason
            } else {
                reason = .unknown
            }
            onEvent?(.sessionInterrupted(reason))
        }

        @objc private func sessionInterruptionEnded(_ notification: Notification) {
            onEvent?(.sessionInterruptionEnded)
        }
    #endif

    @objc private func sessionRuntimeError(_ notification: Notification) {
        // A runtime error can drop depth delivery; clear the stale map so ranking falls back cleanly.
        latestDepthMap = nil
        let message: String
        if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError {
            message = error.localizedDescription
        } else {
            message = "Unknown runtime error"
        }
        onEvent?(.sessionRuntimeError(message))
    }
}
