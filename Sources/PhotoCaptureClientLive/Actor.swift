@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import PhotoCaptureClient
import os

#if os(iOS)
    import UIKit
    import MetalKit
#else
    import AppKit
#endif

// MARK: - Delegate

/// Private delegate class that bridges AVCapturePhotoCaptureDelegate callbacks
/// and session notifications to the actor. Inherits NSObject for delegate
/// protocol conformance and conforms to `@unchecked Sendable` to safely
/// cross isolation boundaries.
private final class PhotoCaptureDelegate: NSObject, @unchecked Sendable {
    // Callback closures — actor sets these in init
    var onEvent: (@Sendable (PhotoCaptureClient.Event) -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    // Per-capture continuation — set before each capturePhoto call
    var photoContinuation: CheckedContinuation<PhotoCaptureClient.Photo, any Swift.Error>?

    // Frame delivery properties
    private(set) var videoDataOutput: AVCaptureVideoDataOutput?
    private let videoDataQueue = DispatchQueue(label: "PhotoCaptureDelegate.videoDataQueue")

    // Depth delivery properties (depth-capable devices only).
    private(set) var depthDataOutput: AVCaptureDepthDataOutput?
    private let depthDataQueue = DispatchQueue(label: "PhotoCaptureDelegate.depthDataQueue")
    /// Latest converted depth map (DepthFloat32, metric metres), oriented to match the video buffer.
    /// Written on depthDataQueue, read on videoDataQueue when building a throttled wrapper.
    private struct DepthMapState: @unchecked Sendable { var buffer: CVPixelBuffer? }
    private let _latestDepthMap = OSAllocatedUnfairLock<DepthMapState>(initialState: DepthMapState(buffer: nil))
    var latestDepthMap: CVPixelBuffer? {
        get { _latestDepthMap.withLockUnchecked { $0.buffer } }
        set { _latestDepthMap.withLockUnchecked { $0.buffer = newValue } }
    }
    /// Whether depth is actually running: a depth output is attached AND its connection
    /// reported `isActive` for the format in use.
    ///
    /// It used to be set on `addOutput` succeeding, which made it claim depth on a device
    /// that delivered none — the connection can be enabled and inactive at once. Nothing
    /// downstream could tell the difference, so `latestDepthMap` stayed `nil` forever
    /// while this said `true`.
    private(set) var hasDepth: Bool = false
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
        private var didLogDepth = false
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

    // Throttling: only deliver a frame every 333ms (~3fps) for YOLO inference.
    // 3fps is visually smooth for detection boxes while reducing ~40% inference CPU.
    private let frameIntervalSeconds: CFTimeInterval = 0.333
    private var lastFrameTime: CFTimeInterval = 0

    // Depth maps are converted to Float32 and reoriented on the CPU in every callback, but the
    // sampler reads depth only when a throttled video frame is delivered. Processing all ~30fps was
    // ~10× the work anything downstream consumed, and a measurable share of the thermal load. Gate
    // depth to the detection cadence; a centre-tie breaker tolerates ≤ one interval of staleness.
    // Written and read only on depthDataQueue (serial), so it needs no lock.
    private var lastDepthTime: CFTimeInterval = 0

    // Metal renderer callback — receives every frame at full camera rate (no throttling)
    var onFrame: ((_ pixelBuffer: CVPixelBuffer) -> Void)?

    // Framework objects — owned by the delegate, never by the actor
    private(set) var captureSession: AVCaptureSession?
    private(set) var photoOutput: AVCapturePhotoOutput?
    private(set) var currentDevice: AVCaptureDevice?
    private(set) var currentInput: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: "PhotoCaptureDelegate.sessionQueue")

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
    private func applyConnectionOrientation(position: PhotoCaptureClient.CameraPosition) {
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

    // MARK: - Device & Depth Selection

    /// Discover the best capture device for a position, preferring depth-capable virtual devices
    /// (LiDAR / dual / TrueDepth) over the plain wide-angle camera.
    private static func bestDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        #if os(iOS)
            let preferred: [AVCaptureDevice.DeviceType] =
                position == .front
                ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
                : [
                    .builtInLiDARDepthCamera,
                    .builtInDualWideCamera,
                    .builtInDualCamera,
                    .builtInWideAngleCamera,
                ]
        #else
            let preferred: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        #endif
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferred,
            mediaType: .video,
            position: position
        )
        for type in preferred {
            if let match = discovery.devices.first(where: { $0.deviceType == type }) {
                return match
            }
        }
        return discovery.devices.first
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// Every device format that supports depth, each paired with its preferred depth
    /// format, ranked best-quality first.
    ///
    /// Selecting a depth-capable format puts the session into input-priority mode, so
    /// this format — not the `.photo` preset — drives the live preview resolution.
    /// Ranking by raw pixel count alone tends to pick a **binned** format (faster but
    /// soft/noisy), which visibly degrades the preview, so the rank is quality-first:
    /// non-binned over binned, then larger video dimensions.
    ///
    /// A *list*, not a single best, because the best-quality format is not always one
    /// the hardware can actually deliver depth on alongside the session's other
    /// outputs — see `configureDepth`.
    private static func depthCapableFormats(
        for device: AVCaptureDevice
    ) -> [(format: AVCaptureDevice.Format, depthFormat: AVCaptureDevice.Format)] {
        device.formats
            .compactMap { format -> (AVCaptureDevice.Format, AVCaptureDevice.Format)? in
                let depthFormats = format.supportedDepthDataFormats
                guard !depthFormats.isEmpty else { return nil }
                let preferredDepth =
                    depthFormats.first {
                        CMFormatDescriptionGetMediaSubType($0.formatDescription)
                            == kCVPixelFormatType_DepthFloat16
                    } ?? depthFormats.first
                guard let depthFormat = preferredDepth else { return nil }
                return (format, depthFormat)
            }
            .sorted { lhs, rhs in
                // Lexicographic: non-binned dominates, ties broken by resolution.
                let lhsBinned = lhs.0.isVideoBinned
                let rhsBinned = rhs.0.isVideoBinned
                if lhsBinned != rhsBinned { return !lhsBinned }
                return Self.pixelCount(of: lhs.0) > Self.pixelCount(of: rhs.0)
            }
            .map { (format: $0.0, depthFormat: $0.1) }
    }

