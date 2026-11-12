#if os(iOS)
    @preconcurrency import AVFoundation
    import CoreMedia
    import Foundation
    import HistogramKit
    import MultiCamClient
    import PhotoCaptureClient
    import UIKit
    import os

    extension MultiCamClientActor {
        // MARK: - Recording

        func startRecording(_ config: MultiCamClient.RecordingConfiguration) async throws {
            guard delegate.isRunning else {
                throw MultiCamClient.Error.sessionNotRunning
            }
            guard !activeCameras.isEmpty else {
                throw MultiCamClient.Error.cameraSetNotSupported([])
            }
            guard !isRecording else {
                throw MultiCamClient.Error.recordingAlreadyInProgress
            }

            let (cameraSize, compositeSize) = await recordingSizes(forOutputWidth: config.outputWidth)
            try recordingPipeline.startRecording(
                config: config,
                cameras: activeCameras,
                cameraSize: cameraSize,
                compositeSize: compositeSize
            )

            await wireRecordingOutput(size: compositeSize)

            isRecording = true
            yieldEvent(.recordingStarted)
            logger("Recording started (with real-time compositing)")
        }

        /// Computes the per-camera writer size and the screen-aspect-matched composite size
        /// used by `startRecording`.
        private func recordingSizes(
            forOutputWidth outputWidth: Int
        ) async -> (cameraSize: CGSize, compositeSize: CGSize) {
            // Per-camera writers use standard 9:16 portrait (matches camera pixel buffer
            // dimensions) — the transpose of the existing 16:9 `Resolution.hd1080p` dimensions.
            let cameraSize = CGSize(
                width: CGFloat(MultiCamClient.Resolution.hd1080p.height),
                height: CGFloat(MultiCamClient.Resolution.hd1080p.width)
            )

            // Compositor uses screen aspect ratio so viewport rects map correctly
            let screenBounds = await MainActor.run { UIScreen.main.bounds }
            let screenAR = screenBounds.width / screenBounds.height
            let compositeWidth = max(2, outputWidth)
            let rawCompH = Int((CGFloat(compositeWidth) / screenAR).rounded())
            let compositeSize = CGSize(width: compositeWidth, height: rawCompH + (rawCompH % 2))

            return (cameraSize, compositeSize)
        }

        /// Enables compositor offscreen recording and wires its composed-frame callback to the
        /// recording pipeline.
        private func wireRecordingOutput(size compositeSize: CGSize) async {
            let pipeline = recordingPipeline
            let comp = compositor
            await MainActor.run {
                comp?.configureRecordingOutput(size: compositeSize)
                comp?.onRecordingFrame = { pixelBuffer, time in
                    pipeline.appendComposedFrame(pixelBuffer, at: time)
                }
                comp?.isRecording = true
            }
        }

        func pauseRecording() async {
            guard isRecording else { return }
            recordingPipeline.pause()
            let comp = compositor
            await MainActor.run { comp?.isRecording = false }
            yieldEvent(.recordingPaused)
            logger("Recording paused")
        }

        func resumeRecording() async {
            guard isRecording else { return }
            recordingPipeline.resume()
            let comp = compositor
            await MainActor.run { comp?.isRecording = true }
            yieldEvent(.recordingResumed)
            logger("Recording resumed")
        }

        func capturePhoto(camera: MultiCamClient.CameraID) throws -> PhotoCaptureClient.Photo {
            guard delegate.isRunning else {
                throw MultiCamClient.Error.sessionNotRunning
            }
            guard let photo = delegate.capturePhoto(for: camera) else {
                throw MultiCamClient.Error.cameraSetNotSupported([camera])
            }
            yieldEvent(.photoCaptured(camera))
            return photo
        }

        func captureCompositePhoto(outputSize: CGSize) async throws -> MultiCamClient.CompositePhotoCaptureResult {
            guard delegate.isRunning else {
                throw MultiCamClient.Error.sessionNotRunning
            }

            // 1. Composite photo from Metal compositor
            let comp = compositor
            let combinedPhoto: PhotoCaptureClient.Photo? = await MainActor.run {
                comp?.captureCompositePhoto(outputSize: outputSize)
            }

            // 2. Individual per-camera photos
            var individualPhotos: [MultiCamClient.CameraID: PhotoCaptureClient.Photo] = [:]
            for camera in activeCameras {
                if let photo = delegate.capturePhoto(for: camera) {
                    individualPhotos[camera] = photo
                }
            }

            return MultiCamClient.CompositePhotoCaptureResult(
                combinedPhoto: combinedPhoto,
                individualPhotos: individualPhotos
            )
        }

        func stopRecording() async throws -> MultiCamClient.RecordingResult {
            guard isRecording else {
                throw MultiCamClient.Error.recordingNotInProgress
            }

            // Stop compositor recording first
            let comp = compositor
            await MainActor.run {
                comp?.isRecording = false
                comp?.onRecordingFrame = nil
            }

            let result = try await recordingPipeline.stopRecording()
            isRecording = false
            yieldEvent(.recordingStopped(result))
            logger("Recording stopped: duration=\(result.duration)s, combined=\(result.combinedURL != nil)")
            return result
        }
    }
#endif
