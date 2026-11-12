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

// MARK: - Device & Depth Selection

extension PhotoCaptureDelegate {
    /// Discover the best capture device for a position, preferring depth-capable virtual devices
    /// (LiDAR / dual / TrueDepth) over the plain wide-angle camera.
    static func bestDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
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
    func configureDepth(
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

    /// The preview frame rate held while a result covers the feed — low enough to shed heat, high
    /// enough that motion behind the result still reads as live rather than stepped.
    private static let reducedPreviewFrameRate: Double = 15

    /// Lower the live preview's cost in place, or restore the full viewfinder. `reduced` drops the
    /// depth pipeline, caps the frame rate, and shrinks the camera texture; `full` re-runs the
    /// initial depth/format/30fps configuration so the viewfinder returns exactly as it started.
    func setPreviewPerformanceMode(reduced: Bool) {
        guard let session = captureSession, let device = currentDevice else { return }
        session.beginConfiguration()
        if reduced {
            detachDepthOutput(from: session)
            latestDepthMap = nil
            if session.canSetSessionPreset(.hd1280x720) {
                session.sessionPreset = .hd1280x720
            }
            if (try? device.lockForConfiguration()) != nil {
                applyClampedFrameRate(device, target: Self.reducedPreviewFrameRate)
                device.unlockForConfiguration()
            }
        } else {
            session.sessionPreset = .photo
            configureDepth(session: session, device: device)
        }
        session.commitConfiguration()
    }

    /// Remove the depth output without the format/frame-rate restore `disableDepth` performs: the
    /// reduced mode sets both itself and must not be bounced back to 30fps here.
    private func detachDepthOutput(from session: AVCaptureSession) {
        if let existing = depthDataOutput {
            session.removeOutput(existing)
            depthDataOutput = nil
        }
        hasDepth = false
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
}