    private static func pixelCount(of format: AVCaptureDevice.Format) -> Int {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return Int(dimensions.width) * Int(dimensions.height)
    }

    /// Add/refresh the depth output for `device`, settling on the highest-quality format
    /// whose depth connection the hardware will actually run — or tear depth down when
    /// none of them will. Must run inside a `beginConfiguration`/`commitConfiguration`
    /// block.
    ///
    /// **Why this tries formats instead of picking one.** Choosing the best depth-capable
    /// format and trusting it was wrong in a way that gave no sign of being wrong. On an
    /// iPhone 11 Pro Max the dual-wide camera lists 14 depth-capable formats, every one
    /// of them non-binned — so the non-binned preference never discriminated and the
    /// ranking degenerated to "largest", landing on 4032x3024. At 12MP, alongside a photo
    /// output and a video-data output, the hardware cannot also run depth: the depth
    /// connection comes back `isEnabled == true` but `isActive == false`, nothing throws,
    /// nothing logs, and the delegate is simply never called. Depth was dead on that
    /// device while this function reported success. Capping to 1920x1440 made the same
    /// connection active and metric depth flowed immediately.
    ///
    /// A fixed resolution cap would only move the guess: another device may carry depth at
    /// a higher format, or fail at a lower one. `isActive` is the hardware's own answer,
    /// readable before `commitConfiguration`, so this asks it — stepping down the ranked
    /// list until one activates. The preview therefore keeps the best format that does not
    /// cost depth, rather than the best format outright.
    private func configureDepth(
        session: AVCaptureSession,
        device: AVCaptureDevice
    ) {
        let candidates = Self.depthCapableFormats(for: device)
        guard !candidates.isEmpty else {
            disableDepth(session: session, device: device, restoring: nil)
            return
        }

        // The connection only exists once the output is attached, and its `isActive` is
        // the whole test — so the output goes on before the formats are tried.
        guard let output = attachDepthOutput(to: session) else {
            disableDepth(session: session, device: device, restoring: nil)
            return
        }

        let formatBeforeProbing = device.activeFormat
        for candidate in candidates {
            guard (try? device.lockForConfiguration()) != nil else { continue }
            device.activeFormat = candidate.format
            device.activeDepthDataFormat = candidate.depthFormat
            applyClampedFrameRate(device, target: 30)
            device.unlockForConfiguration()

            if output.connection(with: .depthData)?.isActive == true {
                hasDepth = true
                let dimensions = CMVideoFormatDescriptionGetDimensions(
                    candidate.format.formatDescription
                )
                onLog?("Depth active at \(dimensions.width)x\(dimensions.height)")
                return
            }
        }

        // Nothing this device offers can carry depth beside the rest of the session.
        onLog?("No depth-capable format could activate; continuing without depth")
        disableDepth(session: session, device: device, restoring: formatBeforeProbing)
    }

