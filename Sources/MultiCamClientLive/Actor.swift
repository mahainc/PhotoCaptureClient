#if os(iOS)
    @preconcurrency import AVFoundation
    import CoreMedia
    import Foundation
    import HistogramKit
    import MultiCamClient
    import PhotoCaptureClient
    import UIKit
    import os

    /// Sendable wrapper for CMSampleBuffer to cross isolation boundaries.
    final class SendableSampleBuffer: @unchecked Sendable {
        let buffer: CMSampleBuffer
        init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
    }

    /// Coordinating actor for multi-camera sessions, preview, and recording.
    /// Follows the same pattern as PhotoCaptureClientActor.
    ///
    /// The actor's surface is split across cohesive extension files in this target:
    /// `+Capability`, `+Session`, `+Controls`, `+Recording`, `+Authorization` and `+Streams`.
    actor MultiCamClientActor {
        let delegate = MultiCamSessionDelegate()
        let recordingPipeline = RecordingPipeline()
        let logger: @Sendable (String) -> Void

        var compositor: MultiCamCompositor?
        var cachedPreviewView: MultiCamClient.PreviewView?
        var currentLayout: MultiCamClient.Layout = .grid(.init())
        var activeCameras: [MultiCamClient.CameraID] = []
        var isRecording = false
        var pipGestureCallbacks: MultiCamClient.PiPGestureCallbacks = .none
        var histogramVisible = false
        var histogramConfig = Histogram.Config.default

        var eventContinuations: [UUID: AsyncStream<MultiCamClient.Event>.Continuation] = [:]
        var pixelBufferContinuations:
            [MultiCamClient.CameraID: [UUID: AsyncStream<PhotoCaptureClient.PixelBufferWrapper>.Continuation]] = [:]
        /// Atomic flag: true if any pixel buffer observers exist. Checked from capture queues without actor hop.
        let _hasPixelBufferObservers = OSAllocatedUnfairLock(initialState: false)

        // MARK: - Init

        init(
            logger: @escaping @Sendable (String) -> Void = { message in
                #if DEBUG
                    print("📹 [MULTI_CAM]: \(message)")
                #endif
            }
        ) {
            self.logger = logger

            delegate.onEvent = { [weak self] event in
                Task { await self?.yieldEvent(event) }
            }
        }

        // MARK: - Helpers

        func yieldEvent(_ event: MultiCamClient.Event) {
            for continuation in eventContinuations.values {
                continuation.yield(event)
            }
        }
    }
#endif
