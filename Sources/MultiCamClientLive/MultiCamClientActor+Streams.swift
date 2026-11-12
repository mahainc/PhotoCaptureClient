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
        // MARK: - Preview

        /// Returns the cached preview view, creating, caching and wiring it to the compositor
        /// on first call. The `ensure` prefix admits that side effect; a `get` would not.
        func ensurePreviewView() async -> MultiCamClient.PreviewView {
            if let cached = cachedPreviewView {
                return cached
            }
            let comp = compositor
            let layout = currentLayout
            let preview = await MainActor.run {
                if let comp {
                    let pv = MultiCamClient.PreviewView(view: comp, layout: layout)
                    comp.previewViewRef = pv
                    return pv
                } else {
                    return MultiCamClient.PreviewView(view: UIView(), layout: layout)
                }
            }
            cachedPreviewView = preview
            return preview
        }

        // MARK: - Streams

        func observeEvents() -> AsyncStream<MultiCamClient.Event> {
            let id = UUID()
            return AsyncStream { continuation in
                eventContinuations[id] = continuation
                continuation.onTermination = { [weak self] _ in
                    Task { await self?.removeEventContinuation(id: id) }
                }
            }
        }

        private func removeEventContinuation(id: UUID) {
            eventContinuations.removeValue(forKey: id)
        }

        func observePixelBuffers(for camera: MultiCamClient.CameraID) -> AsyncStream<
            PhotoCaptureClient.PixelBufferWrapper
        > {
            let id = UUID()
            return AsyncStream { continuation in
                if pixelBufferContinuations[camera] == nil {
                    pixelBufferContinuations[camera] = [:]
                }
                pixelBufferContinuations[camera]?[id] = continuation
                _hasPixelBufferObservers.withLock { $0 = true }
                continuation.onTermination = { [weak self] _ in
                    Task { await self?.removePixelBufferContinuation(camera: camera, id: id) }
                }
            }
        }

        private func removePixelBufferContinuation(
            camera: MultiCamClient.CameraID,
            id: UUID
        ) {
            pixelBufferContinuations[camera]?.removeValue(forKey: id)
            // Update atomic flag
            let hasAny = pixelBufferContinuations.values.contains { !$0.isEmpty }
            _hasPixelBufferObservers.withLock { $0 = hasAny }
        }

        // MARK: - Internal Frame Delivery

        func deliverPixelBuffer(
            cameraID: MultiCamClient.CameraID,
            sampleBuffer: SendableSampleBuffer
        ) {
            // Yield to per-camera pixel buffer streams
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer.buffer) else { return }
            let wrapper = PhotoCaptureClient.PixelBufferWrapper(
                pixelBuffer: pixelBuffer,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                timestamp: .now
            )

            if let continuations = pixelBufferContinuations[cameraID] {
                for continuation in continuations.values {
                    continuation.yield(wrapper)
                }
            }
        }
    }
#endif