    /// Attach the depth output, reusing one already on the session.
    private func attachDepthOutput(to session: AVCaptureSession) -> AVCaptureDepthDataOutput? {
        if let existing = depthDataOutput { return existing }
        let output = AVCaptureDepthDataOutput()
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        // Ranking reads a 20th-percentile sample over a box and uses it only to break a centre tie,
        // so it does not need temporal/spatial hole-filling — and filtering is continuous depth-
        // pipeline work. Off trades a little sparsity (holes fall back to centre ranking, which is
        // the primary criterion anyway) for a steady thermal saving.
        output.isFilteringEnabled = false
        output.setDelegate(self, callbackQueue: depthDataQueue)
        depthDataOutput = output
        return output
    }

    /// Tear depth down and leave the device in a sane state.
    ///
    /// `restoring` puts back the format the device had before probing, so a device that
    /// cannot run depth is left on its own preferred format rather than on whichever
    /// candidate was tried last.
    private func disableDepth(
        session: AVCaptureSession,
        device: AVCaptureDevice,
        restoring previousFormat: AVCaptureDevice.Format?
    ) {
        if let existing = depthDataOutput {
            session.removeOutput(existing)
            depthDataOutput = nil
        }
        hasDepth = false
        if (try? device.lockForConfiguration()) != nil {
            if let previousFormat {
                device.activeFormat = previousFormat
            }
            applyClampedFrameRate(device, target: 30)
            device.unlockForConfiguration()
        }
    }

