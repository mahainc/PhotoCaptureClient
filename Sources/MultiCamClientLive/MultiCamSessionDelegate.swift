#if os(iOS)
    @preconcurrency import AVFoundation
    import CoreImage
    import CoreMedia
    import Foundation
    import MultiCamClient
    import PhotoCaptureClient
    import UIKit
    import os

    /// Bridges AVCaptureMultiCamSession to the actor. Owns all AVFoundation objects.
    /// Follows the same delegate pattern as PhotoCaptureDelegate in PhotoCaptureClientLive.
    final class MultiCamSessionDelegate: NSObject, @unchecked Sendable {

        // MARK: - Callbacks

        var onVideoFrame: ((_ cameraID: MultiCamClient.CameraID, _ sampleBuffer: CMSampleBuffer) -> Void)?
        var onAudioSample: ((_ sampleBuffer: CMSampleBuffer) -> Void)?
        var onEvent: (@Sendable (MultiCamClient.Event) -> Void)?

        // MARK: - AVFoundation State

        var multiCamSession: AVCaptureMultiCamSession?
        var cameraInputs: [MultiCamClient.CameraID: AVCaptureDeviceInput] = [:]
        var videoOutputs: [MultiCamClient.CameraID: AVCaptureVideoDataOutput] = [:]
        var outputToCameraID: [ObjectIdentifier: MultiCamClient.CameraID] = [:]
        var audioOutput: AVCaptureAudioDataOutput?

        // Per-camera dispatch queues
        var videoQueues: [MultiCamClient.CameraID: DispatchQueue] = [:]
        let audioQueue = DispatchQueue(label: "MultiCamDelegate.audio")
        private let sessionQueue = DispatchQueue(label: "MultiCamDelegate.session")

        var isRunning: Bool {
            multiCamSession?.isRunning ?? false
        }

        // MARK: - Session Configuration State

        /// The hardware cost after session configuration (0.0–1.0). Values >= 1.0 may cause issues.
        var lastHardwareCost: Float = 0

        /// Cameras that were actually added successfully (may be fewer than requested if cost exceeded).
        var activeCameras: [MultiCamClient.CameraID] = []

        // MARK: - System Pressure KVO

        var pressureObservations: [NSKeyValueObservation] = []

        // MARK: - Per-Camera Zoom

        func setZoom(
            for camera: MultiCamClient.CameraID,
            factor: CGFloat
        ) throws {
            guard let input = cameraInputs[camera] else {
                throw MultiCamClient.Error.cameraSetNotSupported([camera])
            }
            let device = input.device
            let minZoom = device.minAvailableVideoZoomFactor
            let maxZoom = device.maxAvailableVideoZoomFactor
            let clamped = min(max(factor, minZoom), maxZoom)
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        }

        // MARK: - Torch

        func setTorch(mode: MultiCamClient.TorchMode) {
            // Find any back camera with torch capability
            let backCamera = cameraInputs.first { key, input in
                key.rawValue.hasPrefix("back") && input.device.hasTorch
            }?.value.device
            guard let device = backCamera else { return }
            let avMode: AVCaptureDevice.TorchMode
            switch mode {
                case .off: avMode = .off
                case .on: avMode = .on
                case .auto: avMode = .auto
            }
            try? device.lockForConfiguration()
            device.torchMode = avMode
            device.unlockForConfiguration()
        }

        // MARK: - Video Stabilization

        func setStabilization(
            for camera: MultiCamClient.CameraID,
            mode: MultiCamClient.StabilizationMode
        ) {
            guard let output = videoOutputs[camera],
                let connection = output.connection(with: .video),
                connection.isVideoStabilizationSupported
            else { return }

            let avMode: AVCaptureVideoStabilizationMode
            switch mode {
                case .off: avMode = .off
                case .standard: avMode = .standard
                case .cinematic: avMode = .cinematic
                case .cinematicExtended: avMode = .cinematicExtended
                case .auto: avMode = .auto
            }

            // Check if the device format supports this mode
            if let input = cameraInputs[camera],
                input.device.activeFormat.isVideoStabilizationModeSupported(avMode)
            {
                connection.preferredVideoStabilizationMode = avMode
            } else {
                // Fallback to standard if requested mode not supported
                connection.preferredVideoStabilizationMode = .standard
            }
        }

        func zoomRange(for camera: MultiCamClient.CameraID) -> (min: CGFloat, max: CGFloat) {
            guard let input = cameraInputs[camera] else { return (1.0, 1.0) }
            return (input.device.minAvailableVideoZoomFactor, input.device.maxAvailableVideoZoomFactor)
        }

        // MARK: - Photo Capture

        /// Latest pixel buffer per camera — thread-safe storage for snapshot capture.
        private struct PixelBufferStore: @unchecked Sendable {
            var buffers: [MultiCamClient.CameraID: CVPixelBuffer] = [:]
        }
        private let _latestPixelBuffers = OSAllocatedUnfairLock(initialState: PixelBufferStore())

        func storeLatestPixelBuffer(
            _ pixelBuffer: CVPixelBuffer,
            for camera: MultiCamClient.CameraID
        ) {
            _latestPixelBuffers.withLockUnchecked { $0.buffers[camera] = pixelBuffer }
        }

        func capturePhoto(for camera: MultiCamClient.CameraID) -> PhotoCaptureClient.Photo? {
            guard let pixelBuffer = _latestPixelBuffers.withLockUnchecked({ $0.buffers[camera] }) else { return nil }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)

            // Convert pixel buffer to JPEG data
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }

            let uiImage = UIImage(cgImage: cgImage)
            guard let jpegData = uiImage.jpegData(compressionQuality: 0.9) else { return nil }

            return PhotoCaptureClient.Photo(
                fileDataRepresentation: jpegData,
                photoDimensions: CGSize(width: width, height: height),
                timestamp: .now,
                isRawPhoto: false
            )
        }

        func startRunning() {
            sessionQueue.async { [weak self] in
                self?.multiCamSession?.startRunning()
            }
        }

        func stopRunning() {
            sessionQueue.async { [weak self] in
                self?.multiCamSession?.stopRunning()
            }
        }

        func teardown() {
            if let session = multiCamSession, session.isRunning {
                sessionQueue.async { session.stopRunning() }
            }
            removeNotificationObservers()
            onVideoFrame = nil
            onAudioSample = nil
            multiCamSession = nil
            cameraInputs.removeAll()
            videoOutputs.removeAll()
            outputToCameraID.removeAll()
            videoQueues.removeAll()
            audioOutput = nil
        }
    }
#endif
