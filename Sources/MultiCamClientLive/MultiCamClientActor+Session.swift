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
        // MARK: - Session Lifecycle

        func startSession(_ config: MultiCamClient.SessionConfiguration) async throws {
            guard !delegate.isRunning else {
                throw MultiCamClient.Error.sessionAlreadyRunning
            }

            logger("Configuring multi-cam session with \(config.cameras.map(\.rawValue))")
            try delegate.configureSession(config)
            delegate.registerNotificationObservers()

            // Use actual cameras that were successfully added (may be fewer if hardware cost exceeded)
            activeCameras = delegate.activeCameras
            logger(
                "Active cameras: \(activeCameras.map(\.rawValue)), hardware cost: \(String(format: "%.2f", delegate.lastHardwareCost))"
            )

            // FIX: Compositor uses actual active cameras (not requested), in case some were dropped
            let actualCameras = activeCameras
            let comp = await createCompositor(for: actualCameras)
            self.compositor = comp
            if comp == nil {
                yieldEvent(.sessionError("Metal compositor unavailable — preview disabled"))
            }

            wireCompositorCallbacks(compositor: comp)

            // Invalidate cached preview
            cachedPreviewView = nil

            logger("Starting multi-cam session")
            delegate.startRunning()

            emitConnectionEvents(activeCameras: activeCameras, requestedCameras: config.cameras)
        }

        /// Creates and configures a fresh compositor for the given active cameras, restoring the
        /// persisted layout/callbacks/histogram state so a session restart is seamless.
        private func createCompositor(
            for cameras: [MultiCamClient.CameraID]
        ) async -> MultiCamCompositor? {
            let layout = currentLayout
            let savedCallbacks = pipGestureCallbacks
            let savedHistogramVisible = histogramVisible
            let savedHistogramConfig = histogramConfig
            return await MainActor.run {
                let comp = MultiCamCompositor.create()
                // setLayout first (may override _cameras for stale custom layouts),
                // then setCameras to restore the correct camera list and recompute viewports.
                comp?.setLayout(layout)
                comp?.setCameras(cameras)
                // Re-apply persisted gesture callbacks so the consumer doesn't have to
                // re-install them on every session restart.
                comp?.setGestureCallbacks(savedCallbacks)
                comp?.setHistogramConfig(savedHistogramConfig)
                comp?.setHistogramVisible(savedHistogramVisible)
                return comp
            }
        }

        /// Wires delegate → compositor + recording pipeline + pixel buffer streams.
        /// Recording pipeline is called SYNCHRONOUSLY here to ensure CMSampleBuffer
        /// is still valid (AVFoundation recycles buffers after the delegate returns).
        private func wireCompositorCallbacks(compositor comp: MultiCamCompositor?) {
            let pipeline = recordingPipeline
            let del = delegate
            delegate.onVideoFrame = { [weak self, weak comp, weak del] cameraID, sampleBuffer in
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                comp?.enqueueFrame(pixelBuffer, for: cameraID)

                // Store latest frame for photo capture (lightweight lock)
                del?.storeLatestPixelBuffer(pixelBuffer, for: cameraID)

                // Feed recording pipeline synchronously (before buffer is recycled)
                pipeline.appendVideoSample(sampleBuffer, for: cameraID)

                // Feed pixel buffer streams only if observers exist (avoid per-frame Task allocation)
                if self?._hasPixelBufferObservers.withLock({ $0 }) == true {
                    let wrapped = SendableSampleBuffer(sampleBuffer)
                    Task { [weak self] in
                        await self?.deliverPixelBuffer(cameraID: cameraID, sampleBuffer: wrapped)
                    }
                }
            }

            delegate.onAudioSample = { sampleBuffer in
                pipeline.appendAudioSample(sampleBuffer)
            }
        }

        /// Emits `cameraConnected` for cameras that passed the hardware cost check, and
        /// `cameraDisconnected` for any requested camera that was dropped.
        private func emitConnectionEvents(
            activeCameras: [MultiCamClient.CameraID],
            requestedCameras: [MultiCamClient.CameraID]
        ) {
            for camera in activeCameras {
                yieldEvent(.cameraConnected(camera))
            }
            let dropped = requestedCameras.filter { !activeCameras.contains($0) }
            for camera in dropped {
                yieldEvent(.cameraDisconnected(camera))
            }
        }

        func stopSession() async {
            logger("Stopping multi-cam session (isRunning=\(delegate.isRunning))")

            if isRecording {
                if let result = try? await recordingPipeline.stopRecording() {
                    yieldEvent(.recordingStopped(result))
                }
                isRecording = false
            }

            delegate.onVideoFrame = nil
            delegate.onAudioSample = nil
            compositor = nil
            cachedPreviewView = nil
            delegate.teardown()

            for (_, continuations) in pixelBufferContinuations {
                for continuation in continuations.values {
                    continuation.finish()
                }
            }
            pixelBufferContinuations.removeAll()

            for continuation in eventContinuations.values {
                continuation.finish()
            }
            eventContinuations.removeAll()

            activeCameras = []
        }
    }
#endif