    /// Clamp a target FPS to the active format's supported range and pin min == max. Caller must
    /// already hold `lockForConfiguration`.
    private func applyClampedFrameRate(
        _ device: AVCaptureDevice,
        target: Double
    ) {
        guard let range = device.activeFormat.videoSupportedFrameRateRanges.first else { return }
        let fps = min(max(target, range.minFrameRate), range.maxFrameRate)
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    func startRunning() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    func stopRunning() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
        }
    }

    func switchCamera(to position: PhotoCaptureClient.CameraPosition) throws {
        guard let session = captureSession else {
            throw PhotoCaptureClient.Error.captureSessionNotRunning
        }

        let avPosition: AVCaptureDevice.Position = position == .front ? .front : .back
        guard let newDevice = Self.bestDevice(position: avPosition) else {
            throw PhotoCaptureClient.Error.captureDeviceNotFound(position)
        }

        let newInput = try AVCaptureDeviceInput(device: newDevice)

        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
        }
        guard session.canAddInput(newInput) else {
            if let currentInput {
                session.addInput(currentInput)
            }
            session.commitConfiguration()
            throw PhotoCaptureClient.Error.cannotAddInput
        }
        session.addInput(newInput)

        // Stale depth from the previous device must not be sampled against the new device's frames.
        latestDepthMap = nil
        // Re-establish (or tear down) depth for the new device while still inside the configuration.
        configureDepth(session: session, device: newDevice)

        session.commitConfiguration()

        self.currentDevice = newDevice
        self.currentInput = newInput

        applyConnectionOrientation(position: position)
    }

    func capturePhoto(settings: PhotoCaptureClient.PhotoSettings) {
        let avSettings = AVCapturePhotoSettings()
        avSettings.flashMode = settings.flashMode.avFlashMode
        avSettings.photoQualityPrioritization = settings.qualityPrioritization.avQualityPrioritization
        photoOutput?.capturePhoto(with: avSettings, delegate: self)
    }

    func focus(at point: CGPoint) throws {
        guard let device = currentDevice else {
            throw PhotoCaptureClient.Error.captureSessionNotRunning
        }
        guard device.isFocusModeSupported(.autoFocus) else {
            throw PhotoCaptureClient.Error.focusModeNotSupported
        }
        try device.lockForConfiguration()
        device.focusPointOfInterest = point
        device.focusMode = .autoFocus
        device.unlockForConfiguration()
    }

    /// Focus **and** auto-expose at a point of interest. The tap gesture drives this, so each axis is
    /// guarded by device support and simply skipped when unavailable — a tap must never fail — and one
    /// lock covers both.
    func focusAndExpose(at point: CGPoint) {
        guard let device = currentDevice else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
            device.focusPointOfInterest = point
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
            device.exposurePointOfInterest = point
            device.exposureMode = .autoExpose
        }
        device.unlockForConfiguration()
    }

    #if os(iOS)
        func setZoomFactor(_ factor: CGFloat) throws {
            guard let device = currentDevice else {
                throw PhotoCaptureClient.Error.captureSessionNotRunning
            }
            let minZoom = device.minAvailableVideoZoomFactor
            let maxZoom = device.maxAvailableVideoZoomFactor
            guard factor >= minZoom && factor <= maxZoom else {
                throw PhotoCaptureClient.Error.zoomFactorOutOfRange(min: minZoom, max: maxZoom)
            }
            try device.lockForConfiguration()
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
        }

        /// Set zoom, clamping to the device's available range instead of throwing — the pinch gesture
        /// drives this and must not fail at the limits.
        func setZoomFactorClamped(_ factor: CGFloat) {
            guard let device = currentDevice else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        }

        /// The active device's available zoom range, supplied to the renderer so pinch clamps locally.
        func zoomLimits() -> (min: CGFloat, max: CGFloat) {
            guard let device = currentDevice else { return (1, 1) }
            return (device.minAvailableVideoZoomFactor, device.maxAvailableVideoZoomFactor)
        }
    #else
        func setZoomFactor(_ factor: CGFloat) throws {
            throw PhotoCaptureClient.Error.cameraUnavailable
        }
    #endif

    func teardown() {
        if let session = captureSession, session.isRunning {
            sessionQueue.async {
                session.stopRunning()
            }
        }
        removeNotificationObservers()
        pixelBufferContinuation?.finish()
        pixelBufferContinuation = nil
        videoDataOutput = nil
        depthDataOutput = nil
        latestDepthMap = nil
        hasDepth = false
        onFrame = nil
        captureSession = nil
        photoOutput = nil
        currentDevice = nil
        currentInput = nil
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

// MARK: - AVCapturePhotoCaptureDelegate

extension PhotoCaptureDelegate: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        onEvent?(.willBeginCapture)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        onEvent?(.willCapturePhoto)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        onEvent?(.didCapturePhoto)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Swift.Error)?
    ) {
        if let error {
            photoContinuation?.resume(throwing: PhotoCaptureClient.Error.captureFailed(error.localizedDescription))
            photoContinuation = nil
            return
        }

        let dimensions = photo.resolvedSettings.photoDimensions
        #if os(iOS)
            let isRaw = photo.isRawPhoto
        #else
            let isRaw = false
        #endif
        let domainPhoto = PhotoCaptureClient.Photo(
            fileDataRepresentation: photo.fileDataRepresentation(),
            photoDimensions: CGSize(width: Int(dimensions.width), height: Int(dimensions.height)),
            timestamp: .now,
            isRawPhoto: isRaw
        )
        photoContinuation?.resume(returning: domainPhoto)
        photoContinuation = nil
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: (any Swift.Error)?
    ) {
        onEvent?(.captureCompleted)

        // If didFinishProcessingPhoto was never called (e.g., error before processing)
        if let error, photoContinuation != nil {
            photoContinuation?.resume(throwing: PhotoCaptureClient.Error.captureFailed(error.localizedDescription))
            photoContinuation = nil
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension PhotoCaptureDelegate: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Deliver every frame to Metal renderer at full camera rate
        onFrame?(pixelBuffer)

        // Throttle: only deliver frames for detection inference at ~5fps
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= frameIntervalSeconds else { return }
        lastFrameTime = now

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let wrapper = PhotoCaptureClient.PixelBufferWrapper(
            pixelBuffer: pixelBuffer,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            depthBuffer: latestDepthMap,
            timestamp: .now
        )

        pixelBufferContinuation?.yield(wrapper)
    }
}

// MARK: - AVCaptureDepthDataOutputDelegate

extension PhotoCaptureDelegate: AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didOutput depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection
    ) {
        // Throttle to the detection cadence: the conversion + EXIF reorientation below are per-frame
        // CPU work, and nothing samples depth faster than video frames are throttled through.
        let now = CACurrentMediaTime()
        guard now - lastDepthTime >= frameIntervalSeconds else { return }
        lastDepthTime = now

        // Normalise to metric depth (metres, smaller = nearer). LiDAR/dual cameras may deliver
        // disparity or 16-bit depth; converting to DepthFloat32 guarantees comparable metres and a
        // fresh, non-pool backing buffer that is safe to retain past this callback (the wrapper's
        // strong CVPixelBuffer reference keeps it alive once attached).
        let metric =
            depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        // Orient the depth map to match the rotated/mirrored video buffer in software. Setting
        // videoRotationAngle on the depth connection does not reliably rotate depthDataMap, so the raw
        // map is sensor-native landscape; sampling a portrait box centre there reads a 90°-wrong (and,
        // front, mirrored) pixel. applyingExifOrientation rotates both the map and its calibration so
        // the existing top-left, portrait-normalised box centre samples the correct pixel.
        let oriented = metric.applyingExifOrientation(depthExifOrientation)
        let map = oriented.depthDataMap
        latestDepthMap = map
        #if DEBUG
            if !didLogDepth {
                didLogDepth = true
                onLog?(
                    "Depth map \(CVPixelBufferGetWidth(map))x\(CVPixelBufferGetHeight(map)) "
                        + "(portrait expects height > width), exif=\(depthExifOrientation.rawValue)"
                )
            }
        #endif
    }
}

// MARK: - Actor

/// Plain actor that manages AVFoundation photo capture via a delegate.
actor PhotoCaptureClientActor {
    private let delegate = PhotoCaptureDelegate()
    private let logger: @Sendable (String) -> Void

    private var currentPosition: PhotoCaptureClient.CameraPosition = .back
    private var currentFlashMode: PhotoCaptureClient.FlashMode = .auto
    #if os(iOS)
        private var metalRenderer: MetalPreviewRenderer?
        private var cachedPreviewView: PhotoCaptureClient.PreviewView?
        private var currentVisualZoom: (factor: Float, anchorX: Float, anchorY: Float) = (1.0, 0.5, 0.5)
    #endif
    private var eventContinuations: [UUID: AsyncStream<PhotoCaptureClient.Event>.Continuation] = [:]

    // MARK: - Init

    init(
        logger: @escaping @Sendable (String) -> Void = { message in
            #if DEBUG
                print("📷 [PHOTO_CAPTURE]: \(message)")
            #endif
        }
    ) {
        self.logger = logger

        delegate.onEvent = { [weak self] event in
            Task { await self?.yieldEvent(event) }
        }
        delegate.onLog = { [weak self] message in
            Task { await self?.log(message) }
        }
    }

    private func log(_ message: String) {
        logger(message)
    }

    // MARK: - Session Lifecycle

    func startSession() async throws {
        guard !delegate.isRunning else {
            throw PhotoCaptureClient.Error.captureSessionAlreadyRunning
        }
        logger("Configuring capture session")
        try delegate.configureSession(position: currentPosition)
        delegate.registerNotificationObservers()
        #if os(iOS)
            let renderer = await MainActor.run { MetalPreviewRenderer.create() }
            self.metalRenderer = renderer
            delegate.onFrame = { [weak renderer] pixelBuffer in
                renderer?.enqueueFrame(pixelBuffer)
            }
            await wireGestureCallbacks(to: renderer)
            // Link renderer to cached preview view (if getPreviewView was called before startSession)
            if let renderer, let cached = cachedPreviewView {
                renderer.previewViewRef = cached
            }
            // Invalidate cached preview so next getPreviewView returns one with the new renderer
            cachedPreviewView = nil
        #endif
        logger("Starting capture session")
        delegate.startRunning()
    }

    func stopSession() async {
        guard delegate.isRunning else {
            logger("Session not running, nothing to stop")
            return
        }
        logger("Stopping capture session")
        delegate.pixelBufferContinuation?.finish()
        delegate.pixelBufferContinuation = nil
        #if os(iOS)
            delegate.onFrame = nil
            metalRenderer = nil
        #endif
        delegate.teardown()
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    // MARK: - Photo Capture

    func capturePhoto(settings: PhotoCaptureClient.PhotoSettings) async throws -> PhotoCaptureClient.Photo {
        guard delegate.isRunning else {
            throw PhotoCaptureClient.Error.captureSessionNotRunning
        }
        logger("Capturing photo with flash: \(settings.flashMode)")

        return try await withCheckedThrowingContinuation { continuation in
            delegate.photoContinuation = continuation
            delegate.capturePhoto(settings: settings)
        }
    }

    // MARK: - Camera Control

    func switchCamera(to position: PhotoCaptureClient.CameraPosition) async throws {
        logger("Switching camera to \(position)")
        try delegate.switchCamera(to: position)
        currentPosition = position
        #if os(iOS)
            currentVisualZoom = (1.0, 0.5, 0.5)
            let renderer = metalRenderer
            let limits = delegate.zoomLimits()
            await MainActor.run {
                renderer?.resetVisualZoom()
                renderer?.zoomLimits = limits
                renderer?.resetZoomTracking()
            }
            yieldEvent(.zoomChanged(1.0))
        #endif
    }

    func setFlashMode(_ mode: PhotoCaptureClient.FlashMode) {
        logger("Setting flash mode to \(mode)")
        currentFlashMode = mode
    }

    func focus(at point: CGPoint) async throws {
        logger("Focusing at \(point)")
        try delegate.focus(at: point)
    }

    func setZoomFactor(_ factor: CGFloat) async throws {
        logger("Setting zoom factor to \(factor)")
        try delegate.setZoomFactor(factor)
        #if os(iOS)
            let renderer = metalRenderer
            await MainActor.run { renderer?.syncZoomTracking(to: factor) }
        #endif
    }

    #if os(iOS)
        /// Wire the renderer's default gestures to the capture device: pinch → clamped zoom, tap →
        /// focus + auto-expose. Supplies the device's zoom limits so the pinch clamps on the main thread.
        private func wireGestureCallbacks(to renderer: MetalPreviewRenderer?) async {
            guard let renderer else { return }
            let limits = delegate.zoomLimits()
            await MainActor.run {
                renderer.zoomLimits = limits
                renderer.resetZoomTracking()
                renderer.onZoomChange = { [weak self] factor in
                    Task { await self?.applyGestureZoom(factor) }
                }
                renderer.onTapToFocus = { [weak self] point in
                    Task { await self?.applyTapToFocus(point) }
                }
            }
        }

        private func applyGestureZoom(_ factor: CGFloat) {
            delegate.setZoomFactorClamped(factor)
        }

        private func applyTapToFocus(_ point: CGPoint) {
            delegate.focusAndExpose(at: point)
        }
    #endif

    func setVisualZoom(
        factor: CGFloat,
        anchorX: CGFloat,
        anchorY: CGFloat
    ) async {
        #if os(iOS)
            let clamped = Float(min(max(factor, 1.0), 5.0))
            let clampedAX = Float(min(max(anchorX, 0.0), 1.0))
            let clampedAY = Float(min(max(anchorY, 0.0), 1.0))
            currentVisualZoom = (clamped, clampedAX, clampedAY)
            let renderer = metalRenderer
            await MainActor.run {
                renderer?.setVisualZoom(factor: clamped, anchorX: clampedAX, anchorY: clampedAY)
            }
            yieldEvent(.zoomChanged(CGFloat(clamped)))
        #endif
    }

    // MARK: - Authorization

    func requestAuthorization() async -> PhotoCaptureClient.AuthorizationStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .authorized : .denied
    }

    nonisolated func authorizationStatus() -> PhotoCaptureClient.AuthorizationStatus {
        AVAuthorizationStatus.from(AVCaptureDevice.authorizationStatus(for: .video))
    }

    // MARK: - Streams

    func observeEvents() -> AsyncStream<PhotoCaptureClient.Event> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    // MARK: - Frame Delivery

    func observePixelBuffers() -> AsyncStream<PhotoCaptureClient.PixelBufferWrapper> {
        // bufferingNewest(1): if inference falls behind, keep only the latest frame so detection
        // never chews through a backlog staler than the live preview (and never pins pool buffers).
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // The delegate writes directly into this continuation from the video data queue.
            // Only one subscriber is supported at a time (last subscriber wins).
            delegate.pixelBufferContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.clearPixelBufferContinuation() }
            }
        }
    }

    private func clearPixelBufferContinuation() {
        delegate.pixelBufferContinuation = nil
    }

    // MARK: - Preview

    #if os(iOS)
        func getPreviewView() -> PhotoCaptureClient.PreviewView {
            if let cached = cachedPreviewView {
                return cached
            }
            let preview: PhotoCaptureClient.PreviewView
            if let renderer = metalRenderer {
                preview = PhotoCaptureClient.PreviewView(view: renderer)
                renderer.previewViewRef = preview
                // Sync current visual zoom state
                preview.visualZoomFactor = currentVisualZoom.factor
                preview.visualZoomAnchorX = currentVisualZoom.anchorX
                preview.visualZoomAnchorY = currentVisualZoom.anchorY
            } else {
                preview = PhotoCaptureClient.PreviewView(view: UIView())
            }
            cachedPreviewView = preview
            return preview
        }

        func updateOverlays(_ overlays: [PhotoCaptureClient.OverlayRect]) {
            metalRenderer?.updateOverlays(overlays)
        }

        func setLabelsVisible(_ visible: Bool) {
            metalRenderer?.setLabelsVisible(visible)
        }

        func setOverlayStyle(_ style: PhotoCaptureClient.OverlayStyle) {
            metalRenderer?.setOverlayStyle(style)
        }
    #else
        func getPreviewView() -> PhotoCaptureClient.PreviewView {
            return PhotoCaptureClient.PreviewView(view: NSView())
        }

        func updateOverlays(_ overlays: [PhotoCaptureClient.OverlayRect]) {}

        func setLabelsVisible(_ visible: Bool) {}

        func setOverlayStyle(_ style: PhotoCaptureClient.OverlayStyle) {}
    #endif

    // MARK: - Helpers

    private func yieldEvent(_ event: PhotoCaptureClient.Event) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }
}

// MARK: - AVFoundation → Domain Conversions

extension PhotoCaptureClient.FlashMode {
    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
            case .off: .off
            case .on: .on
            case .auto: .auto
        }
    }
}

extension PhotoCaptureClient.QualityPrioritization {
    var avQualityPrioritization: AVCapturePhotoOutput.QualityPrioritization {
        switch self {
            case .speed: .speed
            case .balanced: .balanced
            case .quality: .quality
        }
    }
}

extension AVAuthorizationStatus {
    static func from(_ status: AVAuthorizationStatus) -> PhotoCaptureClient.AuthorizationStatus {
        switch status {
            case .notDetermined: .notDetermined
            case .restricted: .restricted
            case .denied: .denied
            case .authorized: .authorized
            @unknown default: .notDetermined
        }
    }
}

#if os(iOS)
    extension AVCaptureSession.InterruptionReason {
        var domainReason: PhotoCaptureClient.InterruptionReason {
            switch self {
                case .videoDeviceNotAvailableInBackground:
                    .videoDeviceNotAvailableInBackground
                case .audioDeviceInUseByAnotherClient:
                    .audioDeviceInUseByAnotherClient
                case .videoDeviceInUseByAnotherClient:
                    .videoDeviceInUseByAnotherClient
                case .videoDeviceNotAvailableWithMultipleForegroundApps:
                    .videoDeviceNotAvailableWithMultipleForegroundApps
                case .videoDeviceNotAvailableDueToSystemPressure:
                    .videoDeviceNotAvailableDueToSystemPressure
                case .sensitiveContentMitigationActivated:
                    .unknown
                @unknown default:
                    .unknown
            }
        }
    }
#endif
